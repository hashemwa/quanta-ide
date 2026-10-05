import AppKit
import XCTest
@testable import Quanta

@MainActor
final class AppStateResilienceTests: XCTestCase {
    func testWindowRestorationRejectsNonfiniteOrMalformedDimensions() {
        for value in ["0 0 nan 900", "0 0 inf 900", "0 0 1400 -1", "0 0 broken 900 1500", "0 0 1e99 900", "invalid"] {
            XCTAssertEqual(MainWindowFrame.size(from: value), MainWindowFrame.fallback, value)
        }
        XCTAssertEqual(MainWindowFrame.size(from: "0 0 1600 1000"), CGSize(width: 1600, height: 1000))
        XCTAssertEqual(MainWindowFrame.size(from: "0 0 200 200"), CGSize(width: DS.Layout.windowMinWidth, height: DS.Layout.windowMinHeight))
    }

    func testCorruptedNumericPreferencesNeverReachViewGeometry() throws {
        let name = "quanta.geometry-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for value in [Double.nan, .infinity, -.infinity] {
            defaults.set(value, forKey: "size")
            XCTAssertEqual(QuantaDefaults.finiteCGFloat(forKey: "size", fallback: 13, range: 11...28, defaults: defaults), 13)
        }
        defaults.set(-1_000, forKey: "size")
        XCTAssertEqual(QuantaDefaults.finiteCGFloat(forKey: "size", fallback: 13, range: 11...28, defaults: defaults), 11)
        defaults.set(1_000, forKey: "size")
        XCTAssertEqual(QuantaDefaults.finiteCGFloat(forKey: "size", fallback: 13, range: 11...28, defaults: defaults), 28)
        defaults.set("invalid", forKey: "size")
        XCTAssertEqual(QuantaDefaults.finiteCGFloat(forKey: "size", fallback: 13, range: 11...28, defaults: defaults), 13)
    }

    func testNotebookFindRejectsStaleIndicesAndOverflowingRanges() {
        let app = AppState()
        let cell = NotebookCell(type: .code, source: "value = 1")
        let document = Document(notebook: Notebook(cells: [cell], metadata: [:]), url: nil)
        document.find.query = "value"
        document.find.replacement = "changed"
        document.find.matches = [(cell.id, NSRange(location: 0, length: 5))]
        for index in [-1, Int.min, Int.max, 1] {
            document.find.currentIndex = index
            app.highlightCurrentMatch(in: document)
            app.replaceCurrentMatch(in: document)
            XCTAssertEqual(cell.source, "value = 1")
        }
        for range in [NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max),
                      NSRange(location: -1, length: 1), NSRange(location: 0, length: -1)] {
            document.find.currentIndex = 0
            document.find.matches = [(cell.id, range)]
            app.highlightCurrentMatch(in: document)
            app.replaceCurrentMatch(in: document)
            XCTAssertEqual(cell.source, "value = 1")
        }
        XCTAssertFalse(document.isDirty)
    }
}
