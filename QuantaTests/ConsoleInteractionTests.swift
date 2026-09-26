import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Quanta

final class ConsoleInteractionTests: XCTestCase {
    func testTypingDoesNotPublishTranscriptUpdates() {
        let console = ConsoleModel()
        var updates = 0
        let observation = console.objectWillChange.sink { updates += 1 }
        for index in 0..<100 { console.input.text = "draft \(index)" }
        XCTAssertEqual(updates, 0)
        observation.cancel()
    }

    func testHistoryRestoresTheUnsubmittedDraft() {
        let console = ConsoleInputState()
        console.recordHistory("first = 1")
        console.recordHistory("second = 2")
        console.text = "unfinished = "
        XCTAssertTrue(console.recallHistory(-1))
        XCTAssertEqual(console.text, "second = 2")
        XCTAssertTrue(console.recallHistory(-1))
        XCTAssertEqual(console.text, "first = 1")
        XCTAssertTrue(console.recallHistory(1))
        XCTAssertTrue(console.recallHistory(1))
        XCTAssertEqual(console.text, "unfinished = ")
        XCTAssertFalse(console.recallHistory(1))
        XCTAssertEqual(console.text, "unfinished = ")
    }

    func testRejectedSubmissionPreservesInputAndHistory() {
        let console = ConsoleInputState()
        console.text = "  print('keep me')  "
        XCTAssertFalse(console.submitInput { _ in false })
        XCTAssertEqual(console.text, "  print('keep me')  ")
        XCTAssertTrue(console.history.isEmpty)
        XCTAssertTrue(console.submitInput { $0 == "print('keep me')" })
        XCTAssertEqual(console.text, "")
        XCTAssertEqual(console.history, ["print('keep me')"])
    }

    func testConsolePreservesCRLFAcrossStreamChunks() {
        let console = ConsoleModel()
        console.append(.stdout, "first\r")
        console.append(.stdout, "\nsecond\r")
        console.append(.stdout, "\n")
        XCTAssertEqual(console.lines.map(\.text), ["first\nsecond\n"])
        console.append(.stdout, "progress 10%\r")
        console.append(.stdout, "progress 20%")
        XCTAssertEqual(console.lines.last?.text, "first\nsecond\nprogress 20%")
    }

    @MainActor
    func testConsoleInputStaysEditableWhileKernelIsBusyAndSurvivesViewRecreation() throws {
        let app = AppState()
        app.kernelStatus = .busy
        app.console.input.text = "draft = 42"
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        for _ in 0..<2 {
            let host = NSHostingView(rootView: ConsoleView().environmentObject(app))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 180)
            host.layoutSubtreeIfNeeded()
            let input = try XCTUnwrap(field(in: host))
            XCTAssertTrue(input.isEnabled)
            XCTAssertEqual(input.stringValue, "draft = 42")
        }
    }

    @MainActor
    func testLongConsoleOutputRendersInNarrowAndWidePanes() throws {
        let directory = URL(fileURLWithPath: "/tmp/quanta-console-terminal-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for width in [360.0, 900.0] {
                let app = AppState()
                app.kernelStatus = .busy
                app.console.append(.input, "for batch in range(80): process(batch)")
                for index in 0..<80 {
                    app.console.append(.stdout, "Batch \(index): 2,048 records processed successfully — mean 13.24, elapsed 0.02s\n")
                }
                app.console.append(.stderr, "Warning: column measurement contains missing values; these rows were excluded from the summary.\n")
                app.console.input.text = "df.groupby('category').mean()"
                let hosting = NSHostingView(rootView: ConsoleView().environmentObject(app)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .textBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                defer { window.close() }
                for _ in 0..<5 {
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 2000)
                try data.write(to: directory.appendingPathComponent("console-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }
}
