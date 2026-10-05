import AppKit
import Combine

enum EditorCommand: Equatable {
    case runCell
    case runCellAndAdvance
}

final class QuantaTextView: NSTextView {
    var onCommand: ((EditorCommand) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var completionProvider: ((String, Int, @escaping ([CodeCompletion]) -> Void) -> Void)?
    var inspectionProvider: ((String, Int, @escaping (InspectionInfo?) -> Void) -> Void)?
    var snippetRanges: [NSRange] = []
    var completionSources: (() -> [String])?
    var inlineCompletionController: InlineCompletionController?
    var expandsForInlineCompletion = false
    var inlineCompletionMinimumHeight: CGFloat { inlineCompletionController?.minimumEditorHeight ?? 0 }
    private weak var diagnosticsDocument: Document?
    private var diagnosticsSourceID: UUID?
    private var diagnosticsSubscription: AnyCancellable?
    private var completionWork: DispatchWorkItem?
    private var completionGeneration = 0
    private(set) var lastEditedRange = NSRange(location: 0, length: 0)

    override func shouldChangeText(in affectedCharRange: NSRange,
                                   replacementString: String?) -> Bool {
        let length = textStorage?.length ?? string.utf16.count
        guard EditorTextRange.isValid(affectedCharRange, length: length) else { return false }
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok {
            inlineCompletionController?.dismiss()
            let delta = (replacementString?.utf16.count ?? 0) - affectedCharRange.length
            snippetRanges = snippetRanges.compactMap { range in
                guard EditorTextRange.isValid(range, length: length), range.location >= NSMaxRange(affectedCharRange) else { return nil }
                return NSRange(location: range.location + delta, length: range.length)
            }
            lastEditedRange = NSRange(location: affectedCharRange.location,
                                      length: (replacementString as NSString?)?.length ?? 0)
        }
        return ok
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            inlineCompletionController?.schedule()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            inlineCompletionController?.dismiss()
            CompletionPanel.shared.hide()
            onFocusChange?(false)
        }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        if widthChanged { inlineCompletionController?.dismiss() }
        super.setFrameSize(newSize)
        inlineCompletionController?.layoutDidChange()
        if widthChanged { onLayoutChange?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completionWork?.cancel(); completionGeneration += 1; snippetRanges = [] }
        if CompletionPanel.shared.handle(event, for: self) {
            inlineCompletionController?.dismiss()
            return
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, !snippetRanges.isEmpty {
            inlineCompletionController?.dismiss()
            while !snippetRanges.isEmpty {
                let range = snippetRanges.removeFirst()
                if EditorTextRange.isValid(range, length: string.utf16.count) { setSelectedRange(range); return }
            }
        }
        let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 48, chord.isEmpty, inlineCompletionController?.accept() == true { return }
        if event.keyCode == 53, chord.isEmpty, inlineCompletionController?.dismissVisibleSuggestion() == true { return }
        if event.keyCode == 53, chord.isEmpty, !hasMarkedText(), let onEscape {
            onEscape()
            return
        }
        if (event.keyCode == 116 || event.keyCode == 121), chord.isEmpty, onEscape != nil {
            NotebookScrolling.page(up: event.keyCode == 116, in: window)
            return
        }
        if event.keyCode == 49, event.modifierFlags.contains(.control) {
            requestCompletions()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 36, chord == .shift || chord == .command, let onCommand {
            if CompletionPanel.shared.isShowing(for: self) { CompletionPanel.shared.hide() }
            if onCommand(chord == .shift ? .runCellAndAdvance : .runCell) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func didChangeText() {
        clearPythonDiagnostics()
        completionWork?.cancel()
        completionGeneration += 1
        super.didChangeText()
        if CompletionPanel.shared.isShowing(for: self) {
            CompletionPanel.shared.refresh(from: self)
        }
        inlineCompletionController?.schedule()
    }

    func bindCodeTools(document: Document, sourceID: UUID, isPython: Bool = true) {
        if isPython, inlineCompletionController == nil {
            let service = CopilotService.shared
            inlineCompletionController = InlineCompletionController(editor: self, provider: {
                await service.completion(document: $0, sourceID: $1, source: $2, caret: $3)
            }, onShown: { service.didShow($0) }, onAccepted: { service.accept($0) },
               revisions: service.$revision.eraseToAnyPublisher())
        }
        inlineCompletionController?.bind(document: isPython ? document : nil, sourceID: isPython ? sourceID : nil)
        guard diagnosticsDocument !== document || diagnosticsSourceID != sourceID || !isPython else { return }
        diagnosticsSubscription = nil
        clearPythonDiagnostics()
        diagnosticsDocument = isPython ? document : nil
        diagnosticsSourceID = isPython ? sourceID : nil
        completionSources = isPython ? { [weak document] in document?.pythonSources.map(\.source) ?? [] } : nil
        guard isPython else { return }
        let state = document.codeTools
        diagnosticsSubscription = state.$diagnostics.sink { [weak self, weak state] diagnostics in
            guard let self, let state else { return }
            self.clearPythonDiagnostics()
            guard state.checkedSources[sourceID] == self.string, let layoutManager = self.layoutManager else { return }
            for diagnostic in diagnostics where diagnostic.sourceID == sourceID {
                let range = diagnostic.editorRange(in: self.string)
                guard range.length > 0 else { continue }
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemOrange
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], forCharacterRange: range)
            }
        }
    }

    private func clearPythonDiagnostics() {
        let range = NSRange(location: 0, length: string.utf16.count)
        for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .toolTip] {
            layoutManager?.removeTemporaryAttribute(key, forCharacterRange: range)
        }
    }

    func applyPythonFormatting(original: String, formatted: String) -> Bool {
        guard string == original, !hasMarkedText() else { return false }
        let selection = selectedRange()
        breakUndoCoalescing()
        insertText(formatted, replacementRange: NSRange(location: 0, length: original.utf16.count))
        undoManager?.setActionName("Format Code")
        breakUndoCoalescing()
        let text = formatted as NSString
        let offset = min(selection.location, text.length)
        let caret = offset < text.length ? text.rangeOfComposedCharacterSequence(at: offset).location : offset
        setSelectedRange(NSRange(location: caret, length: 0))
        return string == formatted
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        guard replacementRange.location == NSNotFound && replacementRange.length == 0
                || EditorTextRange.isValid(replacementRange, length: textStorage?.length ?? string.utf16.count) else { return }
        super.insertText(value, replacementRange: replacementRange)
        completionWork?.cancel()
        guard let text = value as? String, text.count == 1, !hasMarkedText(),
              PythonHighlighter.allowsCompletion(in: string, at: selectedRange().location) else { return }
        if text == "(" || text == "," { requestDocumentation(); return }
        guard let last = text.last, last.isLetter || last.isNumber || last == "_" || (last == "." && dotIsAttributeAccess()) else { return }
        let work = DispatchWorkItem { [weak self] in self?.requestCompletions() }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inlineCompletionController?.dismiss()
        completionWork?.cancel()
        completionGeneration += 1
        CompletionPanel.shared.hide()
        super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
        onLayoutChange?()
    }

    override func mouseDown(with event: NSEvent) {
        inlineCompletionController?.dismiss()
        completionWork?.cancel()
        completionGeneration += 1
        snippetRanges = []
        CompletionPanel.shared.hide()
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if CursorZoneView.contains(windowPoint: event.locationInWindow, in: window) {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if CursorZoneView.contains(windowPoint: event.locationInWindow, in: window) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        let length = textStorage?.length ?? string.utf16.count
        guard !ranges.isEmpty, ranges.allSatisfy({ EditorTextRange.isValid($0.rangeValue, length: length) }) else { return }
        let previous = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if selectedRanges != previous { inlineCompletionController?.dismiss() }
        CompletionPanel.shared.caretMoved(in: self)
    }

    override func viewDidHide() {
        inlineCompletionController?.dismiss()
        completionWork?.cancel()
        completionGeneration += 1
        super.viewDidHide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        inlineCompletionController?.windowChanged()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        inlineCompletionController?.dismiss()
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func dotIsAttributeAccess() -> Bool {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret >= 2 else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: caret - 1, length: 0))
        let head = ns.substring(with: NSRange(location: lineRange.location,
                                              length: caret - 1 - lineRange.location))
        var inSingle = false, inDouble = false, escaped = false
        for ch in head {
            if escaped { escaped = false; continue }
            switch ch {
            case "\\": escaped = inSingle || inDouble
            case "'": if !inDouble { inSingle.toggle() }
            case "\"": if !inSingle { inDouble.toggle() }
            case "#": if !inSingle && !inDouble { return false }
            default: break
            }
        }
        if inSingle || inDouble { return false }
        guard let last = head.last else { return false }
        if last.isNumber {
            let token = head.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return token.contains { $0.isLetter || $0 == "_" }
        }
        return last.isLetter || last == "_" || last == ")" || last == "]" || last == "\""
            || last == "'"
    }

    func requestCompletions() {
        guard let completionProvider, !hasMarkedText(), !isHiddenOrHasHiddenAncestor,
              selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let source = string
        completionGeneration += 1
        let generation = completionGeneration
        completionProvider(source, caret) { [weak self] matches in
            guard let self, self.completionGeneration == generation, self.window != nil,
                  self.window?.firstResponder === self, !self.isHiddenOrHasHiddenAncestor,
                  !self.hasMarkedText(), self.selectedRange() == NSRange(location: caret, length: 0),
                  self.string == source else { return }
            CompletionPanel.shared.show(matches: matches, for: self)
            if CompletionPanel.shared.isShowing(for: self) { self.inlineCompletionController?.dismiss() }
        }
    }

    @discardableResult
    func requestDocumentation() -> Bool {
        guard let inspectionProvider else { return false }
        let caret = selectedRange().location
        let source = string
        inspectionProvider(source, caret) { [weak self] info in
            guard let self, self.window?.firstResponder === self, self.string == source,
                  self.selectedRange().location == caret, let info else { return }
            DocumentationPopover.show(info, for: self)
        }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let headLength = max(0, sel.location - lineRange.location)
        let head = ns.substring(with: NSRange(location: lineRange.location, length: headLength))
        var indent = ""
        for ch in head {
            if ch == " " || ch == "\t" { indent.append(ch) } else { break }
        }
        if head.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            indent += "    "
        }
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0 {
            shiftSelectedLines(indent: true)
        } else {
            insertText("    ", replacementRange: sel)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0 {
            let ns = string as NSString
            let previous = ns.substring(with: NSRange(location: sel.location - 1, length: 1))
            if let scalar = previous.unicodeScalars.first,
               CharacterSet.alphanumerics.contains(scalar) || previous == "_" || previous == ")" || previous == "(" || previous == ",",
               requestDocumentation() {
                return
            }
        }
        shiftSelectedLines(indent: false)
    }

    private func shiftSelectedLines(indent: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        let lines = ns.lineRange(for: sel)
        let block = ns.substring(with: lines)
        var lineStrings = block.components(separatedBy: "\n")
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline { lineStrings.removeLast() }
        guard !lineStrings.isEmpty else {
            if indent { insertText("    ", replacementRange: sel) }
            return
        }

        var newText = ""
        var firstDelta = 0
        var totalDelta = 0
        for (idx, line) in lineStrings.enumerated() {
            var newLine = line
            if indent {
                newLine = "    " + line
            } else {
                var removed = 0
                while removed < 4, newLine.hasPrefix(" ") {
                    newLine.removeFirst()
                    removed += 1
                }
                if removed == 0, newLine.hasPrefix("\t") {
                    newLine.removeFirst()
                }
            }
            let delta = newLine.utf16.count - line.utf16.count
            if idx == 0 { firstDelta = delta }
            totalDelta += delta
            newText += newLine
            if idx < lineStrings.count - 1 || hadTrailingNewline { newText += "\n" }
        }

        guard shouldChangeText(in: lines, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: lines, with: newText)
        didChangeText()
        let docLength = (string as NSString).length
        let newLocation = min(max(lines.location, sel.location + firstDelta), docLength)
        let newLength = max(0, min(sel.length + totalDelta - firstDelta, docLength - newLocation))
        setSelectedRange(NSRange(location: newLocation, length: newLength))
    }

    func toggleComment() {
        let ns = string as NSString
        let sel = selectedRange()
        let lines = ns.lineRange(for: sel)
        let block = ns.substring(with: lines)
        var lineStrings = block.components(separatedBy: "\n")
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline { lineStrings.removeLast() }
        guard !lineStrings.isEmpty else { return }

        let nonEmpty = lineStrings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        var newLines: [String] = []
        var firstDelta = 0
        var firstEditOffset = 0
        var totalDelta = 0
        for (idx, line) in lineStrings.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var newLine = line
            var editOffset = 0
            if allCommented {
                if let hashIndex = line.firstIndex(of: "#") {
                    var rest = String(line[line.index(after: hashIndex)...])
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    newLine = String(line[..<hashIndex]) + rest
                    editOffset = line[..<hashIndex].utf16.count
                }
            } else if !trimmed.isEmpty {
                newLine = "# " + line
            }
            let delta = newLine.utf16.count - line.utf16.count
            if idx == 0 {
                firstDelta = delta
                firstEditOffset = editOffset
            }
            totalDelta += delta
            newLines.append(newLine)
        }
        var newText = newLines.joined(separator: "\n")
        if hadTrailingNewline { newText += "\n" }

        guard shouldChangeText(in: lines, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: lines, with: newText)
        didChangeText()
        let docLength = (string as NSString).length
        let caretColumn = sel.location - lines.location
        let caretFollowsEdit = allCommented ? caretColumn > firstEditOffset : caretColumn >= firstEditOffset
        let shift = caretFollowsEdit ? firstDelta : 0
        let newLocation = min(max(lines.location, sel.location + shift), docLength)
        let newLength = max(0, min(sel.length + totalDelta - shift, docLength - newLocation))
        setSelectedRange(NSRange(location: newLocation, length: newLength))
    }
}
