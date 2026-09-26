import XCTest
@testable import Quanta

final class DraftRecoveryTests: XCTestCase {
    @MainActor
    func testCorruptNotebookDraftStaysQuarantinedOnNextRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("untitled-broken.ipynb")
        try "{incomplete notebook".write(to: corrupt, atomically: true, encoding: .utf8)
        let app = AppState()
        app.restoreUntitledDrafts(from: root)
        XCTAssertTrue(app.openDocuments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.appendingPathExtension("corrupt").path))
        app.restoreUntitledDrafts(from: root)
        XCTAssertTrue(app.openDocuments.isEmpty)
        XCTAssertEqual(try String(contentsOf: corrupt.appendingPathExtension("corrupt"), encoding: .utf8),
                       "{incomplete notebook")
        try "recovered = 42".write(to: root.appendingPathComponent("untitled-valid.py"), atomically: true, encoding: .utf8)
        app.restoreUntitledDrafts(from: root)
        XCTAssertEqual(app.openDocuments.count, 1)
        XCTAssertEqual(app.openDocuments.first?.text, "recovered = 42")
        XCTAssertEqual(app.openDocuments.first?.isDirty, true)
    }
}
