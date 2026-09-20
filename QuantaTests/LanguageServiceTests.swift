import AppKit
import XCTest
@testable import Quanta

@MainActor
final class LanguageServiceTests: XCTestCase {
    func testFramingHandlesSplitHeadersUnicodeAndBatchedMessages() throws {
        let first = try LanguageMessageFramer.encode(["id": 1, "result": "🙂 café"])
        let second = try LanguageMessageFramer.encode(["id": 2, "result": [1, 2]])
        var framer = LanguageMessageFramer()
        var results: [[String: Any]] = []
        for byte in first + second { results += try framer.consume(Data([byte])) }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?["result"] as? String, "🙂 café")
        var batched = LanguageMessageFramer()
        XCTAssertEqual(try batched.consume(first + second).count, 2)
        var invalid = LanguageMessageFramer()
        XCTAssertThrowsError(try invalid.consume(Data("Content-Length: 999999999\r\n\r\n".utf8)))
    }

    func testNotebookMappingPreservesUTF16AndRejectsSeparators() throws {
        let root = URL(fileURLWithPath: "/tmp")
        let first = NotebookCell(type: .code, source: "title = '🙂'\r\nvalue = 3")
        let markdown = NotebookCell(type: .markdown, source: "# Not Python")
        let last = NotebookCell(type: .code, source: "print(value)")
        let notebook = Notebook(cells: [first, markdown, last], metadata: [:])
        let document = Document(notebook: notebook, url: root.appendingPathComponent("mapping.ipynb"))
        let mapping = try XCTUnwrap(LanguageDocument(document: document, root: root))
        XCTAssertFalse(mapping.text.contains("Not Python"))
        let position = try XCTUnwrap(mapping.position(editorID: last.id, offset: 6))
        XCTAssertEqual(position, LanguagePosition(line: 3, character: 6))
        XCTAssertEqual(mapping.location(position)?.editorID, last.id)
        XCTAssertEqual(mapping.location(position)?.offset, 6)
        XCTAssertNil(mapping.location(LanguagePosition(line: 2, character: 0)))
        XCTAssertNil(mapping.position(editorID: markdown.id, offset: 0))
        XCTAssertEqual(LanguagePosition.at(12, in: first.source)?.character, 12)
        XCTAssertEqual(LanguagePosition.offset(LanguagePosition(line: 1, character: 1), in: first.source), 15)
        notebook.cells.swapAt(0, 2)
        let moved = try XCTUnwrap(LanguageDocument(document: document, root: root))
        XCTAssertEqual(moved.uri, mapping.uri)
        XCTAssertEqual(moved.position(editorID: last.id, offset: 6)?.line, 0)
        last.cellType = .markdown
        XCTAssertNil(LanguageDocument(document: document, root: root)?.position(editorID: last.id, offset: 0))
    }

    func testRestrictedWorkspaceDoesNotLaunchConfiguredServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("pyright-langserver")
        let marker = root.appendingPathComponent("executed")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let defaults = QuantaDefaults.store
        let oldPath = defaults.object(forKey: "QuantaLanguageServer")
        defaults.set(executable.path, forKey: "QuantaLanguageServer")
        defer {
            if let oldPath { defaults.set(oldPath, forKey: "QuantaLanguageServer") }
            else { defaults.removeObject(forKey: "QuantaLanguageServer") }
        }
        let app = AppState()
        app.workspace = Workspace(rootURL: root, root: FileNode(url: root, name: "Restricted", isDirectory: true, children: []))
        app.language.observe(app, automatic: true)
        app.language.synchronize()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(app.language.ready)
        app.language.stop()
    }

    func testCancelledRequestsAndShutdownCompleteExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("server")
        let script = """
        #!/usr/bin/python3
        import sys, json
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                break
            size = int(line.split(b':')[1])
            sys.stdin.buffer.readline()
            message = json.loads(sys.stdin.buffer.read(size))
            if message.get('method') == 'fast':
                data = json.dumps({'jsonrpc':'2.0','id':message['id'],'result':'ok'}).encode()
                sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n' % len(data)).encode() + data)
                sys.stdout.buffer.flush()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let server = LanguageServer()
        defer { server.stop() }
        try server.start(executable: executable, root: root, environment: ProcessInfo.processInfo.environment)
        var cancelledCalls = 0
        let slow = server.request("slow", [:]) { result in XCTAssertNil(result); cancelledCalls += 1 }
        server.cancel(slow)
        server.cancel(slow)
        let fast = expectation(description: "Server remains responsive after cancellation")
        server.request("fast", [:]) { result in XCTAssertEqual(result as? String, "ok"); fast.fulfill() }
        await fulfillment(of: [fast], timeout: 5)
        var shutdownCalls = 0
        server.request("slow", [:]) { result in XCTAssertNil(result); shutdownCalls += 1 }
        server.stop()
        server.stop()
        XCTAssertEqual(cancelledCalls, 1)
        XCTAssertEqual(shutdownCalls, 1)
    }

    func testWorkspaceWatcherReportsCreatedAndRemovedPythonFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("created.py")
        var changes: [(URL, Int)] = []
        let watcher = try XCTUnwrap(WorkspaceWatcher(url: root, onFileChanges: { changes += $0 }, onChange: {}))
        try "value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil(message: { "Create events: \(changes)" }) { changes.contains { $0.0.lastPathComponent == "created.py" && $0.1 == 1 } }
        changes.removeAll()
        try FileManager.default.removeItem(at: file)
        try await waitUntil(message: { "Delete events: \(changes)" }) { changes.contains { $0.0.lastPathComponent == "created.py" && $0.1 == 3 } }
        withExtendedLifetime(watcher) {}
    }

    func testRealPyrightUnexecutedNotebookCompletionDefinitionsDiagnosticsAndChanges() async throws {
        let configured = ProcessInfo.processInfo.environment["QUANTA_TEST_PYRIGHT"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_QUANTA_TEST_PYRIGHT"] ?? ""
        guard let executable = PythonLanguageService.findServer(configured: configured) else {
            throw XCTSkip("Install Pyright or set QUANTA_TEST_PYRIGHT to run the live language-server test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PythonLanguageService()
        defer { service.stop() }
        service.start(executable: executable, root: root, python: "/usr/bin/python3")
        try await waitUntil { service.ready }
        let first = NotebookCell(type: .code, source: "class Example:\n    def transform(self, value: int) -> str:\n        return str(value)\n\nsample = Example()")
        let second = NotebookCell(type: .code, source: "sample.tran")
        let notebook = Notebook(cells: [first, NotebookCell(type: .markdown, source: "# Notes"), second], metadata: [:])
        let document = Document(notebook: notebook, url: root.appendingPathComponent("unexecuted.ipynb"))
        service.update([document], root: root)
        let completion = expectation(description: "Static completion")
        service.completions(editorID: second.id, code: second.source, offset: second.source.utf16.count) { matches, start, end in
            XCTAssertTrue(matches.contains("transform"), "Received \(matches)")
            XCTAssertEqual(start, 7)
            XCTAssertEqual(end, 11)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 20)
        second.source = "result = sample.transform(5)\nwrong: int = 'text'"
        service.update([document], root: root)
        let definition = expectation(description: "Cross-cell definition")
        service.request("textDocument/definition", editorID: second.id, code: second.source, offset: 20) { result, snapshot in
            let value = (result as? [[String: Any]])?.first ?? result as? [String: Any]
            let range = (value?["range"] ?? value?["targetSelectionRange"]) as? [String: Any]
            let position = LanguagePosition(range?["start"])
            XCTAssertNotNil(position)
            if let position { XCTAssertEqual(snapshot?.location(position)?.editorID, first.id) }
            definition.fulfill()
        }
        await fulfillment(of: [definition], timeout: 20)
        try await waitUntil { service.diagnostics[document.id, default: []].contains { $0.editorID == second.id && $0.line == 2 } }
        let old = service.diagnostics[document.id, default: []]
        XCTAssertTrue(old.contains { $0.message.contains("int") })
        let hover = expectation(description: "Static documentation")
        service.inspect(editorID: second.id, code: second.source, offset: 26) { info in
            XCTAssertNotNil(info)
            XCTAssertTrue((info?.signature ?? "").contains("value") || (info?.doc ?? "").contains("transform"))
            hover.fulfill()
        }
        await fulfillment(of: [hover], timeout: 20)
        notebook.cells.swapAt(1, 2)
        second.source = "result = sample.transform(5)\nwrong: int = 5"
        service.update([document], root: root)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(service.diagnostics[document.id, default: []].isEmpty)
        let mapping = try XCTUnwrap(LanguageDocument(document: document, root: root))
        service.receiveDiagnostics(["uri": mapping.uri, "version": 1, "diagnostics": [[
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "message": "stale",
        ]]])
        XCTAssertFalse(service.diagnostics[document.id, default: []].contains { $0.message == "stale" })
        service.update([], root: root)
        XCTAssertTrue(service.diagnostics.isEmpty)
        let module = root.appendingPathComponent("helpers.py")
        try "def compute(value: int) -> int:\n    return value + 1\n".write(to: module, atomically: true, encoding: .utf8)
        service.filesChanged([(module, 1)])
        let script = Document(script: root.appendingPathComponent("main.py"), text: "import helpers\nhelpers.comp")
        service.update([script], root: root)
        let imported = expectation(description: "Completion from an unexecuted imported module")
        service.completions(editorID: script.id, code: script.text, offset: script.text.utf16.count) { matches, _, _ in
            XCTAssertTrue(matches.contains("compute"), "Received \(matches)")
            imported.fulfill()
        }
        await fulfillment(of: [imported], timeout: 20)
        script.text = "import helpers\nhelpers.compute(5)"
        script.url = root.appendingPathComponent("renamed.py")
        service.update([script], root: root)
        let external = expectation(description: "Cross-file definition after rename")
        service.request("textDocument/definition", editorID: script.id, code: script.text, offset: 26) { result, _ in
            let item = (result as? [[String: Any]])?.first ?? result as? [String: Any]
            XCTAssertEqual(item?["uri"] as? String ?? item?["targetUri"] as? String, module.absoluteString)
            external.fulfill()
        }
        await fulfillment(of: [external], timeout: 20)
    }

    private func waitUntil(message: () -> String = { "Timed out waiting for language-server state" }, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(message())
        throw QuantaError("Language-server test timed out")
    }
}
