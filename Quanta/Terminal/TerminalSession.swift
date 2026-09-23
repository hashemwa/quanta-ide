import AppKit
import Combine
import WebKit

@_silgen_name("quanta_spawn_pty")
private func spawnPTY(_ master: UnsafeMutablePointer<Int32>, _ shell: UnsafePointer<CChar>,
                      _ directory: UnsafePointer<CChar>, _ environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("quanta_resize_pty")
private func resizePTY(_ master: Int32, _ rows: UInt16, _ columns: UInt16)

enum BottomPane: String, CaseIterable {
    case console = "Console"
    case terminal = "Terminal"
    case plots = "Plots"
}

final class TerminalSession: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var directory: URL?
    @Published private(set) var error: String?
    @Published private(set) var exitStatus: Int32?
    private var master: FileHandle?
    private var pid: Int32 = 0
    private var restartDirectory: URL?
    private var generation = 0
    private var pending = Data()
    private var flushScheduled = false
    @Published private(set) var isReady = false
    private let inputQueue = DispatchQueue(label: "quanta.terminal.input")
    private var browser: WKWebView?
    private var bridge: TerminalBridge?
    var onOutput: ((Data) -> Void)?

    func start(in directory: URL, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        guard !running else { return }
        self.directory = directory
        error = nil
        exitStatus = nil
        generation += 1
        let generation = generation
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Quanta"
        environment["PWD"] = directory.path
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "UTF-8"
        var env = environment.map { strdup("\($0.key)=\($0.value)") }
        env.append(nil)
        defer { for pointer in env { free(pointer) } }
        var fd: Int32 = -1
        let child = shell.withCString { executable in
            directory.path.withCString { path in spawnPTY(&fd, executable, path, &env) }
        }
        guard child > 0 else { error = String(cString: strerror(errno)); return }
        pid = child
        running = true
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        master = handle
        if isReady { browser?.evaluateJavaScript("fit.fit(); send({type: 'resize', cols: term.cols, rows: term.rows})") }
        handle.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                if !bytes.isEmpty { self.receive(bytes) }
            }
            if bytes.isEmpty { handle.readabilityHandler = nil }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            let result = status
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.running = false
                self.pid = 0
                self.exitStatus = result & 0x7f == 0 ? (result >> 8) & 0xff : 128 + (result & 0x7f)
                self.master?.readabilityHandler = nil
                self.master = nil
                if let next = self.restartDirectory {
                    self.restartDirectory = nil
                    self.start(in: next)
                }
            }
        }
    }

    func send(_ text: String) {
        guard running, let master, let data = text.data(using: .utf8) else { return }
        inputQueue.async { try? master.write(contentsOf: data) }
    }

    func resize(columns: Int, rows: Int) {
        guard let master else { return }
        resizePTY(master.fileDescriptor, UInt16(clamping: max(1, rows)), UInt16(clamping: max(1, columns)))
    }

    func restart(in directory: URL) {
        guard running else { start(in: directory); return }
        restartDirectory = directory
        stop()
    }

    func stop() {
        guard pid > 0 else { return }
        if let master {
            let foreground = tcgetpgrp(master.fileDescriptor)
            if foreground > 0 { kill(-foreground, SIGHUP) }
        }
        kill(-pid, SIGHUP)
        master?.readabilityHandler = nil
        master = nil
    }

    func clear() { browser?.evaluateJavaScript("term.clear()") }
    func focus() { browser?.evaluateJavaScript("term.focus()") }

    private func receive(_ data: Data) {
        onOutput?(data)
        pending.append(data)
        if pending.count > 2_000_000 { pending = Data(pending.suffix(2_000_000)) }
        guard isReady, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard isReady, !pending.isEmpty else { return }
        let encoded = pending.base64EncodedString()
        pending.removeAll(keepingCapacity: true)
        browser?.evaluateJavaScript("term.write(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0)))")
    }

    func webView() -> WKWebView {
        if let browser { return browser }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let bridge = TerminalBridge(session: self)
        config.userContentController.add(bridge, name: "terminal")
        self.bridge = bridge
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = bridge
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        browser = view
        guard let resource = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Terminal")
            ?? Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Resources/Terminal")
            ?? Bundle.main.url(forResource: "terminal", withExtension: "html") else {
            error = "Terminal resources are missing. Rebuild Quanta."
            return view
        }
        view.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        return view
    }

    func appearance(_ colors: [String: String], size: CGFloat) {
        guard isReady, let data = try? JSONSerialization.data(withJSONObject: colors, options: [.sortedKeys]),
              let theme = String(data: data, encoding: .utf8) else { return }
        browser?.evaluateJavaScript("configureTerminal(\(theme), \(size))")
    }

    fileprivate func message(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isReady = true
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            appearance(DS.Chrome.terminalTheme(AppTheme.current, dark: dark),
                       size: AppState.shared.editorFontSize - 1)
            flush()
        case "input": if let text = body["data"] as? String { send(text) }
        case "resize": resize(columns: body["cols"] as? Int ?? 80, rows: body["rows"] as? Int ?? 24)
        default: break
        }
    }
}

private final class TerminalBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var session: TerminalSession?
    init(session: TerminalSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any] else { return }
        session?.message(body)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
