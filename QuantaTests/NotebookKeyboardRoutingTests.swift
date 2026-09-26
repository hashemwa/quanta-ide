import AppKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookKeyboardRoutingTests: XCTestCase {
    func testPageNavigationUsesTheFocusedSplitPane() throws {
        let window = makeWindow()
        defer { window.close() }
        let editors = [CodeEditorFactory.makeTextView(), CodeEditorFactory.makeTextView()]
        let scrollViews = editors.map { editor in
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            scrollView.documentView = editor
            window.contentView?.addSubview(scrollView)
            NotebookScrolling.register(scrollView: scrollView, documentID: UUID())
            return scrollView
        }
        for index in editors.indices {
            XCTAssertTrue(window.makeFirstResponder(editors[index]))
            XCTAssertTrue(NotebookScrolling.scrollView(in: window) === scrollViews[index])
        }
    }

    func testCommandModeRoutesToTheActiveNotebookAndPane() throws {
        let app = AppState.shared
        let savedDocumentID = app.activeDocumentID
        let savedCommandMode = app.isCommandMode
        let savedCellID = app.selectedCellID
        let savedCellIDs = app.selection.selectedCellIDs
        let window = makeWindow()
        defer {
            window.close()
            app.activeDocumentID = savedDocumentID
            app.isCommandMode = savedCommandMode
            app.selectedCellID = savedCellID
            app.selection.selectedCellIDs = savedCellIDs
        }
        let catchers = [EditorPane.primary, .secondary].map { pane in
            let catcher = CommandCatcherView(frame: .zero)
            catcher.pane = pane
            return catcher
        }
        let scrollViews = catchers.map { catcher in
            let documentID = UUID()
            catcher.documentID = documentID
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            scrollView.documentView = CodeEditorFactory.makeTextView()
            window.contentView?.addSubview(catcher)
            window.contentView?.addSubview(scrollView)
            NotebookScrolling.register(scrollView: scrollView, documentID: documentID, pane: catcher.pane)
            return scrollView
        }
        for sameDocument in [false, true] {
            if sameDocument {
                let documentID = try XCTUnwrap(catchers[0].documentID)
                catchers[1].documentID = documentID
                NotebookScrolling.register(scrollView: scrollViews[1], documentID: documentID, pane: .secondary)
            }
            for index in catchers.indices {
                app.activeDocumentID = catchers[index].documentID
                XCTAssertTrue(window.makeFirstResponder(scrollViews[index].documentView))
                XCTAssertTrue(CommandCatcherView.activeCatcher(in: window) === catchers[index])
                XCTAssertTrue(window.makeFirstResponder(catchers[index]))
                XCTAssertTrue(NotebookScrolling.scrollView(in: window) === scrollViews[index])
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
