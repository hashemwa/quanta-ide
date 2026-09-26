import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class NotebookVirtualizationTests: XCTestCase {
    private var cells: [NotebookCell] = []
    private var document: Quanta.Document!
    private var hosting: NSHostingView<EditorStage>!

    override func setUp() {
        super.setUp()
        cells = (0..<400).map { index in
            index % 3 == 0
                ? NotebookCell(type: .markdown, source: "## Section \(index)\nSome explanation for step \(index).")
                : NotebookCell(type: .code, source: "value_\(index) = \(index)\nprint(value_\(index))")
        }
        document = Document(notebook: Notebook(cells: cells, metadata: [:]), url: nil)
        hosting = NSHostingView(rootView: stage(scrollRequest: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        addTeardownBlock {
            window.close()
            DocumentViewCache.shared.retain(documents: [], splitVisible: false)
        }
        settle()
    }

    func testLargeNotebookBuildsOnlyTheCellsNearTheViewport() throws {
        let realized = cellViews()
        XCTAssertGreaterThan(realized.count, 0)
        XCTAssertLessThan(realized.count, 60)
        let documentView = try XCTUnwrap(scrollView()?.documentView)
        XCTAssertGreaterThan(documentView.frame.height, CGFloat(cells.count) * 30)
    }

    func testScrollingToACellBuildsItAndItsEditor() throws {
        let target = cells[301]
        hosting.rootView = stage(scrollRequest: target.id)
        settle()
        let cellView = try XCTUnwrap(cellViews().first { $0.cellID == target.id })
        let visible = try XCTUnwrap(scrollView()).contentView.bounds
        XCTAssertTrue(visible.intersects(cellView.frame))
        XCTAssertNotNil(EditorRegistry.shared.view(for: target.id))
        XCTAssertNil(cellViews().first { $0.cellID == cells[1].id })
    }

    func testUndoSurvivesACellLeavingTheViewport() throws {
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cells[1].id))
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.undoManager?.canUndo, true)

        hosting.rootView = stage(scrollRequest: cells[399].id)
        settle()
        XCTAssertNil(cellViews().first { $0.cellID == cells[1].id })

        hosting.rootView = stage(scrollRequest: cells[1].id)
        settle()
        let rebuilt = try XCTUnwrap(EditorRegistry.shared.view(for: cells[1].id))
        XCTAssertEqual(rebuilt.undoManager?.canUndo, true)
        XCTAssertTrue(cells[1].source.hasPrefix("x"))
        rebuilt.undoManager?.undo()
        settle()
        XCTAssertEqual(cells[1].source, "value_1 = 1\nprint(value_1)")
        XCTAssertEqual(rebuilt.string, cells[1].source)
        rebuilt.undoManager?.redo()
        settle()
        XCTAssertEqual(cells[1].source, "xvalue_1 = 1\nprint(value_1)")
        XCTAssertEqual(rebuilt.string, cells[1].source)
    }

    func testCellsBuiltLaterKeepTheNotebookRhythm() throws {
        hosting.rootView = stage(scrollRequest: cells[200].id)
        settle()
        let realized = cellViews().sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(realized.count, 3)
        for (above, below) in zip(realized, realized.dropFirst()) {
            guard let upper = cells.firstIndex(where: { $0.id == above.cellID }),
                  let lower = cells.firstIndex(where: { $0.id == below.cellID }), lower == upper + 1 else { continue }
            let gap = below.frame.minY - above.frame.maxY
            XCTAssertEqual(gap, NotebookCanvas.spacing(after: cells[upper].cellType), accuracy: 0.5)
        }
    }

    func testRemovingMostCellsWhileScrolledToTheBottomKeepsTheCanvasValid() throws {
        hosting.rootView = stage(scrollRequest: cells[399].id)
        settle()
        document.notebook?.cells = Array(cells.prefix(3))
        settle()
        let scroll = try XCTUnwrap(scrollView())
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
        XCTAssertEqual(Set(cellViews().compactMap(\.cellID)), Set(cells.prefix(3).map(\.id)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
    }

    func testRemovingCellsAboveTheViewportPreservesTheVisibleAnchor() throws {
        hosting.rootView = stage(scrollRequest: cells[301].id)
        settle()
        let clip = try XCTUnwrap(scrollView()).contentView
        let anchor = try XCTUnwrap(cellViews().filter { $0.frame.maxY > clip.bounds.minY }
            .min { $0.frame.minY < $1.frame.minY })
        let before = anchor.frame.minY - clip.bounds.minY
        document.notebook?.cells.removeFirst(100)
        settle()
        XCTAssertEqual(anchor.frame.minY - clip.bounds.minY, before, accuracy: 0.5)
    }

    func testIdlePrefetchBuildsTheNextScreenWithoutMovingContent() throws {
        hosting.rootView = stage(scrollRequest: cells[200].id)
        settle()
        let clip = try XCTUnwrap(scrollView()).contentView
        let anchor = try XCTUnwrap(cellViews().filter { $0.frame.maxY > clip.bounds.minY }
            .min { $0.frame.minY < $1.frame.minY })
        let before = anchor.frame.minY - clip.bounds.minY
        settle(rounds: 30)
        XCTAssertEqual(anchor.frame.minY - clip.bounds.minY, before, accuracy: 0.5)
        let farBelow = clip.bounds.maxY + clip.bounds.height * 1.5
        XCTAssertTrue(cellViews().contains { $0.frame.minY <= farBelow && $0.frame.maxY >= farBelow })
    }

    private func stage(scrollRequest: UUID?) -> EditorStage {
        EditorStage(document: document, pane: .secondary, showsLineNumbers: true, wrapsLines: true,
                    scrollRequest: scrollRequest)
    }

    private func settle(rounds: Int = 6) {
        for _ in 0..<rounds {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func cellViews() -> [NotebookCellAppKitView] {
        descendants(of: hosting).compactMap { $0 as? NotebookCellAppKitView }
    }

    private func scrollView() -> NSScrollView? {
        descendants(of: hosting).compactMap { $0 as? NSScrollView }.first
    }
}
