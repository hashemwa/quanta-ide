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

    func testDiagnosticsDoNotRepeatedlyMutateTextAndClearOnTyping() throws {
        let view = CodeEditorFactory.makeTextView()
        view.string = "value\n"
        let storage = try XCTUnwrap(view.textStorage)
        let layout = try XCTUnwrap(view.layoutManager)
        let edits = StorageEdits()
        storage.delegate = edits
        view.applyLanguageDiagnostics([])
        view.applyLanguageDiagnostics([])
        XCTAssertTrue(edits.ranges.isEmpty)
        let diagnostic = LanguageDiagnostic(editorID: UUID(), range: NSRange(location: 0, length: 5),
                                            message: "Unresolved name", severity: 1, line: 0)
        view.applyLanguageDiagnostics([diagnostic])
        XCTAssertEqual(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(storage.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, diagnostic.message)
        edits.ranges = []
        view.applyLanguageDiagnostics([diagnostic])
        XCTAssertTrue(edits.ranges.isEmpty)
        view.didChangeText()
        XCTAssertNil(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.toolTip, at: 0, effectiveRange: nil))
        edits.ranges = []
        view.didChangeText()
        XCTAssertTrue(edits.ranges.isEmpty)
    }

    func testDiagnosticRenderingSkipsEmptyLineFragments() throws {
        let view = CodeEditorFactory.makeTextView()
        view.setFrameSize(NSSize(width: 300, height: 150))
        view.string = "x\n\n  \ny"
        let layout = try XCTUnwrap(view.layoutManager)
        let diagnostic = LanguageDiagnostic(editorID: UUID(), range: NSRange(location: 0, length: view.string.utf16.count),
                                            message: "Incomplete expression", severity: 1, line: 0)
        view.applyLanguageDiagnostics([diagnostic])
        for index in [0, 6] {
            XCTAssertEqual(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) as? Int,
                           NSUnderlineStyle.single.rawValue)
        }
        for index in 1...5 {
            XCTAssertNil(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil))
        }
        let point = LanguageDiagnostic(editorID: diagnostic.editorID, range: NSRange(location: 1, length: 0),
                                       message: diagnostic.message, severity: 1, line: 0)
        view.applyLanguageDiagnostics([point])
        XCTAssertNil(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 1, effectiveRange: nil))
        view.applyLanguageDiagnostics([diagnostic])
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }

}
