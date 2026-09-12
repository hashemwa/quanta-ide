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
        tv.typingAttributes = [.font: EditorTheme.font, .foregroundColor: EditorTheme.text]
        tv.textContainerInset = NSSize(width: DS.Space.xs, height: DS.Space.s)
        tv.completionProvider = { code, cursor, reply in
            AppState.shared.requestCompletions(code: code, cursor: cursor, reply: reply)
        }
        tv.inspectionProvider = { code, cursor, reply in
            AppState.shared.requestInspection(code: code, cursor: cursor, reply: reply)
        }
        return tv
    }
}

struct ScrollingCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var documentID: UUID? = nil
    var onCommand: ((EditorCommand) -> Bool)? = nil
    var onFocus: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = CodeEditorFactory.makeTextView()
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        tv.string = text
        if let storage = tv.textStorage { PythonHighlighter.highlight(storage) }
        if let documentID { EditorRegistry.shared.register(tv, for: documentID) }

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background

        let ruler = LineNumberRulerView(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        let coordinator = context.coordinator
        coordinator.textView = tv
        coordinator.ruler = ruler
        tv.onFocusChange = { [weak coordinator] focused in
            if focused { coordinator?.parent.onFocus?() }
        }
        tv.onLayoutChange = { [weak ruler] in
            ruler?.refreshMetrics()
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        tv.onCommand = onCommand
        if tv.string != text, !tv.hasMarkedText() {
            let sel = tv.selectedRange()
            tv.string = text
            context.coordinator.undoManager.removeAllActions()
            if let storage = tv.textStorage { PythonHighlighter.highlight(storage) }
            let length = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, length), length: 0))
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollingCodeEditor
        weak var textView: QuantaTextView?
        weak var ruler: LineNumberRulerView?
        let undoManager = UndoManager()

        init(_ parent: ScrollingCodeEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if !tv.hasMarkedText() {
                parent.text = tv.string
                if let storage = tv.textStorage {
                    PythonHighlighter.highlight(storage, editedRange: tv.lastEditedRange)
                }
            }
            ruler?.needsDisplay = true
        }
    }
}

struct GrowingCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var cellID: UUID? = nil
    var onCommand: ((EditorCommand) -> Bool)? = nil
    var onFocus: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> QuantaTextView {
        let tv = CodeEditorFactory.makeTextView()
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        tv.string = text
        if let storage = tv.textStorage { PythonHighlighter.highlight(storage) }
        if let cellID { EditorRegistry.shared.register(tv, for: cellID) }

        let coordinator = context.coordinator
        coordinator.textView = tv
        tv.onFocusChange = { [weak coordinator] focused in
            if focused { coordinator?.parent.onFocus?() }
        }
        tv.onLayoutChange = { [weak coordinator] in
            coordinator?.scheduleMeasure()
        }
        return tv
    }

    func updateNSView(_ tv: QuantaTextView, context: Context) {
        context.coordinator.parent = self
        tv.onCommand = onCommand
        tv.onEscape = onEscape
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            context.coordinator.undoManager.removeAllActions()
            if let storage = tv.textStorage { PythonHighlighter.highlight(storage) }
        }
        context.coordinator.scheduleMeasure()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingCodeEditor
        weak var textView: QuantaTextView?
        private var measureScheduled = false
        let undoManager = UndoManager()

        init(_ parent: GrowingCodeEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if !tv.hasMarkedText() {
                parent.text = tv.string
                if let storage = tv.textStorage {
                    PythonHighlighter.highlight(storage, editedRange: tv.lastEditedRange)
                }
            }
            scheduleMeasure()
        }

        func scheduleMeasure() {
            guard !measureScheduled else { return }
            measureScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.measureScheduled = false
                self?.measureNow()
            }
        }

        private func measureNow() {
            guard let tv = textView,
                  let layoutManager = tv.layoutManager,
                  let container = tv.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let newHeight = max(used.height + tv.textContainerInset.height * 2 + 2, 30)
            if abs(newHeight - parent.height) > 0.5 {
                parent.height = newHeight
            }
        }
    }
}
