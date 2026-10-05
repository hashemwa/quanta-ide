import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class CopilotServiceTests: XCTestCase {
    private func makeService(_ suppliedTransport: StubCopilotTransport? = nil,
                             openURL: @escaping @MainActor (URL) -> Bool = { _ in false },
                             copyCode: @escaping @MainActor (String) -> Void = { _ in }) throws -> (CopilotService, StubCopilotTransport, UserDefaults) {
        let transport = suppliedTransport ?? StubCopilotTransport()
        let name = "quanta.copilot-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let service = CopilotService(defaults: defaults, makeTransport: { transport },
                                     executable: { URL(fileURLWithPath: "/unused-copilot-test-helper") },
                                     openURL: openURL, copyCode: copyCode)
        addTeardownBlock { @MainActor in
            service.shutdown()
            defaults.removePersistentDomain(forName: name)
        }
        return (service, transport, defaults)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate())
    }

    private func signIn(_ service: CopilotService) async throws {
        service.beginSignIn()
        try await waitUntil { service.phase == .ready }
        XCTAssertTrue(service.canSuggest)
    }

    func testUnconfiguredAppDoesNotStartHelperOrShareCode() async throws {
        let (service, transport, defaults) = try makeService()
        let document = Document(script: nil, text: "private_data = 1")
        let suggestion = await service.completion(document: document, sourceID: document.id,
                                                   source: document.text, caret: document.text.utf16.count)
        XCTAssertNil(suggestion)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: CopilotService.consentKey))
        XCTAssertEqual(transport.starts, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(transport.notifications.isEmpty)
    }

    func testSignInEnablesSuggestionsWithoutSendingDocuments() async throws {
        let (service, transport, defaults) = try makeService()
        try await signIn(service)
        XCTAssertEqual(service.account, "quanta-test")
        XCTAssertTrue(defaults.bool(forKey: CopilotService.enabledKey))
        XCTAssertTrue(defaults.bool(forKey: CopilotService.consentKey))
        XCTAssertEqual(transport.requests.map(\.0), ["initialize", "signIn", "checkStatus"])
        XCTAssertFalse(transport.notifications.contains { $0.0.hasPrefix("textDocument/") })
    }

    func testFirstUseDeviceSignInWaitsForAccountAccessBeforeSendingDocuments() async throws {
        var copiedCodes: [String] = []
        let (service, transport, defaults) = try makeService(copyCode: { copiedCodes.append($0) })
        transport.useDeviceFlow()
        transport.holdStatus = true
        defer {
            transport.pendingStatus?.resume(throwing: CancellationError())
            transport.pendingStatus = nil
        }
        let document = Document(script: nil, text: "private_data = ")
        service.beginSignIn()
        try await waitUntil { service.phase == .deviceCode }
        XCTAssertEqual(service.deviceCode, "QUANTA-TEST")
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.canSuggest)
        XCTAssertNil(service.account)
        XCTAssertTrue(copiedCodes.isEmpty)
        XCTAssertEqual(transport.requests.map(\.0), ["initialize", "signIn"])
        let beforeBrowser = await service.completion(document: document, sourceID: document.id,
                                                      source: document.text, caret: document.text.utf16.count)
        XCTAssertNil(beforeBrowser)

        service.continueSignIn()
        XCTAssertEqual(copiedCodes, ["QUANTA-TEST"])
        try await waitUntil { transport.pendingDeviceFlow != nil }
        XCTAssertEqual(service.phase, .signingIn)
        XCTAssertFalse(service.canSuggest)
        let command = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(command.0, "workspace/executeCommand")
        XCTAssertEqual(command.1["command"] as? String, "github.copilot.finishDeviceFlow")
        XCTAssertEqual(command.1["arguments"] as? [String], ["fixture-device-flow"])
        let awaitingBrowser = await service.completion(document: document, sourceID: document.id,
                                                        source: document.text, caret: document.text.utf16.count)
        XCTAssertNil(awaitingBrowser)

        transport.pendingDeviceFlow?.resume(returning: ["status": "OK"])
        transport.pendingDeviceFlow = nil
        try await waitUntil { transport.pendingStatus != nil }
        XCTAssertEqual(service.phase, .signingIn)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.canSuggest)
        let awaitingAccess = await service.completion(document: document, sourceID: document.id,
                                                       source: document.text, caret: document.text.utf16.count)
        XCTAssertNil(awaitingAccess)
        XCTAssertEqual(transport.requests.map(\.0), ["initialize", "signIn", "workspace/executeCommand", "checkStatus"])
        XCTAssertFalse(transport.notifications.contains { $0.0.hasPrefix("textDocument/") })

        transport.pendingStatus?.resume(returning: ["status": "OK", "user": "quanta-test"])
        transport.pendingStatus = nil
        try await waitUntil { service.phase == .ready }
        XCTAssertTrue(service.canSuggest)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.account, "quanta-test")
        XCTAssertNil(service.deviceCode)
        XCTAssertTrue(defaults.bool(forKey: CopilotService.enabledKey))
        XCTAssertTrue(defaults.bool(forKey: CopilotService.consentKey))
        XCTAssertFalse(transport.notifications.contains { $0.0.hasPrefix("textDocument/") })

        transport.inlineResult = ["items": [["insertText": "42"]]]
        let suggestion = await service.completion(document: document, sourceID: document.id,
                                                   source: document.text, caret: document.text.utf16.count)
        XCTAssertEqual(suggestion?.text, "42")
        XCTAssertTrue(transport.notifications.contains { $0.0 == "textDocument/didOpen" })
        XCTAssertEqual(transport.requests.last?.0, "textDocument/inlineCompletion")
    }

    func testNotebookContextExcludesMarkdownAndMapsSuggestionsToTheActiveCell() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        let earlier = NotebookCell(type: .code, source: "import pandas as pd")
        let prose = NotebookCell(type: .markdown, source: "private prose")
        let active = NotebookCell(type: .code, source: "df = pd.")
        let document = Document(notebook: Notebook(cells: [earlier, prose, active], metadata: [:]), url: nil)
        transport.inlineResult = ["items": [["insertText": "read_csv(path)",
                                             "range": ["start": ["line": 2, "character": 8],
                                                       "end": ["line": 2, "character": 8]]]]]
        let result = await service.completion(document: document, sourceID: active.id, source: active.source, caret: 8)
        XCTAssertEqual(result?.range, NSRange(location: 8, length: 0))
        XCTAssertEqual(result?.text, "read_csv(path)")
        let opened = try XCTUnwrap(transport.notifications.first { $0.0 == "textDocument/didOpen" })
        let text = try XCTUnwrap((opened.1["textDocument"] as? [String: Any])?["text"] as? String)
        XCTAssertEqual(text, "import pandas as pd\n\ndf = pd.")
        XCTAssertFalse(text.contains("private prose"))
    }

    func testTurningOffRejectsLateResultsAndStopsAllDocumentUpdates() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        transport.holdCompletion = true
        let document = Document(script: nil, text: "print")
        let pending = Task { await service.completion(document: document, sourceID: document.id, source: "print", caret: 5) }
        try await waitUntil { transport.pendingCompletion != nil }
        service.setEnabled(false)
        let notificationCount = transport.notifications.count
        transport.pendingCompletion?.resume(returning: ["items": [["insertText": "(42)"]]])
        transport.pendingCompletion = nil
        let lateResult = await pending.value
        XCTAssertNil(lateResult)
        XCTAssertGreaterThan(transport.stops, 0)
        XCTAssertEqual(service.account, "quanta-test")
        document.text = "private_after_disable"
        let disabledResult = await service.completion(document: document, sourceID: document.id,
                                                       source: document.text, caret: document.text.utf16.count)
        XCTAssertNil(disabledResult)
        XCTAssertEqual(transport.notifications.count, notificationCount)
    }

    func testProjectDisablePersistsAndStopsRequestsImmediately() async throws {
        let (service, transport, defaults) = try makeService()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-project-\(UUID())")
        service.updateWorkspace(project, trusted: true)
        try await signIn(service)
        service.setProjectDisabled(true)
        XCTAssertTrue(service.isProjectDisabled)
        XCTAssertFalse(service.canSuggest)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(defaults.stringArray(forKey: CopilotService.disabledProjectsKey), [WorkspaceTrust.path(project)])
        let requestCount = transport.requests.count
        let document = Document(script: project.appendingPathComponent("a.py"), text: "private")
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: 7)
        XCTAssertEqual(transport.requests.count, requestCount)
    }

    func testUntrustedWorkspaceDoesNotSendSourceAfterAccountConnects() async throws {
        let (service, transport, _) = try makeService()
        service.updateWorkspace(FileManager.default.temporaryDirectory, trusted: false)
        service.beginSignIn()
        try await waitUntil { service.phase == .ready }
        XCTAssertFalse(service.canSuggest)
        let document = Document(script: nil, text: "untrusted_source")
        let result = await service.completion(document: document, sourceID: document.id, source: document.text, caret: 16)
        XCTAssertNil(result)
        XCTAssertFalse(transport.notifications.contains { $0.0 == "textDocument/didOpen" })
        let initialization = try XCTUnwrap(transport.requests.first { $0.0 == "initialize" })
        XCTAssertNil(initialization.1["workspaceFolders"])
    }

    func testDocumentChangesUseVersionedIncrementalSynchronization() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        let document = Document(script: nil, text: "🐍 = 1\n")
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: document.text.utf16.count)
        document.text += "x = "
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: document.text.utf16.count)
        let change = try XCTUnwrap(transport.notifications.first { $0.0 == "textDocument/didChange" })
        XCTAssertEqual((change.1["textDocument"] as? [String: Any])?["version"] as? Int, 1)
        let content = try XCTUnwrap((change.1["contentChanges"] as? [[String: Any]])?.first)
        let end = (content["range"] as? [String: Any])?["end"] as? [String: Int]
        XCTAssertEqual(end, ["line": 1, "character": 0])
        XCTAssertEqual(content["text"] as? String, document.text)
    }

    func testSignOutStopsSuggestionsAndClearsRememberedAccount() async throws {
        let (service, transport, defaults) = try makeService()
        try await signIn(service)
        service.signOut()
        XCTAssertFalse(service.isEnabled)
        try await waitUntil { service.phase == .idle }
        XCTAssertNil(service.account)
        XCTAssertFalse(defaults.bool(forKey: CopilotService.consentKey))
        XCTAssertNil(defaults.string(forKey: CopilotService.accountKey))
        XCTAssertTrue(transport.requests.contains { $0.0 == "signOut" })
    }

    func testBrowserRequestsCannotOpenArbitraryURLs() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        for uri in ["file:///etc/passwd", "https://example.com/login", "https://github.com/login/device"] {
            let result = await transport.onRequest?("window/showDocument", ["uri": uri]) as? [String: Bool]
            XCTAssertEqual(result?["success"], false)
        }
    }

    func testSigningInOpensOnlyHTTPSGitHubURLs() async throws {
        var openedURLs: [URL] = []
        let (service, transport, _) = try makeService(openURL: { url in
            openedURLs.append(url)
            return true
        })
        transport.useDeviceFlow()
        service.beginSignIn()
        try await waitUntil { service.phase == .deviceCode }
        let beforeContinue = await transport.onRequest?("window/showDocument", ["uri": "https://github.com/login/device"]) as? [String: Bool]
        XCTAssertEqual(beforeContinue?["success"], false)
        XCTAssertTrue(openedURLs.isEmpty)
        service.continueSignIn()
        try await waitUntil { transport.pendingDeviceFlow != nil }
        XCTAssertEqual(service.phase, .signingIn)

        for uri in ["file:///etc/passwd", "http://github.com/login/device", "https://example.com/login",
                    "https://github.com.example.com/login/device", "https://github.com@evil.example/login/device",
                    "https://user@github.com/login/device", "https://user:password@github.com/login/device",
                    "https://github.com:444/login/device"] {
            let result = await transport.onRequest?("window/showDocument", ["uri": uri]) as? [String: Bool]
            XCTAssertEqual(result?["success"], false, uri)
        }
        XCTAssertTrue(openedURLs.isEmpty)
        let allowed = ["https://github.com/login/device", "https://github.com:443/login/device"]
        for uri in allowed {
            let result = await transport.onRequest?("window/showDocument", ["uri": uri]) as? [String: Bool]
            XCTAssertEqual(result?["success"], true, uri)
        }
        XCTAssertEqual(openedURLs.map(\.absoluteString), allowed)
        XCTAssertFalse(service.canSuggest)
        XCTAssertFalse(transport.notifications.contains { $0.0.hasPrefix("textDocument/") })
        service.cancelSignIn()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(transport.pendingDeviceFlow)
    }

    func testServerAccountNoticeIsDismissedWhenConnectionStops() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        let request = Task { await transport.onRequest?("window/showMessageRequest", ["message": "Copilot access notice", "actions": [["title": "Learn more"]]]) }
        try await waitUntil { service.notice != nil }
        XCTAssertTrue(service.showsPopover)
        service.setEnabled(false)
        let response = await request.value
        XCTAssertNil(response)
        XCTAssertNil(service.notice)
    }

    func testReconnectDoesNotSendCodeBeforeAccountAccessIsRechecked() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        transport.holdStatus = true
        service.reconnect()
        try await waitUntil { transport.pendingStatus != nil }
        XCTAssertFalse(service.canSuggest)
        let document = Document(script: nil, text: "private")
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: 7)
        XCTAssertFalse(transport.notifications.contains { $0.0 == "textDocument/didOpen" })
        transport.pendingStatus?.resume(returning: ["status": "OK", "user": "quanta-test"])
        transport.pendingStatus = nil
        try await waitUntil { service.phase == .ready }
        XCTAssertTrue(service.canSuggest)
    }

    func testCanonicallyEquivalentUnicodeStillUpdatesUTF16DocumentPositions() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        let document = Document(script: nil, text: "café")
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: 4)
        document.text = "cafe\u{301}"
        _ = await service.completion(document: document, sourceID: document.id, source: document.text, caret: 5)
        let updates = transport.notifications.filter { $0.0 == "textDocument/didChange" }
        XCTAssertEqual(updates.count, 1)
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual((last.1["position"] as? [String: Int])?["character"], 5)
    }

    func testLongAccountNoticeKeepsPopoverWithinTheWindow() async throws {
        let (service, transport, _) = try makeService()
        try await signIn(service)
        transport.onNotification?("didChangeStatus", ["kind": "Warning", "message": String(repeating: "Connection needs attention. ", count: 30)])
        let pending = Task { await transport.onRequest?("window/showMessageRequest", [
            "message": String(repeating: "Review your GitHub account access. ", count: 50),
            "actions": [["title": "Open GitHub"], ["title": "Later"]],
        ]) }
        try await waitUntil { service.notice != nil }
        let view = NSHostingView(rootView: CopilotPopover(copilot: service))
        view.frame = NSRect(x: 0, y: 0, width: DS.Layout.copilotPopoverWidth, height: DS.Layout.copilotPopoverMaxHeight)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThanOrEqual(view.fittingSize.height, DS.Layout.copilotPopoverMaxHeight + 1)
        XCTAssertEqual(view.fittingSize.width, DS.Layout.copilotPopoverWidth, accuracy: 1)
        service.shutdown()
        _ = await pending.value
    }
}

@MainActor
private final class StubCopilotTransport: CopilotTransport {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((String, [String: Any]) async -> Any?)?
    var onTermination: ((String) -> Void)?
    var requests: [(String, [String: Any])] = []
    var notifications: [(String, [String: Any])] = []
    var starts = 0
    var stops = 0
    var signInResult: Any = ["status": "AlreadySignedIn", "user": "quanta-test"]
    var inlineResult: Any = ["items": []]
    var holdCompletion = false
    var holdStatus = false
    var holdDeviceFlow = false
    var pendingCompletion: CheckedContinuation<Any, Error>?
    var pendingStatus: CheckedContinuation<Any, Error>?
    var pendingDeviceFlow: CheckedContinuation<Any, Error>?

    func useDeviceFlow() {
        signInResult = ["userCode": "QUANTA-TEST", "command": ["command": "github.copilot.finishDeviceFlow", "arguments": ["fixture-device-flow"]]]
        holdDeviceFlow = true
    }

    func start(executable: URL) throws { starts += 1 }
    func stop() {
        stops += 1
        pendingDeviceFlow?.resume(throwing: CancellationError())
        pendingDeviceFlow = nil
    }
    func notify(_ method: String, params: [String: Any]) { notifications.append((method, params)) }
    func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any {
        requests.append((method, params))
        switch method {
        case "signIn": return signInResult
        case "workspace/executeCommand":
            if holdDeviceFlow, params["command"] as? String == "github.copilot.finishDeviceFlow" {
                return try await withCheckedThrowingContinuation { pendingDeviceFlow = $0 }
            }
            return [:] as [String: Any]
        case "checkStatus":
            if holdStatus { return try await withCheckedThrowingContinuation { pendingStatus = $0 } }
            return ["status": "OK", "user": "quanta-test"]
        case "textDocument/inlineCompletion":
            if holdCompletion { return try await withCheckedThrowingContinuation { pendingCompletion = $0 } }
            return inlineResult
        default: return [:] as [String: Any]
        }
    }
}
