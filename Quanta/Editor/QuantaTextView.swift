import AppKit

enum EditorCommand: Equatable {
    case runCell
    case runCellAndAdvance
}

final class QuantaTextView: NSTextView {
    var onCommand: ((EditorCommand) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var completionProvider: ((String, Int, @escaping ([String], Int, Int) -> Void) -> Void)?
    var inspectionProvider: ((String, Int, @escaping (InspectionInfo?) -> Void) -> Void)?
    private(set) var lastEditedRange = NSRange(location: 0, length: 0)

    override func shouldChangeText(in affectedCharRange: NSRange,
                                   replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok {
            lastEditedRange = NSRange(location: affectedCharRange.location,
                                      length: (replacementString as NSString?)?.length ?? 0)
        }
        return ok
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            CompletionPanel.shared.hide()
            onFocusChange?(false)
        }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayoutChange?()
    }

    override func keyDown(with event: NSEvent) {
        if CompletionPanel.shared.handle(event, for: self) { return }
        let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
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
        super.didChangeText()
        if CompletionPanel.shared.isShowing(for: self) {
            CompletionPanel.shared.refresh(from: self)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if let text = string as? String, text == ".", dotIsAttributeAccess() {
            requestCompletions()
        }
    }

    override func mouseDown(with event: NSEvent) {
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
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        CompletionPanel.shared.caretMoved(in: self)
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
        guard let completionProvider else { return }
        let caret = selectedRange().location
        completionProvider(self.string, caret) { [weak self] matches, start, _ in
            guard let self, self.window != nil,
                  self.window?.firstResponder === self,
                  self.selectedRange().location >= start else { return }
            CompletionPanel.shared.show(matches: matches, start: start, for: self)
        }
    }

    private func requestDocumentation() -> Bool {
        guard let inspectionProvider, AppState.shared.kernelStatus == .idle else { return false }
        let caret = selectedRange().location
        inspectionProvider(self.string, caret) { [weak self] info in
            guard let self, self.window != nil, let info else { return }
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
               CharacterSet.alphanumerics.contains(scalar) || previous == "_" || previous == ")",
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
