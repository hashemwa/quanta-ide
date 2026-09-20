import XCTest
@testable import Quanta

final class WorkspaceTrustTests: XCTestCase {
    private var root: URL!
    private var savedDefaults: [String: Any] = [:]
    private let keys = [WorkspaceTrust.workspacesKey, WorkspaceTrust.interpretersKey,
                        PythonLocator.defaultsKey, "QuantaLastWorkspace"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for key in keys {
            savedDefaults[key] = QuantaDefaults.store.object(forKey: key)
            QuantaDefaults.store.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in keys {
            QuantaDefaults.store.removeObject(forKey: key)
            if let value = savedDefaults[key] { QuantaDefaults.store.set(value, forKey: key) }
        }
        try FileManager.default.removeItem(at: root)
    }

    func testTrustUsesCanonicalExactFolders() throws {
        let alias = root.appendingPathComponent("alias")
        let project = root.appendingPathComponent("project")
        let child = project.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        WorkspaceTrust.grant(alias)
        XCTAssertTrue(WorkspaceTrust.contains(project))
        XCTAssertFalse(WorkspaceTrust.contains(child))
        XCTAssertFalse(WorkspaceTrust.contains(root))
    }

    @MainActor
    func testOpeningUntrustedWorkspaceNeverLaunchesItsInterpreter() async throws {
        let interpreter = root.appendingPathComponent(".venv/bin/python3")
        let marker = root.appendingPathComponent("executed")
        try FileManager.default.createDirectory(at: interpreter.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let script = "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexec /usr/bin/python3 \"$@\"\n"
        try script.write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        QuantaDefaults.store.set(interpreter.path, forKey: PythonLocator.defaultsKey)
        let app = AppState()
        defer { app.kernel.stop() }
        app.openWorkspace(root)
        app.refreshEnvironments()
        app.startKernelIfNeeded()
        app.restartKernel(confirm: false)
        app.runConsoleInput("print('must not run')")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(app.kernel.isRunning)
        XCTAssertTrue(app.environmentVersions.isEmpty)
        XCTAssertEqual(app.workspaceTrustRequest, root)
        app.trustWorkspace(root)
        try await waitForIdle(app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(app.kernel.executable, interpreter.path)
    }

    @MainActor
    func testSavedCustomInterpreterIsNotImplicitlyTrusted() async throws {
        let interpreter = root.appendingPathComponent("python")
        let marker = root.appendingPathComponent("executed")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\necho 'Python 3.12'\n"
            .write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        QuantaDefaults.store.set(interpreter.path, forKey: PythonLocator.defaultsKey)
        let app = AppState()
        app.refreshEnvironments()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let environment = PythonEnvironment(executable: interpreter.path, kind: .custom, name: "Saved")
        XCTAssertFalse(WorkspaceTrust.allows(environment, workspace: nil))
        WorkspaceTrust.grantInterpreter(interpreter.path)
        XCTAssertTrue(WorkspaceTrust.allows(environment, workspace: nil))
    }

    @MainActor
    func testSameInterpreterWorkspaceSwitchRequiresChoiceAndUsesNewDirectory() async throws {
        let first = root.appendingPathComponent("A")
        let second = root.appendingPathComponent("B")
        for (directory, contents) in [(first, "A"), (second, "B")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: directory.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
            WorkspaceTrust.grant(directory)
        }
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        app.openWorkspace(first)
        try await waitForIdle(app)
        let firstResult = try await result("open('data.csv').read()", app: app)
        XCTAssertEqual(firstResult, "'A'")
        app.openWorkspace(second)
        XCTAssertNotNil(app.kernelTransition)
        XCTAssertFalse(app.allowExecution())
        XCTAssertEqual(app.kernel.workingDirectory.map(WorkspaceTrust.path), WorkspaceTrust.path(first))
        app.keepKernelSession()
        XCTAssertTrue(app.allowExecution())
        XCTAssertTrue(app.kernelUsesDifferentDirectory)
        let retainedResult = try await result("open('data.csv').read()", app: app)
        XCTAssertEqual(retainedResult, "'A'")
        app.synchronizeWorkspaceKernel()
        let transition = try XCTUnwrap(app.kernelTransition)
        app.applyKernelTransition(transition)
        try await waitForIdle(app)
        let switchedResult = try await result("open('data.csv').read()", app: app)
        XCTAssertEqual(switchedResult, "'B'")
        XCTAssertFalse(app.kernelUsesDifferentDirectory)
        XCTAssertEqual(app.kernel.workingDirectory.map(WorkspaceTrust.path), WorkspaceTrust.path(second))
    }

    @MainActor
    func testRestrictedWorkspaceCannotUseAnExistingKernel() async throws {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        app.startKernel()
        try await waitForIdle(app)
        app.openWorkspace(root)
        XCTAssertTrue(app.kernel.isRunning)
        app.runConsoleInput("restricted_code_ran = True")
        let script = Document(script: nil, text: "restricted_code_ran = True")
        app.runScript(script)
        let cell = NotebookCell(type: .code, source: "restricted_code_ran = True")
        let document = Document(notebook: Notebook(cells: [cell], metadata: [:]), url: nil)
        app.runCell(cell, in: document, advance: false)
        app.requestCompletions(code: "object.", cursor: 7) { matches, _, _ in
            XCTAssertTrue(matches.isEmpty)
        }
        let value = try await result("'restricted_code_ran' in globals()", app: app)
        XCTAssertEqual(value, "False")
        XCTAssertFalse(cell.isRunning)
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testMissingSelectedInterpreterDoesNotFallBack() {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = root.appendingPathComponent("missing-python").path
        app.startKernel()
        XCTAssertFalse(app.kernel.isRunning)
        XCTAssertEqual(app.kernelBanner, "Interpreter unavailable")
        XCTAssertNotNil(app.userNotice)
    }

    @MainActor
    func testMissingReplacementInterpreterKeepsRunningSession() async throws {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        app.startKernel()
        try await waitForIdle(app)
        app.selectPython(root.appendingPathComponent("missing-python").path)
        let transition = try XCTUnwrap(app.kernelTransition)
        app.applyKernelTransition(transition)
        XCTAssertTrue(app.kernel.isRunning)
        XCTAssertEqual(app.pythonPath, "/usr/bin/python3")
        XCTAssertNotNil(app.userNotice)
        let value = try await result("6 * 7", app: app)
        XCTAssertEqual(value, "42")
    }

    @MainActor
    func testInterpreterSelectionKeepsCurrentStateUntilConfirmed() async throws {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        app.startKernel()
        try await waitForIdle(app)
        app.selectPython(root.appendingPathComponent("other-python").path)
        XCTAssertNotNil(app.kernelTransition)
        XCTAssertEqual(app.pythonPath, "/usr/bin/python3")
        XCTAssertNil(QuantaDefaults.store.string(forKey: PythonLocator.defaultsKey))
        app.keepKernelSession()
        let value = try await result("6 * 7", app: app)
        XCTAssertEqual(value, "42")
    }

    @MainActor
    private func waitForIdle(_ app: AppState) async throws {
        for _ in 0..<500 {
            if app.kernel.status == .idle { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Kernel did not become idle: \(app.kernel.status)")
        throw NSError(domain: "WorkspaceTrustTests", code: 1)
    }

    @MainActor
    private func result(_ code: String, app: AppState) async throws -> String {
        let done = expectation(description: "Execution completed")
        var output = ""
        app.kernel.execute(code: code) { message in
            if message["type"] as? String == "result" { output = message["text"] as? String ?? "" }
            if message["type"] as? String == "done" {
                done.fulfill()
                return true
            }
            return false
        }
        await fulfillment(of: [done], timeout: 10)
        return output
    }
}
