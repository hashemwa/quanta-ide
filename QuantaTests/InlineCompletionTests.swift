import AppKit
import Combine
import XCTest
@testable import Quanta

@MainActor
final class InlineCompletionTests: XCTestCase {
    private struct Fixture {
        let editor: QuantaTextView
        let document: Document
        let container: NSView
        let window: NSWindow
    }

    private func fixture(source: String) -> Fixture {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        let editor = CodeEditorFactory.makeTextView()
        editor.frame = container.bounds
        editor.string = source
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        container.addSubview(editor)
        addTeardownBlock {
            MainActor.assumeIsolated {
                editor.inlineCompletionController?.dismiss()
                window.close()
            }
        }
        return Fixture(editor: editor, document: Document(script: nil, text: source), container: container, window: window)
    }

    private func controller(in fixture: Fixture, provider: @escaping InlineCompletionController.Provider,
                            onShown: @escaping (CopilotSuggestion) -> Void = { _ in },
                            onAccepted: @escaping (CopilotSuggestion) -> Void = { _ in },
                            revisions: AnyPublisher<Int, Never>? = nil) -> InlineCompletionController {
        let controller = InlineCompletionController(editor: fixture.editor, provider: provider,
            onShown: onShown, onAccepted: onAccepted, revisions: revisions, hasFocus: { _ in true })
        fixture.editor.inlineCompletionController = controller
        controller.bind(document: fixture.document, sourceID: fixture.document.id)
        return controller
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    private func key(_ code: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func cellView(containing editor: QuantaTextView) -> NotebookCellAppKitView? {
        var view = editor.superview
        while let current = view {
            if let cellView = current as? NotebookCellAppKitView { return cellView }
            view = current.superview
        }
        return nil
    }

    func testPrefixAndSuffixPreservingSuggestionsBecomePureInsertions() throws {
        let prefix = CopilotSuggestion(source: "pri", caret: 3, range: NSRange(location: 0, length: 3), text: "print(1)")
        let edit = try XCTUnwrap(InlineCompletionEdit(suggestion: prefix, source: "pri", caret: 3))
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 0))
        XCTAssertEqual(edit.text, "nt(1)")
        let suffix = CopilotSuggestion(source: "print()", caret: 6, range: NSRange(location: 0, length: 7), text: "print('value')")
        XCTAssertEqual(InlineCompletionEdit(suggestion: suffix, source: "print()", caret: 6)?.text, "'value'")
    }

    func testSuggestionsCannotDeleteOrReplaceExistingCode() {
        for text in ["other", "pr", "pri"] {
            let suggestion = CopilotSuggestion(source: "pri", caret: 3, range: NSRange(location: 0, length: 3), text: text)
            XCTAssertNil(InlineCompletionEdit(suggestion: suggestion, source: "pri", caret: 3))
        }
        let suggestion = CopilotSuggestion(source: "print()", caret: 6, range: NSRange(location: 0, length: 7), text: "print('value']")
        XCTAssertNil(InlineCompletionEdit(suggestion: suggestion, source: "print()", caret: 6))
    }

    func testSuggestionBoundsRejectStaleTextOverflowAndSplitCharacters() {
        let source = "👩🏽‍💻é"
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: Int.max),
                      NSRange(location: -1, length: 0), NSRange(location: 1, length: 0)] {
            let suggestion = CopilotSuggestion(source: source, caret: range.location, range: range, text: "value")
            XCTAssertNil(InlineCompletionEdit(suggestion: suggestion, source: source, caret: range.location))
        }
        let end = source.utf16.count
        let suggestion = CopilotSuggestion(source: source, caret: end, range: NSRange(location: end, length: 0), text: " + 1")
        XCTAssertNotNil(InlineCompletionEdit(suggestion: suggestion, source: source, caret: end))
        XCTAssertNil(InlineCompletionEdit(suggestion: suggestion, source: source + "x", caret: end))
        XCTAssertNil(InlineCompletionEdit(suggestion: suggestion, source: source, caret: end - 1))
        let combining = CopilotSuggestion(source: "e", caret: 1, range: NSRange(location: 0, length: 1), text: "éx")
        XCTAssertNil(InlineCompletionEdit(suggestion: combining, source: "e", caret: 1))
    }

    func testPreviewNeverCoversExistingCodeOrAcceptsHugeInvisibleText() throws {
        let middle = CopilotSuggestion(source: "print()", caret: 6, range: NSRange(location: 6, length: 0), text: "1")
        let edit = try XCTUnwrap(InlineCompletionEdit(suggestion: middle, source: "print()", caret: 6))
        XCTAssertFalse(edit.hasRoomInSource("print()"))
        let multiline = CopilotSuggestion(source: "value\nnext = 1", caret: 5, range: NSRange(location: 5, length: 0), text: " = 1\nother = 2")
        XCTAssertFalse(try XCTUnwrap(InlineCompletionEdit(suggestion: multiline, source: multiline.source, caret: 5))
            .hasRoomInSource(multiline.source))
        let huge = CopilotSuggestion(source: "", caret: 0, range: NSRange(location: 0, length: 0),
                                     text: String(repeating: "x", count: CopilotDocumentSnapshot.suggestionLimit + 1))
        XCTAssertNil(InlineCompletionEdit(suggestion: huge, source: "", caret: 0))
    }

    func testShowingAndDismissingSuggestionDoNotEditTextStorageOrUndo() async throws {
        let fixture = fixture(source: "pri")
        let before = NSAttributedString(attributedString: try XCTUnwrap(fixture.editor.textStorage))
        var shown = 0
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: 0, length: caret), text: "print(1)")
        }, onShown: { _ in shown += 1 })
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(fixture.editor.string, "pri")
        XCTAssertEqual(fixture.document.text, "pri")
        XCTAssertTrue(before.isEqual(to: try XCTUnwrap(fixture.editor.textStorage)))
        XCTAssertFalse(fixture.editor.undoManager?.canUndo ?? false)
        XCTAssertTrue(controller.dismissVisibleSuggestion())
        XCTAssertFalse(controller.dismissVisibleSuggestion())
        XCTAssertEqual(fixture.editor.string, "pri")
    }

    func testHighlightingDoesNotDismissAnUnchangedSuggestion() async throws {
        let fixture = fixture(source: "value =")
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: caret, length: 0), text: " 42")
        })
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        fixture.editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                                 range: NSRange(location: 0, length: 5))
        XCTAssertNotNil(controller.suggestion)
        XCTAssertEqual(fixture.editor.string, "value =")
    }

    func testMultilineNotebookPreviewExpandsWithoutChangingSourceOrCachedHeight() async throws {
        let cell = NotebookCell(type: .code, source: "def summarize(values):")
        let nextCell = NotebookCell(type: .code, source: "data = [1, 2, 3]")
        let notebook = Notebook(cells: [cell, nextCell], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: EditorTheme.fontSize - 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas.view
        defer { window.close() }
        for _ in 0..<10 {
            canvas.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        let nextEditor = try XCTUnwrap(EditorRegistry.shared.view(for: nextCell.id))
        let cellView = try XCTUnwrap(self.cellView(containing: editor))
        let nextCellView = try XCTUnwrap(self.cellView(containing: nextEditor))
        XCTAssertTrue(cellView.superview === nextCellView.superview)
        let initialCellFrame = cellView.frame
        let initialNextCellFrame = nextCellView.frame
        let initialGap = initialNextCellFrame.minY - initialCellFrame.maxY
        XCTAssertEqual(initialGap, DS.Layout.notebookCellSpacing, accuracy: 0.5)
        let initialHeight = editor.bounds.height
        let cachedHeight = cell.editorHeight
        let wasDirty = document.isDirty
        editor.setSelectedRange(NSRange(location: cell.source.utf16.count, length: 0))
        let controller = InlineCompletionController(editor: editor, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: caret, length: 0),
                               text: "\n    total = sum(values)\n    return total / len(values)")
        }, hasFocus: { _ in true })
        editor.inlineCompletionController = controller
        controller.bind(document: document, sourceID: cell.id)
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        let preview = try XCTUnwrap(editor.subviews.first { !$0.isHidden && $0.accessibilityLabel() == "Copilot suggestion" })
        XCTAssertGreaterThan(editor.bounds.height, initialHeight + 20)
        XCTAssertTrue(editor.visibleRect.intersection(editor.bounds).contains(preview.frame))
        XCTAssertEqual(preview.frame.minX, editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0), accuracy: 0.5)
        XCTAssertEqual(cell.source, "def summarize(values):")
        XCTAssertEqual(editor.string, cell.source)
        XCTAssertEqual(document.isDirty, wasDirty)
        XCTAssertEqual(cell.editorHeight, cachedHeight, accuracy: 0.5)
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
        XCTAssertTrue(cellView.bounds.contains(cellView.convert(preview.bounds, from: preview)))
        let cellGrowth = cellView.frame.height - initialCellFrame.height
        XCTAssertGreaterThan(cellGrowth, 0)
        XCTAssertEqual(nextCellView.frame.minY - initialNextCellFrame.minY, cellGrowth, accuracy: 0.5)
        XCTAssertEqual(nextCellView.frame.minY - cellView.frame.maxY, initialGap, accuracy: 0.5)
        XCTAssertTrue(controller.dismissVisibleSuggestion())
        try await waitUntil {
            abs(editor.bounds.height - initialHeight) < 0.5
                && abs(nextCellView.frame.minY - initialNextCellFrame.minY) < 0.5
        }
        XCTAssertEqual(cellView.frame.height, initialCellFrame.height, accuracy: 0.5)
        XCTAssertEqual(editor.inlineCompletionMinimumHeight, 0)
        XCTAssertEqual(cell.source, "def summarize(values):")
        withExtendedLifetime(canvas) {}
    }

    func testTabAcceptsOneUndoableEdit() async throws {
        let fixture = fixture(source: "pri")
        var accepted = 0
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: 0, length: caret), text: "print(1)")
        }, onAccepted: { _ in accepted += 1 })
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        let undo = try XCTUnwrap(fixture.editor.undoManager)
        undo.beginUndoGrouping()
        fixture.editor.keyDown(with: try key(48, characters: "\t", in: fixture.window))
        undo.endUndoGrouping()
        XCTAssertEqual(fixture.editor.string, "print(1)")
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(undo.undoActionName, "Accept Copilot Suggestion")
        undo.undo()
        XCTAssertEqual(fixture.editor.string, "pri")
        undo.redo()
        XCTAssertEqual(fixture.editor.string, "print(1)")
    }

    func testEscapeDismissesSuggestionBeforeLeavingTheCell() async throws {
        let fixture = fixture(source: "value =")
        var escaped = 0
        fixture.editor.onEscape = { escaped += 1 }
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: caret, length: 0), text: " 42")
        })
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        let escape = try key(53, characters: "\u{1B}", in: fixture.window)
        fixture.editor.keyDown(with: escape)
        XCTAssertNil(controller.suggestion)
        XCTAssertEqual(escaped, 0)
        fixture.editor.keyDown(with: escape)
        XCTAssertEqual(escaped, 1)
    }

    func testEditCancelsAnUncooperativeStaleProviderResponse() async throws {
        let fixture = fixture(source: "value =")
        var reply: CheckedContinuation<CopilotSuggestion?, Never>?
        let controller = controller(in: fixture, provider: { _, _, _, _ in
            await withCheckedContinuation { reply = $0 }
        })
        controller.schedule(delay: 0)
        try await waitUntil { reply != nil }
        fixture.editor.insertText(" 1", replacementRange: fixture.editor.selectedRange())
        controller.dismiss()
        reply?.resume(returning: CopilotSuggestion(source: "value =", caret: 7, range: NSRange(location: 7, length: 0), text: " 42"))
        reply = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.suggestion)
        XCTAssertFalse(controller.accept())
        XCTAssertEqual(fixture.editor.string, "value = 1")
    }

    func testCaretMovesHiddenAncestorsAndRevisionChangesInvalidateSuggestions() async throws {
        let fixture = fixture(source: "value =")
        let revision = CurrentValueSubject<Int, Never>(0)
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: caret, length: 0), text: " 42")
        }, revisions: revision.eraseToAnyPublisher())
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(controller.suggestion)
        fixture.editor.setSelectedRange(NSRange(location: 7, length: 0))
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        revision.send(1)
        XCTAssertNil(controller.suggestion)
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        fixture.container.isHidden = true
        XCTAssertFalse(controller.accept())
        XCTAssertNil(controller.suggestion)
    }

    func testMarkedTextAndSnippetNavigationTakePriority() async throws {
        let fixture = fixture(source: "value =")
        let controller = controller(in: fixture, provider: { _, _, source, caret in
            CopilotSuggestion(source: source, caret: caret, range: NSRange(location: caret, length: 0), text: " 42")
        })
        fixture.editor.snippetRanges = [NSRange(location: 0, length: 5)]
        controller.schedule(delay: 0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.suggestion)
        fixture.editor.snippetRanges = []
        controller.schedule(delay: 0)
        try await waitUntil { controller.suggestion != nil }
        fixture.editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(controller.suggestion)
        XCTAssertFalse(controller.accept())
        fixture.editor.unmarkText()
    }

    func testMalformedReplacementAndSelectionRangesAreIgnored() {
        let fixture = fixture(source: "value")
        let selection = fixture.editor.selectedRange()
        fixture.editor.insertText("lost", replacementRange: NSRange(location: 2, length: Int.max))
        fixture.editor.setSelectedRanges([NSValue(range: NSRange(location: NSNotFound, length: 0))],
                                         affinity: .downstream, stillSelecting: false)
        XCTAssertFalse(fixture.editor.shouldChangeText(in: NSRange(location: 0, length: Int.max), replacementString: "lost"))
        XCTAssertEqual(fixture.editor.string, "value")
        XCTAssertEqual(fixture.editor.selectedRange(), selection)
    }

    func testInvalidSnippetRangesDoNotOverflowOnTab() throws {
        let fixture = fixture(source: "value")
        fixture.editor.snippetRanges = [NSRange(location: NSNotFound, length: Int.max), NSRange(location: 0, length: 5)]
        fixture.editor.keyDown(with: try key(48, characters: "\t", in: fixture.window))
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(fixture.editor.string, "value")
    }

    func testInvalidSnippetRangesDoNotOverflowWhileTyping() {
        let fixture = fixture(source: "value")
        fixture.editor.snippetRanges = [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max),
                                        NSRange(location: 0, length: 5)]
        fixture.editor.insertText("new_", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.editor.string, "new_value")
        XCTAssertEqual(fixture.editor.snippetRanges, [NSRange(location: 4, length: 5)])
    }
}
