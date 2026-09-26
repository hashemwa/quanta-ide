import XCTest
@testable import Quanta

final class WorkspaceGitRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testStageAllAndCommitCommitsPreviouslyUnstagedFiles() throws {
        try XCTSkipIf(GitClient.executable == nil, "git is not installed")
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "tests@example.com"],
            ["config", "user.name", "Quanta Tests"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] {
            let result = GitClient.run(arguments, in: root)
            XCTAssertTrue(result.succeeded, result.failureMessage)
        }
        try "answer = 42\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        let app = AppState()
        let loaded = expectation(description: "Repository loaded")
        app.git.onSnapshot = { loaded.fulfill() }
        app.git.setWorkspace(root)
        wait(for: [loaded], timeout: 10)
        app.git.onSnapshot = nil
        XCTAssertTrue(try XCTUnwrap(app.git.snapshot).staged.isEmpty)
        XCTAssertFalse(try XCTUnwrap(app.git.snapshot).unstaged.isEmpty)
        app.git.draft.message = "First commit"
        let committed = expectation(description: "Stage all and commit finishes")
        var didFinish = false
        app.git.onSnapshot = {
            if app.git.snapshot?.hasCommits == true, !didFinish {
                didFinish = true
                committed.fulfill()
            }
        }
        defer { app.git.onSnapshot = nil }
        app.stageAllAndCommit()
        wait(for: [committed], timeout: 15)
        XCTAssertEqual(app.git.draft.message, "")
        XCTAssertNil(app.git.operationError)
        XCTAssertTrue(try XCTUnwrap(app.git.snapshot).isClean)
        XCTAssertEqual(GitClient.run(["show", "HEAD:answer.py"], in: root).text, "answer = 42\n")
    }

    @MainActor
    func testExternalReloadDetectsOlderTimestampsWithoutOverwritingDirtyDocuments() throws {
        let file = root.appendingPathComponent("example.py")
        try "disk = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let diskDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: diskDate], ofItemAtPath: file.path)
        let app = AppState()
        let document = Document(script: file, text: "original = 1\n")
        document.fileModificationDate = diskDate.addingTimeInterval(100)
        app.openDocuments = [document]
        app.activeDocumentID = document.id
        app.reloadExternallyChangedDocuments()
        XCTAssertEqual(document.text, "disk = 2\n")
        XCTAssertEqual(document.fileModificationDate, diskDate)

        document.text = "unsaved = 3\n"
        document.isDirty = true
        try "new_disk = 4\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: diskDate.addingTimeInterval(-100)], ofItemAtPath: file.path)
        app.reloadExternallyChangedDocuments()
        XCTAssertEqual(document.text, "unsaved = 3\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(app.externallyChangedDocumentID, document.id)
    }

    @MainActor
    func testExternalComparisonSurvivesRefreshAndReusesItsOwnTab() throws {
        let file = root.appendingPathComponent("example.py")
        try "disk = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let app = AppState()
        let document = Document(script: file, text: "unsaved = 2\n")
        document.isDirty = true
        document.fileModificationDate = Date(timeIntervalSince1970: 1_600_000_000)
        app.openDocuments = [document]
        app.externallyChangedDocumentID = document.id
        app.compareExternalVersion()
        let comparison = try XCTUnwrap(app.activeDocument)
        XCTAssertEqual(comparison.displayName, "example.py (Your Edits)")
        XCTAssertEqual(comparison.diff?.oldLabel, "Disk")
        XCTAssertEqual(comparison.diff?.newLabel, "Your Edits")
        app.reloadDiffDocuments()
        app.reloadExternallyChangedDocuments()
        XCTAssertNil(comparison.diffError)
        XCTAssertEqual(comparison.diff?.newLabel, "Your Edits")
        XCTAssertEqual(app.activeDocumentID, comparison.id)

        try "disk = 3\n".write(to: file, atomically: true, encoding: .utf8)
        document.text = "unsaved = 4\n"
        app.reloadDiff(comparison)
        XCTAssertEqual(comparison.diff?.rows.filter { $0.kind == .removed }.map(\.text), ["disk = 3"])
        XCTAssertEqual(comparison.diff?.rows.filter { $0.kind == .added }.map(\.text), ["unsaved = 4"])
        app.compareExternalVersion()
        XCTAssertEqual(app.openDocuments.count, 2)
        XCTAssertEqual(app.activeDocumentID, comparison.id)
    }

    @MainActor
    func testReloadingConflictedDocumentAllowsNextConflict() throws {
        let app = AppState()
        let documents = try ["first.py", "second.py"].map { name in
            let file = root.appendingPathComponent(name)
            try "external = 1\n".write(to: file, atomically: true, encoding: .utf8)
            let document = Document(script: file, text: "unsaved = 2\n")
            document.isDirty = true
            document.fileModificationDate = Date(timeIntervalSince1970: 1_600_000_000)
            return document
        }
        app.openDocuments = documents
        app.reloadExternallyChangedDocuments()
        XCTAssertEqual(app.externallyChangedDocumentID, documents[0].id)
        app.reloadFromDisk(documents[0])
        XCTAssertNil(app.externallyChangedDocumentID)
        app.reloadExternallyChangedDocuments()
        XCTAssertEqual(app.externallyChangedDocumentID, documents[1].id)
        XCTAssertEqual(documents[1].text, "unsaved = 2\n")
        XCTAssertTrue(documents[1].isDirty)
    }

    @MainActor
    func testFailedExternalReloadKeepsConflictAndUnsavedEdits() throws {
        let file = root.appendingPathComponent("unreadable.ipynb")
        try "invalid notebook".write(to: file, atomically: true, encoding: .utf8)
        let document = Document(notebook: Notebook.empty(), url: file)
        document.notebook?.cells[0].source = "unsaved = 2"
        document.isDirty = true
        let app = AppState()
        app.openDocuments = [document]
        app.externallyChangedDocumentID = document.id
        app.reloadExternalVersion()
        XCTAssertEqual(app.externallyChangedDocumentID, document.id)
        XCTAssertEqual(document.notebook?.cells[0].source, "unsaved = 2")
        XCTAssertTrue(document.isDirty)
    }

    func testDiffIdentitySeparatesRepositoriesAndExternalComparisons() {
        let first = DiffSource(path: "example.py", url: root.appendingPathComponent("first/example.py"), area: .unstaged, status: .modified)
        let second = DiffSource(path: "example.py", url: root.appendingPathComponent("second/example.py"), area: .unstaged, status: .modified)
        let comparison = DiffSource(path: first.path, url: first.url, area: first.area, status: first.status, comparedDocumentID: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, comparison)
    }

    @MainActor
    func testReorderingTabsPreservesTheirCanvasAndPinnedGroup() {
        let app = AppState()
        let pinned = Document(script: nil, text: "pinned")
        let first = Document(script: nil, text: "first")
        let second = Document(script: nil, text: "second")
        pinned.isPinned = true
        app.openDocuments = [pinned, first, second]
        let key = DocumentViewCache.Key(documentID: first.id, pane: .primary)
        let canvas = DocumentViewCache.shared.canvas(for: key) { ScriptCanvas(document: first) }
        app.reorderDocument(first.id, beside: pinned.id, after: false)
        XCTAssertEqual(app.openDocuments.map(\.id), [pinned.id, first.id, second.id])
        XCTAssertTrue(DocumentViewCache.shared.contains(canvas))
        app.moveDocumentToEnd(first.id)
        XCTAssertEqual(app.openDocuments.map(\.id), [pinned.id, second.id, first.id])
        XCTAssertTrue(DocumentViewCache.shared.contains(canvas))
        app.moveDocumentToEnd(pinned.id)
        XCTAssertEqual(app.openDocuments.map(\.id), [pinned.id, second.id, first.id])
    }

    func testWorkspaceStopsTraversingSymlinkCycles() throws {
        let directory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "value = 1\n".write(to: directory.appendingPathComponent("example.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: root)
        let workspace = Workspace.load(url: root)
        let source = try XCTUnwrap(workspace.root.children?.first)
        let loop = try XCTUnwrap(source.children?.first { $0.name == "loop" })
        XCTAssertTrue(loop.isDirectory)
        XCTAssertEqual(loop.children, [])
        XCTAssertEqual(WorkspaceIndex.files(in: workspace.root).map(\.lastPathComponent), ["example.py"])
    }

    func testFileTransferRejectsAliasedDescendantsAndSkipsFilesAlreadyInDestination() throws {
        let directory = root.appendingPathComponent("source", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        let rejected = FileOperations.transfer([directory], to: alias, copying: false) { _ in
            XCTFail("Moving a folder into itself must not reach collision handling")
            return .cancel
        }
        XCTAssertEqual(rejected.failures.count, 1)
        XCTAssertTrue(rejected.completed.isEmpty)

        let file = nested.appendingPathComponent("example.py")
        try "value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let skipped = FileOperations.transfer([file], to: alias, copying: false) { _ in
            XCTFail("Moving a file into its current folder must not rename it")
            return .keepBoth
        }
        XCTAssertEqual(skipped.skipped.count, 1)
        XCTAssertTrue(skipped.completed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMovingSymbolicLinkIntoItsTargetMovesTheLinkItself() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let report = FileOperations.transfer([link], to: target, copying: false) { _ in .cancel }
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.completed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        let moved = target.appendingPathComponent("link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path), target.path)
        XCTAssertTrue(try moved.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}
