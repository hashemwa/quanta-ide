import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Quanta

@MainActor
final class SourceControlPanelTests: XCTestCase {
    private var root: URL!
    private let panelHeight: CGFloat = 620

    override func setUpWithError() throws {
        try XCTSkipIf(GitClient.executable == nil, "git is not installed")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-source-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "tests@example.com"],
            ["config", "user.name", "Quanta Tests"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] { _ = try run(arguments) }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCommitControlsRemainVisibleAfterCommit() throws {
        try write("value = 1\n")
        _ = try run(["add", "--", "example.py"])
        _ = try run(["remote", "add", "origin", root.appendingPathComponent("remote.git").path])
        let app = try loadApp()
        app.git.draft.message = "Initial change"
        let (window, hosting) = host(app, width: 260)
        try capture(hosting, name: "staged-260")
        try assertControlsFit(hosting, in: window, message: app.git.draft.message)
        XCTAssertFalse(try XCTUnwrap(app.git.snapshot).staged.isEmpty)
        XCTAssertFalse(app.git.isBusy)
        try capture(hosting, name: "staged-260")

        let finished = expectation(description: "Commit finishes with clean working tree")
        var completed = false
        app.git.onSnapshot = {
            if app.git.snapshot?.hasCommits == true, app.git.snapshot?.isClean == true, !completed {
                completed = true
                finished.fulfill()
            }
        }
        app.commit()
        wait(for: [finished], timeout: 15)
        app.git.onSnapshot = nil
        settle(hosting)
        try assertControlsFit(hosting, in: window, message: app.git.draft.message)
        XCTAssertTrue(try XCTUnwrap(app.git.snapshot).staged.isEmpty)
        XCTAssertFalse(app.git.canPull)
        XCTAssertTrue(app.git.canPush)
        XCTAssertEqual(app.git.draft.message, "")
        try capture(hosting, name: "clean-260")
    }

    func testRepositoryControlsFitLongBranchesAndCommitMessages() throws {
        try write("value = 1\n")
        _ = try run(["add", "--", "example.py"])
        _ = try run(["commit", "-q", "-m", "Base"])
        let base = try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("value = 2\n")
        _ = try run(["commit", "-q", "-a", "-m", "Upstream change"])
        _ = try run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try run(["remote", "add", "origin", root.appendingPathComponent("remote.git").path])
        let branch = "feature/a-very-long-branch-name-that-needs-to-truncate"
        _ = try run(["checkout", "-q", "-b", branch, base])
        _ = try run(["config", "branch.\(branch).remote", "origin"])
        _ = try run(["config", "branch.\(branch).merge", "refs/heads/main"])
        try write("value = 3\n")
        _ = try run(["commit", "-q", "-a", "-m", "Local change"])
        let app = try loadApp()
        XCTAssertEqual(app.git.snapshot?.ahead, 1)
        XCTAssertEqual(app.git.snapshot?.behind, 1)
        XCTAssertTrue(app.git.snapshot?.isClean == true)
        app.git.draft.message = Array(repeating: "A longer commit message with detail that wraps across narrow panels.", count: 12).joined(separator: "\n")

        for width in [240.0, 260.0, 400.0] {
            let (window, hosting) = host(app, width: width)
            try capture(hosting, name: "long-draft-\(Int(width))")
            try assertControlsFit(hosting, in: window, message: app.git.draft.message)
            XCTAssertTrue(app.git.canPull)
            XCTAssertTrue(app.git.canPush)
            XCTAssertTrue(try XCTUnwrap(app.git.snapshot).staged.isEmpty)
            try capture(hosting, name: "long-draft-\(Int(width))")
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        let result = GitClient.run(arguments, in: root)
        guard result.succeeded else { throw QuantaError(result.failureMessage) }
        return result.text
    }

    private func write(_ text: String) throws {
        try text.write(to: root.appendingPathComponent("example.py"), atomically: true, encoding: .utf8)
    }

    private func loadApp() throws -> AppState {
        let app = AppState()
        let loaded = expectation(description: "Repository loaded")
        app.git.onSnapshot = { loaded.fulfill() }
        app.git.setWorkspace(root)
        wait(for: [loaded], timeout: 10)
        app.git.onSnapshot = nil
        _ = try XCTUnwrap(app.git.snapshot)
        return app
    }

    private func host(_ app: AppState, width: CGFloat) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: SourceControlPanel(app: app)
            .frame(width: width, height: panelHeight)
            .background(Color(nsColor: .windowBackgroundColor)))
        let frame = NSRect(x: 0, y: 0, width: width, height: panelHeight)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        addTeardownBlock { window.close() }
        settle(hosting)
        return (window, hosting)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertControlsFit(_ hosting: NSView, in window: NSWindow, message: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        recognition.customWords = ["Pull", "Push", "Commit"]
        recognition.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
        let observations = recognition.results ?? []
        let recognized = observations.flatMap { $0.topCandidates(5).map(\.string) }
        var buttonFrames: [CGRect] = []
        for title in ["Pull", "Push", "Commit"] {
            let frames = observations.flatMap { observation -> [CGRect] in
                observation.topCandidates(5).flatMap { candidate -> [CGRect] in
                    var search = candidate.string.startIndex..<candidate.string.endIndex
                    var matches: [CGRect] = []
                    while let range = candidate.string.range(of: title, options: .caseInsensitive, range: search) {
                        if let rectangle = try? candidate.boundingBox(for: range) { matches.append(rectangle.boundingBox) }
                        search = range.upperBound..<candidate.string.endIndex
                    }
                    return matches
                }
            }
            let frame = try XCTUnwrap(frames.min { $0.midY < $1.midY },
                                     "Missing visible \(title) button. Recognized: \(recognized)", file: file, line: line)
            buttonFrames.append(frame)
            XCTAssertGreaterThan(frame.minX, 0, title, file: file, line: line)
            XCTAssertLessThan(frame.maxX, 1, title, file: file, line: line)
        }
        XCTAssertEqual(buttonFrames[0].midY, buttonFrames[1].midY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(buttonFrames[1].midY, buttonFrames[2].midY, accuracy: 0.01,
                       "Recognized footer: \(recognized)", file: file, line: line)
        XCTAssertLessThan(buttonFrames[0].maxX, buttonFrames[1].minX, file: file, line: line)
        XCTAssertLessThan(buttonFrames[1].maxX, buttonFrames[2].minX, file: file, line: line)
        let field = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && !($0 is NSSearchField) && $0.stringValue == message
        }, "Missing native commit message input", file: file, line: line)
        let frame = field.convert(field.bounds, to: hosting)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, hosting.bounds.maxY + 1, file: file, line: line)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: "/tmp/quanta-source-control-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
