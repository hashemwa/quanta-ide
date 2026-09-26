import AppKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookEditorLayoutTests: XCTestCase {
    func testCodeRemainsInsideItsWellAsThePaneNarrowsAndWidens() throws {
        let source = "records = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta']\n"
            + "message = 'A long line with Unicode 🐍 and enough words to wrap across a narrow notebook pane.'\n"
            + "print(records, message)"
        let cell = NotebookCell(type: .code, source: source)
        let (window, canvas) = host([cell, NotebookCell(type: .markdown, source: "The entire cell remains visible above this line.")])
        defer { window.close() }
        for width in [900.0, 450.0, 320.0, 280.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 650))
            settle(canvas.view)
            let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
            assertTextFits(editor)
            let cellView = try XCTUnwrap(descendants(of: canvas.view).compactMap { $0 as? NotebookCellAppKitView }.first { $0.cellID == cell.id })
            let editorFrame = cellView.convert(editor.bounds, from: editor)
            XCTAssertGreaterThanOrEqual(editorFrame.minX, 0)
            XCTAssertLessThanOrEqual(editorFrame.maxX, cellView.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(editorFrame.maxY, cellView.bounds.height + 0.5)
            try saveImage(canvas.view, name: "code-\(Int(width))")
        }
    }

    func testTypingNewlinesKeepsTheInsertionLineInsideTheEditor() throws {
        let cell = NotebookCell(type: .code, source: "value = 1")
        let (window, canvas) = host([cell], width: 320)
        defer { window.close() }
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        for text in ["\n", "\n", "print(value)\n", "\n"] {
            editor.insertText(text, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            settle(canvas.view)
            assertTextFits(editor)
        }
        try saveImage(canvas.view, name: "trailing-newlines-320")
    }

    func testLargerCodeFontReflowsWithoutCuttingOffWrappedLines() throws {
        let originalFontSize = EditorTheme.fontSize
        defer { EditorTheme.fontSize = originalFontSize }
        let cell = NotebookCell(type: .code, source: "result = calculate_measurements(samples, normalization='standard', precision=12)\n")
        let (window, canvas) = host([cell], width: 280)
        defer { window.close() }
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        let initialHeight = editor.frame.height
        EditorTheme.fontSize = 24
        editor.typingAttributes = [.font: EditorTheme.font, .foregroundColor: EditorTheme.text]
        if let storage = editor.textStorage { PythonHighlighter.highlight(storage) }
        editor.onLayoutChange?()
        settle(canvas.view)
        assertTextFits(editor)
        XCTAssertGreaterThan(editor.frame.height, initialHeight)
        try saveImage(canvas.view, name: "large-font-280")
    }

    func testMarkedTextCanWrapWithoutClippingOrPublishingUncommittedSource() throws {
        let cell = NotebookCell(type: .code, source: "")
        let (window, canvas) = host([cell], width: 280)
        defer { window.close() }
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        let composition = String(repeating: "測定値の入力", count: 16)
        editor.setMarkedText(composition, selectedRange: NSRange(location: composition.utf16.count, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        settle(canvas.view)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(cell.source, "")
        assertTextFits(editor)
        try saveImage(canvas.view, name: "marked-text-280")
        editor.insertText(composition, replacementRange: editor.markedRange())
        settle(canvas.view)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(cell.source, composition)
        assertTextFits(editor)
    }

    private func assertTextFits(_ editor: QuantaTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else {
            XCTFail("Missing text layout", file: file, line: line)
            return
        }
        layoutManager.ensureLayout(for: container)
        let availableWidth = editor.bounds.width - editor.textContainerInset.width * 2
        XCTAssertLessThanOrEqual(container.containerSize.width, availableWidth + 0.5, file: file, line: line)
        let origin = editor.textContainerOrigin
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, used, _, _, _ in
            XCTAssertLessThanOrEqual(used.maxX + origin.x, editor.bounds.width - editor.textContainerInset.width + 0.5,
                                     file: file, line: line)
        }
        let usedHeight = max(layoutManager.usedRect(for: container).maxY, layoutManager.extraLineFragmentRect.maxY)
        XCTAssertLessThanOrEqual(usedHeight + origin.y + editor.textContainerInset.height, editor.bounds.height + 0.5,
                                 file: file, line: line)
    }

    private func host(_ cells: [NotebookCell], width: CGFloat = 900) -> (NSWindow, NotebookCanvas) {
        let notebook = Notebook(cells: cells, metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: EditorTheme.fontSize - 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = canvas.view
        settle(canvas.view)
        return (window, canvas)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func saveImage(_ view: NSView, name: String) throws {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/quanta-notebook-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
