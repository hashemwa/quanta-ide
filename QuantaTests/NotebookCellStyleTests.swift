import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class NotebookCellStyleTests: XCTestCase {
    private let title = NotebookCell(type: .markdown, source: "# Title")
    private let caption = NotebookCell(type: .markdown, source: "Import packages")
    private let code = NotebookCell(type: .code, source: "x = 1")
    private let closing = NotebookCell(type: .markdown, source: "Done")
    private var window: NSWindow!
    private var hosting: NSView!

    override func setUp() {
        super.setUp()
        let app = AppState.shared
        let savedDocument = app.activeDocumentID
        let savedCell = app.selection.selectedCellID
        let savedCells = app.selection.selectedCellIDs
        app.selection.selectedCellID = nil
        app.selection.selectedCellIDs = []
        addTeardownBlock {
            app.activeDocumentID = savedDocument
            app.selection.selectedCellID = savedCell
            app.selection.selectedCellIDs = savedCells
        }
        (window, hosting) = host([title, caption, code, closing], width: 900)
    }

    func testNotebookSitsOnTheTextBackground() throws {
        let scroll = try XCTUnwrap(first(NSScrollView.self, in: hosting))
        XCTAssertEqual(scroll.backgroundColor, .textBackgroundColor)
    }

    func testCodeSitsInAWellAndProseSitsOnThePage() throws {
        let well = try XCTUnwrap(cardLayer(of: code))
        XCTAssertEqual(rgba(well.backgroundColor), rgba(NSColor.tertiarySystemFill))
        XCTAssertEqual(rgba(well.borderColor), rgba(NSColor.separatorColor))
        let prose = try XCTUnwrap(cardLayer(of: caption))
        XCTAssertEqual(prose.backgroundColor?.alpha ?? 0, 0)
        XCTAssertEqual(prose.borderColor?.alpha ?? 0, 0)
    }

    func testSelectionMarksTheWholeCellWithoutBoxingProse() throws {
        AppState.shared.selection.selectedCellID = caption.id
        AppState.shared.selection.selectedCellIDs = [caption.id]
        settle()
        let captionView = try XCTUnwrap(cellView(caption))
        let bar = try XCTUnwrap(selectionBar(in: captionView))
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.height, captionView.bounds.height, accuracy: 0.5)
        XCTAssertEqual(rgba(bar.layer?.backgroundColor), rgba(NSColor.controlAccentColor))
        XCTAssertEqual(try XCTUnwrap(cardLayer(of: caption)).borderColor?.alpha ?? 0, 0)
        XCTAssertTrue(try XCTUnwrap(selectionBar(in: try XCTUnwrap(cellView(code)))).isHidden)
    }

    func testEditingRingsTheWellWithTheAccentColor() throws {
        let editor = try XCTUnwrap(first(NSTextView.self, in: try XCTUnwrap(cellView(code))))
        XCTAssertTrue(window.makeFirstResponder(editor))
        settle()
        XCTAssertEqual(rgba(try XCTUnwrap(cardLayer(of: code)).borderColor), rgba(NSColor.controlAccentColor))
        XCTAssertFalse(try XCTUnwrap(selectionBar(in: try XCTUnwrap(cellView(code)))).isHidden)
        XCTAssertTrue(window.makeFirstResponder(nil))
        settle()
        XCTAssertEqual(rgba(try XCTUnwrap(cardLayer(of: code)).borderColor), rgba(NSColor.separatorColor))
    }

    func testProseBindsToTheCodeBelowIt() throws {
        let frames = try [title, caption, code, closing].map { try XCTUnwrap(cellView($0)).frame }
        XCTAssertEqual(frames[1].minY - frames[0].maxY, DS.Layout.notebookProseSpacing, accuracy: 0.5)
        XCTAssertEqual(frames[2].minY - frames[1].maxY, DS.Layout.notebookProseSpacing, accuracy: 0.5)
        XCTAssertEqual(frames[3].minY - frames[2].maxY, DS.Layout.notebookCellSpacing, accuracy: 0.5)
        XCTAssertLessThan(DS.Layout.notebookProseSpacing, DS.Layout.notebookCellSpacing)
    }

    func testShortCellsAreSizedByTheirContentNotTheirGutter() throws {
        let captionView = try XCTUnwrap(cellView(caption))
        let card = try XCTUnwrap(cardView(in: captionView))
        XCTAssertEqual(captionView.bounds.height, card.frame.height, accuracy: 2)
    }

    func testLongProseIsMeasuredAtTheWidthItWrapsTo() throws {
        let paragraph = String(repeating: "Finite differences approximate a derivative from nearby samples. ", count: 12)
        var heights: [CGFloat] = []
        for width in [700.0, 1000.0] {
            let prose = NotebookCell(type: .markdown, source: paragraph)
            let line = NotebookCell(type: .markdown, source: "Done")
            let (window, hosting) = host([prose, line], width: width)
            let proseView = try XCTUnwrap(cellView(prose, in: hosting))
            let lineView = try XCTUnwrap(cellView(line, in: hosting))
            let content = try XCTUnwrap(hostedContent(in: proseView))
            XCTAssertGreaterThan(content.frame.height, try XCTUnwrap(hostedContent(in: lineView)).frame.height * 3)
            XCTAssertGreaterThanOrEqual(proseView.frame.height, content.frame.height)
            heights.append(content.frame.height)
            window.close()
        }
        XCTAssertGreaterThan(heights[0], heights[1])
    }

    private func host(_ cells: [NotebookCell], width: CGFloat) -> (NSWindow, NSView) {
        let notebook = Notebook(cells: cells, metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let hosting = NSHostingView(rootView: NotebookScrollView(document: document, notebook: notebook,
                                                                 scrollRequest: nil)
            .frame(width: width, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        addTeardownBlock { window.close() }
        settle(hosting)
        return (window, hosting)
    }

    private func settle(_ view: NSView? = nil) {
        let view = view ?? hosting!
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    private func cellView(_ cell: NotebookCell, in root: NSView? = nil) -> NotebookCellAppKitView? {
        all(NotebookCellAppKitView.self, in: root ?? hosting).first { $0.cellID == cell.id }
    }

    private func hostedContent(in view: NSView) -> NSView? {
        descendants(of: view).first { String(describing: type(of: $0)).contains("HostingView") }
    }

    private func cardView(in view: NSView) -> NSView? {
        descendants(of: view).first { String(describing: type(of: $0)).contains("CardView") }
    }

    private func cardLayer(of cell: NotebookCell) -> CALayer? {
        cellView(cell).flatMap(cardView)?.layer
    }

    private func selectionBar(in view: NSView) -> NSView? {
        descendants(of: view).first { String(describing: type(of: $0)).contains("SelectionBar") }
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        all(type, in: view).first
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        descendants(of: view).compactMap { $0 as? T }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func rgba(_ color: CGColor?) -> [Int] {
        guard let color, let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [] }
        return [converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    private func rgba(_ color: NSColor) -> [Int] {
        var result: [Int] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { result = rgba(color.cgColor) }
        return result
    }
}
