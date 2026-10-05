import XCTest
@testable import Quanta

final class PythonEnvironmentManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testRequirementInputAcceptsNamesExtrasAndVersionConstraints() throws {
        XCTAssertEqual(try PythonEnvironmentManager.packageRequirements(" pandas>=2,<3\nscikit-learn numpy==2.1.0 dask[array,dataframe] x "),
                       ["pandas>=2,<3", "scikit-learn", "numpy==2.1.0", "dask[array,dataframe]", "x"])
        for input in ["", " ", "--target=/tmp/elsewhere pandas", "-r requirements.txt", "./local",
                      "https://example.com/package.whl", "pandas;touch /tmp/unwanted", "$(touch marker)",
                      "numpy @ https://example.com/numpy.whl", "'numpy'", "numpy\u{0}"] {
            XCTAssertThrowsError(try PythonEnvironmentManager.packageRequirements(input), input)
        }
    }

    @MainActor
    func testPackageListingUsesSelectedInterpreterAndIsolatedArguments() async throws {
        let record = root.appendingPathComponent("invocation.json")
        let python = try interpreter("""
        import json, os, sys
        with open(\(literal(record.path)), 'w') as output:
            json.dump({'args': sys.argv[1:], 'cwd': os.getcwd(), 'pip_config': os.environ.get('PIP_CONFIG_FILE'), 'stdin': sys.stdin.read()}, output)
        print('[{"name":"pandas","version":"2.2.3"},{"name":"numpy","version":"2.1.0"}]')
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        await manager.refreshPackages()
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.hasLoadedPackages)
        XCTAssertEqual(manager.packages.map(\.name), ["numpy", "pandas"])
        let invocation = try recordContents(record)
        XCTAssertEqual(invocation["args"] as? [String],
                       ["-I", "-u", "-m", "pip", "--isolated", "--disable-pip-version-check", "--no-input", "list", "--format=json"])
        let directory = try XCTUnwrap(invocation["cwd"] as? String)
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: root.path)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: directory)
        for key in [FileAttributeKey.systemNumber, .systemFileNumber] {
            XCTAssertEqual(try XCTUnwrap(actualDirectory[key] as? NSNumber),
                           try XCTUnwrap(expectedDirectory[key] as? NSNumber))
        }
        XCTAssertEqual(invocation["pip_config"] as? String, "/dev/null")
        XCTAssertEqual(invocation["stdin"] as? String, "")
        XCTAssertFalse(manager.isBusy)
    }

    @MainActor
    func testInstallDoesNotUseShellOrAllowPipDestinationOptions() async throws {
        let record = root.appendingPathComponent("invocation.json")
        let python = try interpreter("""
        import json, sys
        with open(\(literal(record.path)), 'w') as output:
            json.dump({'args': sys.argv[1:]}, output)
        print('Successfully installed example')
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let invalidResult = await manager.installPackages("--target /tmp/unwanted pandas")
        XCTAssertFalse(invalidResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        let installed = await manager.installPackages("pandas>=2,<3 numpy")
        XCTAssertTrue(installed)
        XCTAssertTrue(manager.restartRecommended)
        let invocation = try recordContents(record)
        let arguments = try XCTUnwrap(invocation["args"] as? [String])
        XCTAssertEqual(Array(arguments.suffix(7)), ["install", "--no-user", "--progress-bar", "off", "--", "pandas>=2,<3", "numpy"])
        XCTAssertTrue(manager.commandOutput.contains("Successfully installed"))
        XCTAssertTrue(manager.statusMessage?.contains("Restart") == true)
    }

    @MainActor
    func testUntrustedOrRunningKernelCannotLaunchPackageCommands() async throws {
        let marker = root.appendingPathComponent("launched")
        let python = try interpreter("open(\(literal(marker.path)), 'w').close()")
        let manager = PythonEnvironmentManager()
        for (trusted, busy) in [(false, false), (true, true)] {
            manager.configure(python: python, workspace: root, trusted: trusted, kernelBusy: busy)
            await manager.refreshPackages()
            let installed = await manager.installPackages("pandas")
            let environment = await manager.createEnvironment()
            XCTAssertFalse(installed)
            XCTAssertNil(environment)
            XCTAssertFalse(manager.canManage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
        }
    }

    @MainActor
    func testWorkspaceEnvironmentCreationNeverOverwritesAnExistingDirectory() async throws {
        let destination = root.appendingPathComponent(".venv", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("existing.txt")
        try "keep this environment".write(to: sentinel, atomically: true, encoding: .utf8)
        let marker = root.appendingPathComponent("launched")
        let python = try interpreter("open(\(literal(marker.path)), 'w').close()")
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        XCTAssertTrue(manager.workspaceEnvironmentExists)
        let result = await manager.createEnvironment()
        XCTAssertNil(result)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep this environment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(manager.errorMessage?.contains("already exists") == true)
    }

    @MainActor
    func testWorkspaceEnvironmentCreationRefusesDanglingSymlink() async throws {
        let destination = root.appendingPathComponent(".venv")
        let target = root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let python = try interpreter("raise RuntimeError('must not execute')")
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let result = await manager.createEnvironment()
        XCTAssertNil(result)
        XCTAssertTrue(manager.workspaceEnvironmentExists)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
    }

    @MainActor
    func testCreatesEnvironmentWithSelectedPythonAndReturnsItsInterpreter() async throws {
        let record = root.appendingPathComponent("invocation.json")
        let python = try interpreter("""
        import json, os, sys
        with open(\(literal(record.path)), 'w') as output:
            json.dump({'args': sys.argv[1:]}, output)
        destination = sys.argv[-1]
        os.mkdir(os.path.join(destination, 'bin'))
        path = os.path.join(destination, 'bin', 'python3')
        with open(path, 'w') as output:
            output.write('mock interpreter')
        os.chmod(path, 0o755)
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let result = await manager.createEnvironment()
        XCTAssertEqual(result, root.appendingPathComponent(".venv/bin/python3").path)
        XCTAssertTrue(manager.workspaceEnvironmentExists)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try recordContents(record)["args"] as? [String],
                       ["-I", "-m", "venv", root.appendingPathComponent(".venv").path])
        XCTAssertEqual(manager.python, python)
        XCTAssertFalse(manager.restartRecommended)
    }

    @MainActor
    func testFailedEnvironmentCreationExplainsHowToRecover() async throws {
        let python = try interpreter("""
        import sys
        print('No module named venv', file=sys.stderr)
        sys.exit(1)
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let result = await manager.createEnvironment()
        XCTAssertNil(result)
        XCTAssertTrue(manager.workspaceEnvironmentExists)
        XCTAssertTrue(manager.errorMessage?.contains("venv and ensurepip") == true)
        XCTAssertTrue(manager.errorMessage?.contains("incomplete .venv") == true)
    }

    @MainActor
    func testMissingPipHasActionableError() async throws {
        let python = try interpreter("""
        import sys
        print('No module named pip', file=sys.stderr)
        sys.exit(1)
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        await manager.refreshPackages()
        XCTAssertFalse(manager.hasLoadedPackages)
        XCTAssertTrue(manager.errorMessage?.contains("ensurepip") == true)
        XCTAssertTrue(manager.errorMessage?.contains(".venv") == true)
    }

    @MainActor
    func testSwitchingInterpreterDiscardsAnInFlightResult() async throws {
        let marker = root.appendingPathComponent("launched")
        let first = try interpreter("""
        import time
        open(\(literal(marker.path)), 'w').close()
        time.sleep(5)
        print('[{"name":"old-environment","version":"1"}]')
        """, name: "first-python")
        let second = try interpreter("print('[{\"name\":\"new-environment\",\"version\":\"2\"}]')", name: "second-python")
        let manager = PythonEnvironmentManager()
        manager.configure(python: first, workspace: root, trusted: true, kernelBusy: false)
        let oldTask = Task { await manager.refreshPackages() }
        try await waitForFile(marker)
        manager.configure(python: second, workspace: root, trusted: true, kernelBusy: false)
        await manager.refreshPackages()
        await oldTask.value
        XCTAssertEqual(manager.packages, [PythonPackage(name: "new-environment", version: "2")])
        XCTAssertEqual(manager.python, second)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testChangingWorkspaceInvalidatesPackageResults() async throws {
        let python = try interpreter("print('[{\"name\":\"example\",\"version\":\"1\"}]')")
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        await manager.refreshPackages()
        XCTAssertTrue(manager.hasLoadedPackages)
        manager.configure(python: python, workspace: other, trusted: true, kernelBusy: false)
        XCTAssertFalse(manager.hasLoadedPackages)
        XCTAssertTrue(manager.packages.isEmpty)
    }

    @MainActor
    func testCancellationStopsAnInterpreterThatIgnoresTermination() async throws {
        let marker = root.appendingPathComponent("launched")
        let python = try interpreter("""
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(\(literal(marker.path)), 'w').close()
        time.sleep(60)
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let task = Task { await manager.installPackages("example") }
        try await waitForFile(marker)
        manager.cancel()
        let installed = await task.value
        XCTAssertFalse(installed)
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(manager.restartRecommended)
        XCTAssertTrue(manager.statusMessage?.contains("canceled") == true)
    }

    @MainActor
    func testTimedOutInterpreterDoesNotLeaveManagerBusy() async throws {
        let python = try interpreter("""
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """)
        let manager = PythonEnvironmentManager(listingTimeout: 0.2)
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        await manager.refreshPackages()
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(manager.errorMessage?.contains("timed out") == true)
    }

    @MainActor
    func testCancellationStopsPackageBuildSubprocesses() async throws {
        let started = root.appendingPathComponent("child-started")
        let unwanted = root.appendingPathComponent("child-kept-running")
        let child = """
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(\(literal(started.path)), 'w').close()
        time.sleep(1)
        open(\(literal(unwanted.path)), 'w').close()
        """
        let python = try interpreter("""
        import subprocess, sys, time
        subprocess.Popen([sys.executable, '-c', \(literal(child))])
        time.sleep(60)
        """)
        let manager = PythonEnvironmentManager()
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let task = Task { await manager.installPackages("example") }
        try await waitForFile(started)
        manager.cancel()
        let installed = await task.value
        XCTAssertFalse(installed)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwanted.path))
    }

    @MainActor
    func testLargeOutputIsDrainedAndDisplayRemainsBounded() async throws {
        let python = try interpreter("""
        import sys
        sys.stdout.write('x' * 1500000)
        sys.stderr.write('y' * 1500000)
        sys.exit(1)
        """)
        let manager = PythonEnvironmentManager(operationTimeout: 5)
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let result = await manager.installPackages("example")
        XCTAssertFalse(result)
        XCTAssertLessThanOrEqual(manager.commandOutput.utf8.count, 32_768)
        XCTAssertLessThanOrEqual(manager.errorMessage?.utf8.count ?? 0, 4096)
        XCTAssertFalse(manager.isBusy)
    }

    @MainActor
    func testMutationGuardRemainsActiveWhileAnOldContextStops() async throws {
        let marker = root.appendingPathComponent("launched")
        let python = try interpreter("""
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(\(literal(marker.path)), 'w').close()
        time.sleep(60)
        """)
        var changes: [Bool] = []
        let manager = PythonEnvironmentManager(onMutationChanged: { changes.append($0) })
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let task = Task { await manager.installPackages("example") }
        try await waitForFile(marker)
        manager.configure(python: nil, workspace: nil, trusted: true, kernelBusy: false)
        XCTAssertTrue(manager.isMutating)
        XCTAssertTrue(manager.isBusy)
        let installed = await task.value
        XCTAssertFalse(installed)
        XCTAssertFalse(manager.isMutating)
        XCTAssertFalse(manager.isBusy)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor
    func testAppPreventsExecutionAndKernelLaunchDuringPackageChanges() async throws {
        let marker = root.appendingPathComponent("launched")
        let python = try interpreter("""
        import time
        open(\(literal(marker.path)), 'w').close()
        time.sleep(60)
        """)
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = root.appendingPathComponent("unavailable-python").path
        let manager = app.pythonEnvironmentManager
        manager.configure(python: python, workspace: root, trusted: true, kernelBusy: false)
        let task = Task { await manager.installPackages("example") }
        try await waitForFile(marker)
        XCTAssertTrue(app.pythonEnvironmentMutationInProgress)
        XCTAssertFalse(app.allowExecution())
        app.startKernel()
        app.restartKernel(confirm: false)
        XCTAssertFalse(app.kernel.isRunning)
        XCTAssertTrue(app.environments.isEmpty)
        XCTAssertTrue(app.userNotice?.contains("environment operation") == true)
        manager.cancel()
        let installed = await task.value
        XCTAssertFalse(installed)
        XCTAssertFalse(app.pythonEnvironmentMutationInProgress)
        XCTAssertTrue(app.allowExecution())
    }

    private func interpreter(_ body: String, name: String = "mock-python") throws -> String {
        let file = root.appendingPathComponent(name)
        try ("#!/usr/bin/python3\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    private func literal(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try! encoder.encode(string), encoding: .utf8)!
    }

    private func recordContents(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    @MainActor
    private func waitForFile(_ file: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "PythonEnvironmentManagerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Mock Python did not start."])
    }
}
