import AppKit
import Combine

struct CopilotNotice: Identifiable {
    let id = UUID()
    let message: String
    let actions: [[String: Any]]
}

@MainActor
final class CopilotService: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, deviceCode, signingIn, ready, attention
    }

    static let shared = CopilotService()
    static let enabledKey = "QuantaCopilotEnabled"
    static let consentKey = "QuantaCopilotConfigured"
    static let accountKey = "QuantaCopilotAccount"
    static let disabledProjectsKey = "QuantaCopilotDisabledProjects"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isEnabled: Bool
    @Published private(set) var account: String?
    @Published private(set) var deviceCode: String?
    @Published private(set) var message = ""
    @Published private(set) var revision = 0
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var workspaceTrusted = true
    @Published private(set) var isProjectDisabled = false
    @Published private(set) var notice: CopilotNotice?
    @Published var showsPopover = false

    private let defaults: UserDefaults
    private let makeTransport: @MainActor () -> CopilotTransport
    private let executable: @MainActor () async throws -> URL
    private let openURL: @MainActor (URL) -> Bool
    private let copyCode: @MainActor (String) -> Void
    private var transport: CopilotTransport?
    private var initialized = false
    private var authorized = false
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var deviceCommand: [String: Any]?
    private var openDocument: (uri: String, text: String, version: Int)?
    private var noticeReply: CheckedContinuation<Any?, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private weak var app: AppState?

    init(defaults: UserDefaults = QuantaDefaults.store,
         makeTransport: @escaping @MainActor () -> CopilotTransport = { CopilotProcessTransport() },
         executable: @escaping @MainActor () async throws -> URL = { try await CopilotInstaller().executable() },
         openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         copyCode: @escaping @MainActor (String) -> Void = { code in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(code, forType: .string)
         }) {
        self.defaults = defaults
        self.makeTransport = makeTransport
        self.executable = executable
        self.openURL = openURL
        self.copyCode = copyCode
        isEnabled = defaults.bool(forKey: Self.enabledKey) && defaults.bool(forKey: Self.consentKey)
        account = defaults.string(forKey: Self.accountKey)
    }

    var isBusy: Bool { phase == .preparing || phase == .signingIn }
    var hasAccount: Bool { account != nil || authorized }
    var canSuggest: Bool {
        isEnabled && authorized && initialized && workspaceTrusted && !isProjectDisabled && phase == .ready
    }
    var statusText: String {
        if phase == .preparing { return "Preparing GitHub Copilot…" }
        if phase == .deviceCode { return "Continue in your browser to sign in." }
        if phase == .signingIn { return "Waiting for GitHub sign-in…" }
        if phase == .attention { return message.isEmpty ? "Copilot needs attention." : message }
        if !workspaceTrusted { return "Suggestions are paused in this untrusted workspace." }
        if isProjectDisabled { return "Suggestions are off for this project." }
        if !isEnabled { return hasAccount ? "Code suggestions are off." : "Sign in to get code suggestions." }
        if !initialized { return "Copilot is disconnected. Use Retry to reconnect." }
        return message.isEmpty ? "Code suggestions are on. Tab accepts · Esc dismisses." : message
    }

    func bind(to app: AppState) {
        guard self.app !== app else { return }
        subscriptions.removeAll()
        self.app = app
        updateWorkspace(app.workspace?.rootURL, trusted: app.isWorkspaceTrusted)
        app.$workspace.dropFirst().sink { [weak self] workspace in
            self?.updateWorkspace(workspace?.rootURL,
                                  trusted: workspace.map { WorkspaceTrust.contains($0.rootURL) } ?? true)
        }.store(in: &subscriptions)
        app.$activeDocumentID.dropFirst().sink { [weak self] _ in
            self?.invalidateSuggestions()
        }.store(in: &subscriptions)
        app.selection.$selectedCellID.dropFirst().sink { [weak self] _ in
            self?.invalidateSuggestions()
        }.store(in: &subscriptions)
        app.$openDocuments.dropFirst().sink { [weak self] _ in
            self?.invalidateSuggestions()
        }.store(in: &subscriptions)
        if operation == nil, isEnabled, workspaceTrusted, !isProjectDisabled { reconnect() }
    }

    func updateWorkspace(_ url: URL?, trusted: Bool) {
        let disabled = url.map { (defaults.stringArray(forKey: Self.disabledProjectsKey) ?? []).contains(WorkspaceTrust.path($0)) } ?? false
        guard workspaceURL != url || workspaceTrusted != trusted || isProjectDisabled != disabled else { return }
        workspaceURL = url
        workspaceTrusted = trusted
        isProjectDisabled = disabled
        cancelOperation()
        stopSession()
        phase = .idle
        if isEnabled, trusted, !disabled { reconnect() }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        cancelOperation()
        stopSession()
        phase = .idle
        message = ""
        if enabled {
            if defaults.bool(forKey: Self.consentKey), hasAccount { reconnect() }
            else { beginSignIn() }
        }
    }

    func setProjectDisabled(_ disabled: Bool) {
        guard let workspaceURL else { return }
        var paths = Set(defaults.stringArray(forKey: Self.disabledProjectsKey) ?? [])
        let path = WorkspaceTrust.path(workspaceURL)
        if disabled { paths.insert(path) } else { paths.remove(path) }
        defaults.set(paths.sorted(), forKey: Self.disabledProjectsKey)
        updateWorkspace(workspaceURL, trusted: workspaceTrusted)
    }

    func beginSignIn() {
        cancelOperation()
        stopSession()
        defaults.set(true, forKey: Self.consentKey)
        phase = .preparing
        message = ""
        let id = operationID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await startSession()
                try checkOperation(id)
                let result = try await transport?.request("signIn", params: [:], timeout: 30) as? [String: Any]
                try checkOperation(id)
                guard let result else { throw CopilotServiceError.invalidResponse }
                if let code = result["userCode"] as? String,
                   let command = result["command"] as? [String: Any],
                   command["command"] as? String == "github.copilot.finishDeviceFlow" {
                    deviceCode = String(code.prefix(64))
                    deviceCommand = command
                    phase = .deviceCode
                } else {
                    try await finishAuthentication(id: id)
                }
            } catch {
                handle(error, operation: id)
            }
        }
    }

    func continueSignIn() {
        guard phase == .deviceCode, let code = deviceCode, let command = deviceCommand else { return }
        copyCode(code)
        phase = .signingIn
        let id = operationID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await transport?.request("workspace/executeCommand", params: command, timeout: 180)
                try checkOperation(id)
                try await finishAuthentication(id: id)
            } catch {
                handle(error, operation: id)
            }
        }
    }

    func cancelSignIn() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        cancelOperation()
        stopSession()
        phase = .idle
        message = ""
    }

    func reconnect() {
        guard defaults.bool(forKey: Self.consentKey), isEnabled, workspaceTrusted, !isProjectDisabled else { return }
        cancelOperation()
        stopSession()
        phase = .preparing
        message = ""
        let id = operationID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await startSession()
                try checkOperation(id)
                try await refreshAccount()
                try checkOperation(id)
                phase = authorized ? .ready : .attention
                if !authorized, message.isEmpty { message = "Sign in with a GitHub account that has Copilot access." }
            } catch {
                handle(error, operation: id)
            }
        }
    }

    func signOut() {
        cancelOperation()
        stopSession()
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        phase = .preparing
        let id = operationID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if !initialized { try await startSession() }
                try checkOperation(id)
                _ = try await transport?.request("signOut", params: [:], timeout: 20)
                try checkOperation(id)
                account = nil
                authorized = false
                defaults.removeObject(forKey: Self.accountKey)
                defaults.set(false, forKey: Self.consentKey)
                stopSession()
                phase = .idle
                message = ""
            } catch {
                handle(error, operation: id)
            }
        }
    }

    func shutdown() {
        cancelOperation()
        stopSession()
    }

    func completion(document: Document, sourceID: UUID, source: String, caret: Int) async -> CopilotSuggestion? {
        guard canSuggest, app?.isWorkspaceTrusted != false,
              app == nil || app?.openDocuments.contains(where: { $0 === document }) == true,
              let snapshot = CopilotDocumentSnapshot(document: document, sourceID: sourceID, source: source, caret: caret),
              let transport else { return nil }
        let revision = self.revision
        let version = synchronize(snapshot)
        do {
            let result = try await transport.request("textDocument/inlineCompletion", params: [
                "textDocument": ["uri": snapshot.uri, "version": version],
                "position": snapshot.position.dictionary,
                "context": ["triggerKind": 2],
                "formattingOptions": ["tabSize": 4, "insertSpaces": true],
            ], timeout: 20)
            guard !Task.isCancelled, revision == self.revision, canSuggest,
                  app?.isWorkspaceTrusted != false,
                  let currentSnapshot = CopilotDocumentSnapshot(document: document, sourceID: sourceID, source: source, caret: caret),
                  currentSnapshot.uri == snapshot.uri, currentSnapshot.languageID == snapshot.languageID,
                  currentSnapshot.text.utf16.elementsEqual(snapshot.text.utf16),
                  let items = (result as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
            return items.prefix(8).compactMap { snapshot.suggestion(from: $0, revision: revision) }.first
        } catch {
            if !Task.isCancelled, revision == self.revision, canSuggest, !(error is CancellationError) {
                message = "Could not get a suggestion. \(String(error.localizedDescription.prefix(300)))"
            }
            return nil
        }
    }

    func didShow(_ suggestion: CopilotSuggestion) {
        guard canSuggest, suggestion.revision == revision, openDocument?.uri == suggestion.uri else { return }
        transport?.notify("textDocument/didShowCompletion", params: ["item": suggestion.item])
    }

    func accept(_ suggestion: CopilotSuggestion) {
        guard canSuggest, suggestion.revision == revision, let transport,
              let command = suggestion.item["command"] as? [String: Any],
              command["command"] as? String == "github.copilot.didAcceptCompletionItem" else { return }
        Task { _ = try? await transport.request("workspace/executeCommand", params: command, timeout: 10) }
    }

    func respondToNotice(_ id: UUID, action: Int?) {
        guard let notice, notice.id == id else { return }
        let result = action.flatMap { notice.actions.indices.contains($0) ? notice.actions[$0] : nil }
        let reply = noticeReply
        noticeReply = nil
        self.notice = nil
        reply?.resume(returning: result)
    }

    private func startSession() async throws {
        let url = try await executable()
        try Task.checkCancellation()
        let transport = makeTransport()
        self.transport = transport
        transport.onNotification = { [weak self] method, params in self?.receive(method, params: params) }
        transport.onRequest = { [weak self] method, params in await self?.respond(method, params: params) }
        transport.onTermination = { [weak self] detail in
            guard let self else { return }
            initialized = false
            authorized = false
            openDocument = nil
            revision &+= 1
            phase = .attention
            message = "Copilot stopped. \(String(detail.prefix(300))) Use Retry to reconnect."
            if let notice { respondToNotice(notice.id, action: nil) }
        }
        try transport.start(executable: url)
        var parameters: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "capabilities": [
                "workspace": ["configuration": true, "workspaceFolders": true],
                "window": ["showDocument": ["support": true]],
                "general": ["positionEncodings": ["utf-16"]],
            ],
            "initializationOptions": [
                "editorInfo": ["name": "Quanta", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
                "editorPluginInfo": ["name": "Quanta Copilot", "version": "1.0.0"],
            ],
        ]
        if let workspaceURL, workspaceTrusted, !isProjectDisabled {
            parameters["workspaceFolders"] = [["uri": workspaceURL.absoluteString, "name": workspaceURL.lastPathComponent]]
        }
        _ = try await transport.request("initialize", params: parameters, timeout: 30)
        try Task.checkCancellation()
        transport.notify("initialized", params: [:])
        transport.notify("workspace/didChangeConfiguration", params: ["settings": ["telemetry": ["telemetryLevel": "off"]]])
        initialized = true
    }

    private func finishAuthentication(id: UUID) async throws {
        try await refreshAccount()
        try checkOperation(id)
        deviceCode = nil
        deviceCommand = nil
        if authorized {
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            phase = .ready
            message = ""
            revision &+= 1
            if !workspaceTrusted || isProjectDisabled { stopSession() }
        } else {
            phase = .attention
            if message.isEmpty { message = "This GitHub account needs Copilot access before it can suggest code." }
        }
    }

    private func refreshAccount() async throws {
        let result = try await transport?.request("checkStatus", params: [:], timeout: 30) as? [String: Any]
        try Task.checkCancellation()
        guard let result, let status = result["status"] as? String else { throw CopilotServiceError.invalidResponse }
        authorized = status == "OK" || status == "MaybeOK" || status == "AlreadySignedIn"
        if let user = result["user"] as? String, !user.isEmpty {
            account = String(user.prefix(100))
            defaults.set(account, forKey: Self.accountKey)
        } else if status == "NotSignedIn" {
            account = nil
            defaults.removeObject(forKey: Self.accountKey)
        }
        if !authorized {
            message = status == "NotSignedIn" ? "Sign in with GitHub to enable suggestions." : "Your GitHub account does not currently have access to Copilot."
        }
    }

    private func synchronize(_ snapshot: CopilotDocumentSnapshot) -> Int {
        if let current = openDocument, current.uri == snapshot.uri {
            guard !current.text.utf16.elementsEqual(snapshot.text.utf16) else { return current.version }
            let version = current.version &+ 1
            let end = CopilotTextPosition(offset: current.text.utf16.count, in: current.text) ?? CopilotTextPosition(line: 0, character: 0)
            transport?.notify("textDocument/didChange", params: [
                "textDocument": ["uri": snapshot.uri, "version": version],
                "contentChanges": [["range": ["start": ["line": 0, "character": 0], "end": end.dictionary], "text": snapshot.text]],
            ])
            openDocument = (snapshot.uri, snapshot.text, version)
            return version
        }
        closeDocument()
        transport?.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": snapshot.uri, "languageId": snapshot.languageID, "version": 0, "text": snapshot.text],
        ])
        transport?.notify("textDocument/didFocus", params: ["textDocument": ["uri": snapshot.uri]])
        openDocument = (snapshot.uri, snapshot.text, 0)
        return 0
    }

    private func invalidateSuggestions() {
        revision &+= 1
        closeDocument()
    }

    private func closeDocument() {
        if let current = openDocument {
            transport?.notify("textDocument/didClose", params: ["textDocument": ["uri": current.uri]])
            transport?.notify("textDocument/didFocus", params: [:])
        }
        openDocument = nil
    }

    private func stopSession() {
        invalidateSuggestions()
        transport?.onTermination = nil
        transport?.onNotification = nil
        transport?.onRequest = nil
        transport?.stop()
        transport = nil
        initialized = false
        authorized = false
        deviceCode = nil
        deviceCommand = nil
        if let notice { respondToNotice(notice.id, action: nil) }
    }

    private func cancelOperation() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
    }

    private func checkOperation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == operationID else { throw CancellationError() }
    }

    private func handle(_ error: Error, operation id: UUID) {
        guard id == operationID, !(error is CancellationError), !Task.isCancelled else { return }
        stopSession()
        phase = .attention
        message = String(error.localizedDescription.prefix(600))
    }

    private func receive(_ method: String, params: [String: Any]) {
        if method == "didChangeStatus", !isBusy, phase != .deviceCode {
            let kind = params["kind"] as? String
            if let detail = params["message"] as? String { message = String(detail.prefix(600)) }
            if kind == "Error" || kind == "Warning" { phase = .attention }
            else if authorized { phase = .ready }
        } else if method == "window/showMessage", let detail = params["message"] as? String {
            message = String(detail.prefix(600))
        }
    }

    private func respond(_ method: String, params: [String: Any]) async -> Any? {
        if method == "workspace/configuration" {
            return (params["items"] as? [[String: Any]] ?? []).prefix(100).map { item -> Any in
                if item["section"] as? String == "telemetry" { return ["telemetryLevel": "off"] }
                return NSNull()
            }
        }
        if method == "window/showDocument" {
            guard phase == .signingIn,
                  let value = params["uri"] as? String, let url = URL(string: value),
                  url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443 else { return ["success": false] }
            return ["success": openURL(url)]
        }
        if method == "window/showMessageRequest", let detail = params["message"] as? String {
            if let notice { respondToNotice(notice.id, action: nil) }
            let next = CopilotNotice(message: String(detail.prefix(1_200)),
                                     actions: Array((params["actions"] as? [[String: Any]] ?? []).prefix(4)))
            return await withCheckedContinuation { reply in
                noticeReply = reply
                notice = next
                showsPopover = true
            }
        }
        return nil
    }
}

private enum CopilotServiceError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "Copilot returned an unexpected response. Retry the connection." }
}
