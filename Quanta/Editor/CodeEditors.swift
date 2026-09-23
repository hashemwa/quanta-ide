import AppKit
import SwiftUI

enum CodeEditorFactory {
    static func makeTextView() -> QuantaTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = QuantaTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = EditorTheme.font
        tv.textColor = EditorTheme.text
        tv.insertionPointColor = .controlAccentColor
        tv.typingAttributes = [.font: EditorTheme.font, .foregroundColor: EditorTheme.text]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.textContainerInset = NSSize(width: DS.Space.xs, height: DS.Space.s)
        tv.inlinePredictionType = .no
        tv.completionProvider = { code, cursor, reply in
            let app = AppState.shared
            app.requestCompletions(code: code, cursor: cursor) { matches, start, end in
                reply(matches.map { CodeCompletion(label: $0, range: NSRange(location: start, length: max(0, end - start))) })
            }
        }
        tv.inspectionProvider = { code, cursor, reply in
            AppState.shared.requestInspection(code: code, cursor: cursor, reply: reply)
        }
        return tv
    }
}

final class ScriptCanvas: NSObject, DocumentCanvas, NSTextViewDelegate {
    private weak var document: Document?
    private let scrollView = NSScrollView()
    private let textView = CodeEditorFactory.makeTextView()
    private let ruler: LineNumberRulerView
    private let undoManager = UndoManager()
    private var wrapsLines: Bool?

    var view: NSView { scrollView }

    init(document: Document) {
        self.document = document
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        super.init()
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        textView.string = document.text
        if let storage = textView.textStorage { PythonHighlighter.highlight(storage) }
        EditorRegistry.shared.register(textView, for: document.id)
        textView.onCommand = { [weak self] command in self?.perform(command) ?? false }
        textView.onFocusChange = { [weak self] focused in
            guard focused, let document = self?.document else { return }
            AppState.shared.activeDocumentID = document.id
        }
        textView.onLayoutChange = { [weak ruler] in ruler?.refreshMetrics() }

        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.verticalRulerView = ruler
    }

    func update(document: Document, showsLineNumbers: Bool, wrapsLines: Bool) {
        if scrollView.rulersVisible != showsLineNumbers {
            scrollView.hasVerticalRuler = showsLineNumbers
            scrollView.rulersVisible = showsLineNumbers
        }
        if self.wrapsLines != wrapsLines {
            self.wrapsLines = wrapsLines
            scrollView.hasHorizontalScroller = !wrapsLines
            textView.isHorizontallyResizable = !wrapsLines
            textView.autoresizingMask = wrapsLines ? [.width] : []
            textView.textContainer?.widthTracksTextView = wrapsLines
            textView.textContainer?.containerSize.width = wrapsLines
                ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude
        }
        guard textView.string != document.text, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        textView.string = document.text
        undoManager.removeAllActions()
        if let storage = textView.textStorage { PythonHighlighter.highlight(storage) }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        ruler.needsDisplay = true
    }

    func focus(in window: NSWindow) {
        window.makeFirstResponder(textView)
    }

    private func perform(_ command: EditorCommand) -> Bool {
        guard let document else { return false }
        switch command {
        case .runCellAndAdvance:
            AppState.shared.runSelectionOrLine(in: document, advance: true)
            return true
        case .runCell:
            AppState.shared.runSelectionOrLine(in: document, advance: false)
            return true
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    func textDidChange(_ notification: Notification) {
        defer { ruler.needsDisplay = true }
        guard let document, !textView.hasMarkedText() else { return }
        if document.text != textView.string {
            document.text = textView.string
            if !document.isDirty { document.isDirty = true }
        }
        if let storage = textView.textStorage {
            PythonHighlighter.highlight(storage, editedRange: textView.lastEditedRange)
        }
    }
}
