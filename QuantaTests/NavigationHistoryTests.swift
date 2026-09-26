import XCTest
@testable import Quanta

final class NavigationHistoryTests: XCTestCase {
    @MainActor
    func testClosedTabsDoNotLeaveUnavailableHistoryButtonsEnabled() {
        let app = AppState()
        let first = Document(script: nil, text: "first")
        let second = Document(script: nil, text: "second")
        let third = Document(script: nil, text: "third")
        app.openDocuments = [first, second, third]
        app.activeDocumentID = first.id
        app.activeDocumentID = second.id
        app.activeDocumentID = third.id
        XCTAssertTrue(app.canNavigateBack)
        XCTAssertTrue(app.closeDocument(second))
        app.navigateHistory(-1)
        XCTAssertEqual(app.activeDocumentID, first.id)
        XCTAssertFalse(app.canNavigateBack)
        XCTAssertTrue(app.canNavigateForward)
        XCTAssertTrue(app.closeDocument(third))
        XCTAssertFalse(app.canNavigateForward)
    }
}
