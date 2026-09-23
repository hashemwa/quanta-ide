import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class EditorStageTests: XCTestCase {
    private let notebook = Document(notebook: Notebook(cells: [NotebookCell(type: .code, source: "x = 1")],
                                                       metadata: [:]), url: nil)
    private let script = Document(script: nil, text: "print('hello')\n")

    override func setUp() {
        super.setUp()
        let app = AppState.shared
        let savedDocument = app.activeDocumentID
        addTeardownBlock { app.activeDocumentID = savedDocument }
    }

    func testSwitchingDocumentsHidesCanvasesInsteadOfRebuildingThem() throws {
        let (hosting, stage) = try host(notebook)
        let notebookCanvas = try XCTUnwrap(visibleCanvas(in: stage))

        hosting.rootView = makeStage(script)
        settle(hosting)
        let scriptCanvas = try XCTUnwrap(visibleCanvas(in: stage))
        XCTAssertFalse(scriptCanvas === notebookCanvas)
        XCTAssertTrue(notebookCanvas.superview === stage)
        XCTAssertTrue(notebookCanvas.isHidden)

        hosting.rootView = makeStage(notebook)
        settle(hosting)
        XCTAssertTrue(visibleCanvas(in: stage) === notebookCanvas)
        XCTAssertTrue(scriptCanvas.isHidden)
        XCTAssertEqual(notebookCanvas.frame, stage.bounds)
    }

    func testSwitchingToAScriptMovesKeyboardFocusIntoIt() throws {
        let (hosting, stage) = try host(notebook)
        hosting.rootView = makeStage(script)
        settle(hosting)
        let editor = try XCTUnwrap(visibleCanvas(in: stage).flatMap { ($0 as? NSScrollView)?.documentView })
        XCTAssertTrue(stage.window?.firstResponder === editor)
    }

    func testClosingADocumentReleasesItsCanvas() throws {
        let (hosting, stage) = try host(script)
        hosting.rootView = makeStage(notebook)
        settle(hosting)
        XCTAssertEqual(stage.subviews.count, 2)

        DocumentViewCache.shared.retain(documents: [notebook.id], splitVisible: false)
        settle(hosting)
        XCTAssertEqual(stage.subviews.count, 1)
    }

    private func makeStage(_ document: Quanta.Document) -> EditorStage {
        EditorStage(document: document, pane: .primary, showsLineNumbers: true, wrapsLines: true, scrollRequest: nil)
    }

    private func host(_ document: Quanta.Document) throws -> (NSHostingView<EditorStage>, EditorStageView) {
        let hosting = NSHostingView(rootView: makeStage(document))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        addTeardownBlock { window.close() }
        settle(hosting)
        func find(_ view: NSView) -> EditorStageView? {
            (view as? EditorStageView) ?? view.subviews.lazy.compactMap(find).first
        }
        return (hosting, try XCTUnwrap(find(hosting)))
    }

    private func visibleCanvas(in stage: EditorStageView) -> NSView? {
        stage.subviews.first { !$0.isHidden }
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            view.layoutSubtreeIfNeeded()
        }
    }
}
