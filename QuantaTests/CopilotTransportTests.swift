import XCTest
import Darwin
@testable import Quanta

final class CopilotTransportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFramingHandlesUnicodeFragmentationAndMultipleMessages() throws {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "result": "α🧪\n变量"],
            ["jsonrpc": "2.0", "method": "didChangeStatus", "params": ["kind": "Normal"]],
        ]
        let combined = try messages.reduce(into: Data()) { $0.append(try CopilotMessageFramer.encode($1)) }
        var framer = CopilotMessageFramer()
        var decoded: [Data] = []
        for offset in stride(from: 0, to: combined.count, by: 3) {
            decoded += try framer.consume(combined.subdata(in: offset..<min(offset + 3, combined.count)))
        }
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: decoded[0]) as? [String: Any])?["result"] as? String, "α🧪\n变量")
        XCTAssertFalse(framer.hasPartialMessage)
        var batch = CopilotMessageFramer()
        XCTAssertEqual(try batch.consume(combined).count, 2)
    }

    func testFramingRejectsUnboundedAndMalformedHeaders() {
        for header in ["Content-Length: -1\r\n\r\n", "Content-Length: 999999999\r\n\r\n",
                       "Content-Length: 3\r\nContent-Length: 3\r\n\r\n", "Missing: 3\r\n\r\n",
                       "Content-Length: no\r\n\r\n", String(repeating: "x", count: 8193)] {
            var framer = CopilotMessageFramer()
            XCTAssertThrowsError(try framer.consume(Data(header.utf8)))
        }
    }

    @MainActor
    func testRealProcessRoundTripUsesStdioAndFragmentedUnicode() async throws {
        let helper = try script("""
        assert sys.argv[1:] == ['--stdio']
        while True:
            item = receive()
            if item is None:
                break
            if 'id' in item:
                send({'id': item['id'], 'result': item['params']}, fragmented=True)
        """)
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        try transport.start(executable: helper)
        let result = try await transport.request("echo", params: ["text": "α🧪 变量"], timeout: 5)
        XCTAssertEqual((result as? [String: Any])?["text"] as? String, "α🧪 变量")
    }

    @MainActor
    func testServerRequestsAndNotificationsReachMainActorHandlers() async throws {
        let helper = try script("""
        item = receive()
        send({'method': 'didChangeStatus', 'params': {'kind': 'Normal'}})
        send({'id': 'server-request', 'method': 'window/showDocument', 'params': {'uri': 'https://github.com/login/device'}})
        response = receive()
        send({'id': item['id'], 'result': response.get('result')})
        receive()
        """)
        let notification = expectation(description: "Status notification")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        transport.onNotification = { method, params in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(method, "didChangeStatus")
            XCTAssertEqual(params["kind"] as? String, "Normal")
            notification.fulfill()
        }
        transport.onRequest = { method, params in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(method, "window/showDocument")
            XCTAssertEqual(params["uri"] as? String, "https://github.com/login/device")
            return ["success": true]
        }
        try transport.start(executable: helper)
        let result = try await transport.request("initialize", params: [:], timeout: 5)
        XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
        await fulfillment(of: [notification], timeout: 2)
    }

    @MainActor
    func testRequestCancellationSendsProtocolCancellation() async throws {
        let helper = try script(cancellationServer)
        let ready = expectation(description: "Request received")
        let cancelled = expectation(description: "Cancellation received")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        transport.onNotification = { method, _ in
            if method == "ready" { ready.fulfill() }
            if method == "cancelled" { cancelled.fulfill() }
        }
        try transport.start(executable: helper)
        let request = Task { try await transport.request("wait", params: [:], timeout: 5) }
        await fulfillment(of: [ready], timeout: 3)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancellation must fail the pending request") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 3)
    }

    @MainActor
    func testTimeoutSendsCancellationAndReleasesPendingRequest() async throws {
        let helper = try script(cancellationServer)
        let cancelled = expectation(description: "Cancellation received")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        transport.onNotification = { method, _ in if method == "cancelled" { cancelled.fulfill() } }
        try transport.start(executable: helper)
        do { _ = try await transport.request("wait", params: [:], timeout: 0.2); XCTFail("Request must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too long")) }
        await fulfillment(of: [cancelled], timeout: 3)
    }

    @MainActor
    func testProcessExitCompletesPendingRequestsAndReportsTermination() async throws {
        let helper = try script("receive()\nsys.exit(7)")
        let terminated = expectation(description: "Helper terminated")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        transport.onTermination = { message in
            XCTAssertFalse(message.isEmpty)
            terminated.fulfill()
        }
        try transport.start(executable: helper)
        do { _ = try await transport.request("exit", params: [:], timeout: 5); XCTFail("Exited helper must fail pending requests") }
        catch { XCTAssertFalse(error is CancellationError) }
        await fulfillment(of: [terminated], timeout: 2)
    }

    @MainActor
    func testStopCancelsPendingAndANewSessionStillWorks() async throws {
        let helper = try script(cancellationServer, name: "waiting")
        let echo = try script("item = receive()\nsend({'id': item['id'], 'result': 'new session'})\nreceive()", name: "echo")
        let ready = expectation(description: "Old request received")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        transport.onNotification = { method, _ in if method == "ready" { ready.fulfill() } }
        try transport.start(executable: helper)
        let old = Task { try await transport.request("wait", params: [:], timeout: 5) }
        await fulfillment(of: [ready], timeout: 3)
        try transport.start(executable: echo)
        do { _ = try await old.value; XCTFail("Old session request must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await transport.request("echo", params: [:], timeout: 5)
        XCTAssertEqual(result as? String, "new session")
    }

    @MainActor
    func testClosedInputPipeDoesNotCrashOrHangTheApp() async throws {
        let helper = try script("os.close(0)\ntime.sleep(1)")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        try transport.start(executable: helper)
        try await Task.sleep(for: .milliseconds(150))
        do {
            _ = try await transport.request("closed", params: ["text": String(repeating: "x", count: 200_000)], timeout: 2)
            XCTFail("A closed input pipe must fail the request")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @MainActor
    func testMalformedServerOutputFailsPendingRequests() async throws {
        let helper = try script("receive()\nsys.stdout.buffer.write(b'Content-Length: 999999999\\r\\n\\r\\n')\nsys.stdout.buffer.flush()\ntime.sleep(1)")
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        try transport.start(executable: helper)
        do { _ = try await transport.request("bad", params: [:], timeout: 3); XCTFail("Malformed output must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid or oversized")) }
    }

    @MainActor
    func testServerErrorsAreReturnedWithoutClosingTheConnection() async throws {
        let helper = try script("""
        item = receive()
        send({'id': item['id'], 'error': {'code': -32001, 'message': 'Not signed in'}})
        item = receive()
        send({'id': item['id'], 'result': 'still connected'})
        receive()
        """)
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        try transport.start(executable: helper)
        do { _ = try await transport.request("first", params: [:], timeout: 3); XCTFail("Server error must be thrown") }
        catch CopilotTransportError.server(let code, let message) {
            XCTAssertEqual(code, -32001)
            XCTAssertEqual(message, "Not signed in")
        }
        let result = try await transport.request("second", params: [:], timeout: 3)
        XCTAssertEqual(result as? String, "still connected")
    }

    @MainActor
    func testBooleanResponseIDCannotCompleteAnIntegerRequest() async throws {
        let helper = try script("""
        item = receive()
        send({'id': True, 'result': 'wrong response'})
        send({'id': item['id'], 'result': 'matching response'})
        receive()
        """)
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        defer { transport.stop() }
        try transport.start(executable: helper)
        let result = try await transport.request("echo", params: [:], timeout: 3)
        XCTAssertEqual(result as? String, "matching response")
    }

    @MainActor
    func testStopKillsHelperThatIgnoresTermination() async throws {
        let helper = try script("""
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        item = receive()
        send({'id': item['id'], 'result': os.getpid()})
        time.sleep(60)
        """)
        let transport = CopilotProcessTransport(configurationDirectory: root.appendingPathComponent("profile"))
        try transport.start(executable: helper)
        let result = try await transport.request("pid", params: [:], timeout: 3)
        let pid = try XCTUnwrap(result as? Int32)
        transport.stop()
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
    }

    @MainActor
    func testHelperUsesItsOwnProfileAndDoesNotInheritAuthenticationOrNodeInjection() async throws {
        let helper = try script("""
        item = receive()
        blocked = [key for key in os.environ if key.startswith(('GITHUB_', 'GH_', 'COPILOT_')) or key in ['NODE_OPTIONS', 'NODE_PATH', 'NODE_TLS_REJECT_UNAUTHORIZED']]
        send({'id': item['id'], 'result': {'config': os.environ.get('XDG_CONFIG_HOME'), 'blockedNames': blocked}})
        receive()
        """)
        let profile = root.appendingPathComponent("isolated-profile")
        let transport = CopilotProcessTransport(configurationDirectory: profile, inheritedEnvironment: [
            "PATH": "/usr/bin:/bin", "HOME": root.path,
            "GITHUB_TOKEN": "fixture", "GH_TOKEN": "fixture", "COPILOT_CUSTOM_TOKEN": "fixture",
            "NODE_OPTIONS": "fixture", "NODE_PATH": "fixture", "NODE_TLS_REJECT_UNAUTHORIZED": "0",
            "XDG_CONFIG_HOME": root.appendingPathComponent("another-editor").path,
        ])
        defer { transport.stop() }
        try transport.start(executable: helper)
        let result = try await transport.request("environment", params: [:], timeout: 3)
        let fields = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(fields["config"] as? String, profile.path)
        XCTAssertEqual(fields["blockedNames"] as? [String], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("another-editor").path))
    }

    @MainActor
    func testInstallerRejectsChecksumMismatchBeforeExtraction() async throws {
        let archive = root.appendingPathComponent("invalid.zip")
        try Data("not a release".utf8).write(to: archive)
        let fixture = CopilotDownloadFixture(archive: archive, directory: root)
        let directory = root.appendingPathComponent("installed")
        let release = CopilotInstaller.Release(version: "test", url: URL(string: "https://github.com/example.zip")!, sha256: String(repeating: "0", count: 64))
        let installer = CopilotInstaller(installationDirectory: directory, release: release,
                                         downloader: { try await fixture.download($0) })
        do { _ = try await installer.executable(); XCTFail("Checksum mismatch must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("integrity check")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testInstallerAtomicallyInstallsAndReusesVerifiedNativeHelper() async throws {
        let archive = try helperArchive()
        let fixture = CopilotDownloadFixture(archive: archive, directory: root)
        let directory = root.appendingPathComponent("installed")
        let release = CopilotInstaller.Release(version: "test", url: URL(string: "https://github.com/example.zip")!, sha256: try CopilotInstaller.sha256(of: archive))
        let installer = CopilotInstaller(installationDirectory: directory, release: release,
                                         downloader: { try await fixture.download($0) })
        let executable = try await installer.executable()
        try CopilotInstaller.validateExecutable(executable)
        let firstHash = try CopilotInstaller.sha256(of: executable)
        let cached = try await installer.executable()
        XCTAssertEqual(cached, executable)
        let firstDownloads = await fixture.count
        XCTAssertEqual(firstDownloads, 1)
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("modified".utf8))
        try handle.close()
        let replaced = try await installer.executable()
        XCTAssertEqual(try CopilotInstaller.sha256(of: replaced), firstHash)
        let secondDownloads = await fixture.count
        XCTAssertEqual(secondDownloads, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["test"])
    }

    @MainActor
    func testInstallerCancellationStopsTheDownload() async throws {
        let directory = root.appendingPathComponent("installed")
        let installer = CopilotInstaller(installationDirectory: directory, downloader: { _ in
            try await Task.sleep(for: .seconds(60))
            throw CopilotInstallerError.failed("Canceled download continued")
        })
        let task = Task { try await installer.executable() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled download must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testInstallerRejectsScriptsAndSymlinkedHelpers() async throws {
        let executable = root.appendingPathComponent("helper")
        try Data("not native".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let installer = CopilotInstaller(bundledExecutable: executable)
        do { _ = try await installer.executable(); XCTFail("Non-native helper must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Apple Silicon")) }
        let link = root.appendingPathComponent("linked-helper")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertThrowsError(try CopilotInstaller.validateExecutable(link))
    }

    private var cancellationServer: String {
        """
        while True:
            item = receive()
            if item is None:
                break
            if item.get('method') == '$/cancelRequest':
                send({'method': 'cancelled', 'params': item.get('params', {})})
            elif 'id' in item:
                send({'method': 'ready', 'params': {}})
        """
    }

    private func script(_ body: String, name: String = "copilot-helper") throws -> URL {
        let file = root.appendingPathComponent(name)
        let prelude = """
        #!/usr/bin/python3
        import json, os, sys, time
        def receive():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line == b'\\r\\n':
                    break
                key, value = line.decode('ascii').split(':', 1)
                headers[key.lower()] = value.strip()
            return json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
        def send(message, fragmented=False):
            message['jsonrpc'] = '2.0'
            body = json.dumps(message, ensure_ascii=False).encode('utf-8')
            frame = ('Content-Length: %d\\r\\n\\r\\n' % len(body)).encode('ascii') + body
            if fragmented:
                for index in range(0, len(frame), 3):
                    sys.stdout.buffer.write(frame[index:index + 3])
                    sys.stdout.buffer.flush()
            else:
                sys.stdout.buffer.write(frame)
                sys.stdout.buffer.flush()
        """
        try (prelude + "\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func helperArchive() throws -> URL {
        let folder = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("copilot-language-server")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + Array("fixture".utf8)).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archive = root.appendingPathComponent("helper.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}

private actor CopilotDownloadFixture {
    let archive: URL
    let directory: URL
    private(set) var count = 0

    init(archive: URL, directory: URL) { self.archive = archive; self.directory = directory }

    func download(_ url: URL) throws -> URL {
        count += 1
        let copy = directory.appendingPathComponent("download-" + UUID().uuidString + ".zip")
        try FileManager.default.copyItem(at: archive, to: copy)
        return copy
    }
}
