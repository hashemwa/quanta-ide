import AppKit
import XCTest
@testable import Quanta

@MainActor
final class EditorRenderingTests: XCTestCase {
    private final class StorageEdits: NSObject, NSTextStorageDelegate {
        var ranges: [NSRange] = []

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            ranges.append(editedRange)
        }
    }

    func testTypingDoesNotRestyleUnchangedTextOrResetFonts() throws {
        let storage = NSTextStorage(string: "import numpy as np\nvalue = 1\nother = 2")
        PythonHighlighter.highlight(storage)
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: full)
        let edits = StorageEdits()
        storage.delegate = edits
        let location = (storage.string as NSString).range(of: "value").location
        storage.replaceCharacters(in: NSRange(location: location + 5, length: 0), with: "s")
        edits.ranges = []
        PythonHighlighter.highlight(storage, editedRange: NSRange(location: location + 5, length: 1))
        XCTAssertTrue(edits.ranges.isEmpty)
        XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(storage.attribute(.font, at: location + 5, effectiveRange: nil) as? NSFont, font)
    }

    func testColorEditsOnlyInvalidateChangedTokenAndPropagateMultilineChanges() {
        let storage = NSTextStorage(string: "value = 1\nprinx(value)\nother = 2")
        PythonHighlighter.highlight(storage)
        let call = (storage.string as NSString).range(of: "prinx")
        storage.replaceCharacters(in: NSRange(location: call.location + 4, length: 1), with: "t")
        let edits = StorageEdits()
        storage.delegate = edits
        PythonHighlighter.highlight(storage, editedRange: call)
        XCTAssertEqual(edits.ranges, [call])
        XCTAssertEqual(storage.attribute(.foregroundColor, at: call.location, effectiveRange: nil) as? NSColor, EditorTheme.builtin)
        storage.insert(NSAttributedString(string: "\"\"\""), at: 0)
        PythonHighlighter.highlight(storage, editedRange: NSRange(location: 0, length: 3))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: storage.length - 1, effectiveRange: nil) as? NSColor, EditorTheme.string)
        storage.deleteCharacters(in: NSRange(location: 0, length: 3))
        PythonHighlighter.highlight(storage, editedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: call.location, effectiveRange: nil) as? NSColor, EditorTheme.builtin)
    }

    func testTextViewOnlyRequestsLayoutWhenItsWidthChanges() {
        let view = CodeEditorFactory.makeTextView()
        var updates = 0
        view.onLayoutChange = { updates += 1 }
        view.setFrameSize(NSSize(width: 300, height: 40))
        view.setFrameSize(NSSize(width: 300, height: 80))
        view.setFrameSize(NSSize(width: 420, height: 80))
        XCTAssertEqual(updates, 2)
    }

}
