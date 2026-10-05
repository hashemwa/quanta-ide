import AppKit
import Combine

struct InlineCompletionEdit: Equatable {
    let range: NSRange
    let text: String

    init?(suggestion: CopilotSuggestion, source: String, caret: Int) {
        let original = source as NSString
        let replacement = suggestion.text as NSString
        guard suggestion.source.utf16.elementsEqual(source.utf16), suggestion.caret == caret,
              EditorTextRange.isValid(suggestion.range, length: original.length),
              caret >= suggestion.range.location, caret - suggestion.range.location <= suggestion.range.length,
              EditorTextRange.isCharacterBoundary(caret, in: original),
              EditorTextRange.isCharacterBoundary(suggestion.range.location, in: original),
              EditorTextRange.isCharacterBoundary(suggestion.range.location + suggestion.range.length, in: original),
              replacement.length <= CopilotDocumentSnapshot.suggestionLimit else { return nil }
        let before = caret - suggestion.range.location
        let after = suggestion.range.length - before
        guard replacement.length > before + after,
              EditorTextRange.isCharacterBoundary(before, in: replacement),
              EditorTextRange.isCharacterBoundary(replacement.length - after, in: replacement) else { return nil }
        let prefix = original.substring(with: NSRange(location: suggestion.range.location, length: before))
        let suffix = original.substring(with: NSRange(location: caret, length: after))
        guard suggestion.text.utf16.prefix(before).elementsEqual(prefix.utf16),
              suggestion.text.utf16.suffix(after).elementsEqual(suffix.utf16) else { return nil }
        let insertion = replacement.substring(with: NSRange(location: before, length: replacement.length - before - after))
        guard !insertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              insertion.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count <= 8,
              !insertion.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
              }) else { return nil }
        range = NSRange(location: caret, length: 0)
        text = insertion
    }

    func hasRoomInSource(_ source: String) -> Bool {
        let original = source as NSString
        guard EditorTextRange.isValid(range, length: original.length) else { return false }
        var lineEnd = original.length
        original.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: range)
        let suffix = original.substring(with: NSRange(location: range.location, length: lineEnd - range.location))
        guard suffix.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if text.contains(where: \.isNewline) {
            let tail = original.substring(from: range.location)
            return tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

@MainActor
final class InlineCompletionController {
    typealias Provider = @MainActor (Document, UUID, String, Int) async -> CopilotSuggestion?

    private weak var editor: QuantaTextView?
    private weak var document: Document?
    private var sourceID: UUID?
    private let provider: Provider
    private let onShown: (CopilotSuggestion) -> Void
    private let onAccepted: (CopilotSuggestion) -> Void
    private let hasFocus: @MainActor (QuantaTextView) -> Bool
    private let preview = InlineCompletionPreview()
    private var revisionSubscription: AnyCancellable?
    private var storageSubscription: AnyCancellable?
    private var windowSubscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var presentationTimeout: Task<Void, Never>?
    private var presentationScheduled = false
    private var candidate: CopilotSuggestion?
    private var generation = 0
    private var applying = false
    private(set) var suggestion: CopilotSuggestion?
    private(set) var minimumEditorHeight: CGFloat = 0

    init(editor: QuantaTextView, provider: @escaping Provider,
         onShown: @escaping (CopilotSuggestion) -> Void = { _ in },
         onAccepted: @escaping (CopilotSuggestion) -> Void = { _ in },
         revisions: AnyPublisher<Int, Never>? = nil,
         hasFocus: @escaping @MainActor (QuantaTextView) -> Bool = {
             $0.window?.firstResponder === $0 && $0.window?.isKeyWindow == true && $0.window?.isVisible == true
         }) {
        self.editor = editor
        self.provider = provider
        self.onShown = onShown
        self.onAccepted = onAccepted
        self.hasFocus = hasFocus
        preview.isHidden = true
        editor.addSubview(preview)
        revisionSubscription = revisions?.dropFirst().sink { [weak self] _ in self?.dismiss() }
        storageSubscription = NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification,
                                                                    object: editor.textStorage)
            .sink { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                self?.dismiss()
            }
        windowChanged()
    }

    deinit {
        pending?.cancel()
        presentationTimeout?.cancel()
    }

    func bind(document: Document?, sourceID: UUID?) {
        guard self.document !== document || self.sourceID != sourceID else { return }
        dismiss()
        self.document = document
        self.sourceID = sourceID
    }

    func windowChanged() {
        dismiss()
        windowSubscriptions.removeAll()
        guard let window = editor?.window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.dismiss() }
                .store(in: &windowSubscriptions)
        }
    }

    func schedule(delay: TimeInterval = 0.35) {
        dismiss()
        guard !applying, let editor, isEligible(editor), let document, let sourceID else { return }
        let requestGeneration = generation
        let provider = provider
        pending = Task { [weak self, weak document] in
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            } catch { return }
            guard !Task.isCancelled, let document,
                  let snapshot = self?.snapshot(generation: requestGeneration) else { return }
            let result = await provider(document, sourceID, snapshot.source, snapshot.caret)
            guard !Task.isCancelled else { return }
            self?.receive(result, generation: requestGeneration)
        }
    }

    func dismiss() {
        generation += 1
        pending?.cancel()
        pending = nil
        presentationTimeout?.cancel()
        presentationTimeout = nil
        candidate = nil
        suggestion = nil
        preview.isHidden = true
        preview.setAccessibilityValue(nil)
        setMinimumEditorHeight(0)
    }

    func layoutDidChange() {
        guard candidate != nil, !presentationScheduled else { return }
        presentationScheduled = true
        let requestGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            guard self.generation == requestGeneration else { return }
            self.presentCandidate()
        }
    }

    @discardableResult
    func dismissVisibleSuggestion() -> Bool {
        let hadSuggestion = suggestion != nil && !preview.isHidden
        dismiss()
        return hadSuggestion
    }

    @discardableResult
    func accept() -> Bool {
        let requestGeneration = generation
        guard let editor, let suggestion, isEligible(editor),
              let edit = InlineCompletionEdit(suggestion: suggestion, source: editor.string,
                                              caret: editor.selectedRange().location),
              !preview.isHidden, let layout = previewLayout(for: edit, in: editor),
              editor.visibleRect.intersection(editor.bounds).contains(layout.frame) else {
            dismiss()
            return false
        }
        guard generation == requestGeneration, !preview.isHidden else { return false }
        let expected = (editor.string as NSString).replacingCharacters(in: edit.range, with: edit.text)
        dismiss()
        applying = true
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(edit.text, replacementRange: edit.range)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Accept Copilot Suggestion")
        editor.breakUndoCoalescing()
        applying = false
        guard editor.string.utf16.elementsEqual(expected.utf16) else { return false }
        onAccepted(suggestion)
        return true
    }

    private func isEligible(_ editor: QuantaTextView) -> Bool {
        editor.isEditable && !editor.isHiddenOrHasHiddenAncestor && !editor.hasMarkedText()
            && editor.selectedRanges.count == 1 && editor.selectedRange().length == 0
            && editor.snippetRanges.isEmpty && !CompletionPanel.shared.isShowing(for: editor) && hasFocus(editor)
    }

    private func snapshot(generation requestGeneration: Int) -> (source: String, caret: Int)? {
        guard generation == requestGeneration, let editor, isEligible(editor) else { return nil }
        let source = editor.string
        let caret = editor.selectedRange().location
        guard source.utf16.count <= CopilotDocumentSnapshot.contextLimit,
              EditorTextRange.isCharacterBoundary(caret, in: source as NSString) else { return nil }
        return (source, caret)
    }

    private func receive(_ result: CopilotSuggestion?, generation requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        pending = nil
        guard let result, let editor, isEligible(editor),
              let edit = InlineCompletionEdit(suggestion: result, source: editor.string,
                                              caret: editor.selectedRange().location),
              let layout = previewLayout(for: edit, in: editor) else { return }
        guard generation == requestGeneration else { return }
        candidate = result
        if editor.expandsForInlineCompletion {
            setMinimumEditorHeight(ceil(layout.frame.maxY + editor.textContainerInset.height))
        }
        if presentCandidate() { return }
        guard editor.expandsForInlineCompletion, generation == requestGeneration else {
            dismiss()
            return
        }
        layoutDidChange()
        presentationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.generation == requestGeneration, self.candidate != nil else { return }
            self.dismiss()
        }
    }

    private func setMinimumEditorHeight(_ height: CGFloat) {
        guard abs(minimumEditorHeight - height) > 0.5 else { return }
        minimumEditorHeight = height
        editor?.onLayoutChange?()
    }

    @discardableResult
    private func presentCandidate() -> Bool {
        let requestGeneration = generation
        guard let candidate, let editor, isEligible(editor),
              let edit = InlineCompletionEdit(suggestion: candidate, source: editor.string,
                                              caret: editor.selectedRange().location),
              let layout = previewLayout(for: edit, in: editor) else { return false }
        guard generation == requestGeneration, editor.bounds.contains(layout.frame) else { return false }
        if !editor.visibleRect.contains(layout.frame), editor.expandsForInlineCompletion {
            editor.scrollToVisible(layout.frame)
        }
        guard generation == requestGeneration, editor.visibleRect.contains(layout.frame) else { return false }
        preview.lines = layout.lines
        preview.lineHeight = layout.lineHeight
        preview.firstLineOffset = layout.firstLineOffset
        preview.frame = layout.frame
        preview.setAccessibilityValue(edit.text)
        preview.isHidden = false
        suggestion = candidate
        self.candidate = nil
        presentationTimeout?.cancel()
        presentationTimeout = nil
        onShown(candidate)
        return true
    }

    private struct PreviewLayout {
        let frame: NSRect
        let lines: [NSAttributedString]
        let firstLineOffset: CGFloat
        let lineHeight: CGFloat
    }

    private func previewLayout(for edit: InlineCompletionEdit, in editor: QuantaTextView) -> PreviewLayout? {
        guard edit.hasRoomInSource(editor.string), let window = editor.window else { return nil }
        let screenRect = editor.firstRect(forCharacterRange: edit.range, actualRange: nil)
        guard screenRect.minX.isFinite, screenRect.minY.isFinite, screenRect.height.isFinite,
              screenRect.height > 0 else { return nil }
        let caret = editor.convert(window.convertFromScreen(screenRect), from: nil)
        let font = editor.font ?? EditorTheme.font
        let paragraph = (editor.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let lines = edit.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
                NSAttributedString(string: String($0), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor,
                                                           .paragraphStyle: paragraph])
            }
        let origin = editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0)
        let left = lines.count > 1 ? min(origin, caret.minX) : caret.minX
        let firstLineOffset = caret.minX - left
        let width = lines.enumerated().map { $0.element.size().width + ($0.offset == 0 ? firstLineOffset : 0) }.max() ?? 0
        let lineHeight = max(caret.height, editor.layoutManager?.defaultLineHeight(for: font) ?? caret.height)
        let frame = NSRect(x: left, y: caret.minY, width: ceil(width), height: ceil(lineHeight * CGFloat(lines.count)))
        let available = editor.visibleRect.intersection(editor.bounds)
        guard !frame.isEmpty, frame.minX >= available.minX, frame.maxX <= available.maxX,
              frame.minY >= available.minY else { return nil }
        if let viewport = editor.enclosingScrollView?.contentView, frame.height > viewport.bounds.height { return nil }
        return PreviewLayout(frame: frame, lines: lines, firstLineOffset: firstLineOffset, lineHeight: lineHeight)
    }
}

private final class InlineCompletionPreview: NSView {
    var lines: [NSAttributedString] = [] { didSet { needsDisplay = true } }
    var firstLineOffset: CGFloat = 0
    var lineHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Copilot suggestion")
        setAccessibilityHelp("Press Tab to accept or Escape to dismiss.")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for (index, line) in lines.enumerated() {
            line.draw(at: NSPoint(x: index == 0 ? firstLineOffset : 0, y: CGFloat(index) * lineHeight))
        }
    }
}
