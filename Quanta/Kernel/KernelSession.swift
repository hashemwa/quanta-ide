import Foundation

enum KernelStatus: Equatable {
    case stopped
    case starting
    case idle
    case busy
    case dead

    var label: String {
        switch self {
        case .stopped: return "Kernel off"
        case .starting: return "Starting…"
        case .idle: return "Idle"
        case .busy: return "Busy"
        case .dead: return "Crashed"
        }
    }
}

final class KernelSession {
    private(set) var status: KernelStatus = .stopped {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }

    var onStatusChange: ((KernelStatus) -> Void)?
    var onOrphanMessage: (([String: Any]) -> Void)?
    private(set) var readyInfo: [String: Any]?
    private(set) var executable: String?
    private(set) var workingDirectory: URL?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "quanta.kernel.write", qos: .userInitiated)
    private var pending: [String: ([String: Any]) -> Bool] = [:]
    private var executing: [String] = []
    private var generation = 0

    var isRunning: Bool {
        switch status {
        case .starting, .idle, .busy: return true
        default: return false
        }
    }

    func start(python: String, scriptURL: URL, workingDirectory: URL?) {
        stop()
        generation += 1
        let gen = generation
        status = .starting
        readyInfo = nil
        executable = python
        self.workingDirectory = workingDirectory

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["MPLBACKEND"] = "Agg"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        if let cwd = workingDirectory {
            proc.currentDirectoryURL = cwd
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let parseQueue = DispatchQueue(label: "quanta.kernel.parse", qos: .userInitiated)
        let framer = LineFramer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            parseQueue.async {
                let parsed = framer.consume(data)
                guard !parsed.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    for item in parsed { self.dispatch(item) }
                }
            }
        }
        let stderrRemainder = ByteRemainder()
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = stderrRemainder.decode(appending: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.routeStray(text, stream: "stderr")
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.handleTermination(code: code)
            }
        }

        do {
            try proc.run()
            process = proc
            stdinHandle = stdinPipe.fileHandleForWriting
        } catch {
            status = .dead
            onOrphanMessage?(["type": "fatal",
                              "error": "Failed to launch \(python): \(error.localizedDescription)"])
        }
    }

    func stop() {
        generation += 1
        if let proc = process, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
        }
        process = nil
        stdinHandle = nil
        executing.removeAll()
        status = .stopped
        failAllPending()
    }

    func interrupt() {
        process?.interrupt()
    }

    @discardableResult
    func request(_ payload: [String: Any], onMessage: @escaping ([String: Any]) -> Bool) -> String? {
        func fail() -> String? {
            _ = onMessage(["type": "dead"])
            return nil
        }
        guard let stdinHandle else { return fail() }
        let id = UUID().uuidString
        var payload = payload
        payload["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return fail() }
        data.append(0x0A)
        pending[id] = onMessage
        if payload["op"] as? String == "execute" {
            executing.append(id)
            if status == .idle { status = .busy }
        }
        let gen = generation
        writeQueue.async { [weak self] in
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen,
                          let handler = self.pending.removeValue(forKey: id) else { return }
                    self.executing.removeAll { $0 == id }
                    _ = handler(["type": "dead"])
                }
            }
        }
        return id
    }

    func notify(_ payload: [String: Any]) {
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        writeQueue.async { try? stdinHandle.write(contentsOf: data) }
    }

    func execute(code: String, filename: String? = nil,
                 onMessage: @escaping ([String: Any]) -> Bool) {
        var payload: [String: Any] = ["op": "execute", "code": code]
        if let filename { payload["filename"] = filename }
        request(payload, onMessage: onMessage)
    }

    final class LineFramer {
        enum Item {
            case message([String: Any])
            case stray(String)
        }
        private var buffer = Data()
        private var scannedBytes = 0

        func consume(_ data: Data) -> [Item] {
            buffer.append(data)
            var items: [Item] = []
            while true {
                let searchStart = buffer.startIndex + scannedBytes
                guard searchStart < buffer.endIndex,
                      let newlineIndex = buffer[searchStart...].firstIndex(of: 0x0A) else {
                    scannedBytes = buffer.count
                    return items
                }
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                scannedBytes = 0
                guard !lineData.isEmpty else { continue }
                if lineData.first == UInt8(ascii: "{"),
                   let obj = try? JSONSerialization.jsonObject(with: lineData),
                   let msg = obj as? [String: Any], msg["type"] != nil {
                    items.append(.message(msg))
                } else if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    items.append(.stray(line))
                }
            }
        }
    }

    private func dispatch(_ item: LineFramer.Item) {
        switch item {
        case .message(let msg): processMessage(msg)
        case .stray(let line): routeStray(line + "\n", stream: "stdout")
        }
    }

    private func processMessage(_ msg: [String: Any]) {
        if let type = msg["type"] as? String, type == "ready" || type == "done" {
            if let cwd = msg["cwd"] as? String {
                workingDirectory = URL(fileURLWithPath: cwd)
            } else if msg["cwd"] is NSNull {
                workingDirectory = nil
            }
        }
        if msg["type"] as? String == "ready" {
            readyInfo = msg
            onOrphanMessage?(msg)
            status = executing.isEmpty ? .idle : .busy
            return
        }
        guard let id = msg["id"] as? String, let handler = pending[id] else {
            onOrphanMessage?(msg)
            return
        }
        if handler(msg) {
            pending.removeValue(forKey: id)
            if executing.contains(id) {
                executing.removeAll { $0 == id }
                if executing.isEmpty, status == .busy { status = .idle }
            }
        }
    }

    private func routeStray(_ text: String, stream: String) {
        let msg: [String: Any] = ["type": "stream", "name": stream, "text": text]
        if let id = executing.first, let handler = pending[id] {
            _ = handler(msg)
        } else {
            onOrphanMessage?(msg)
        }
    }

    private func failAllPending() {
        let handlers = pending
        pending.removeAll()
        for (_, handler) in handlers {
            _ = handler(["type": "dead"])
        }
    }

    final class ByteRemainder {
        private var pending = Data()

        func decode(appending chunk: Data) -> String? {
            pending.append(chunk)
            for trailing in 0...min(3, pending.count) {
                let usable = pending.prefix(pending.count - trailing)
                if let text = String(data: usable, encoding: .utf8) {
                    pending = Data(pending.suffix(trailing))
                    return text.isEmpty ? nil : text
                }
            }
            pending.removeAll()
            return String(decoding: chunk, as: UTF8.self)
        }
    }

    private func handleTermination(code: Int32) {
        process = nil
        stdinHandle = nil
        executing.removeAll()
        status = .dead
        failAllPending()
        onOrphanMessage?(["type": "fatal", "error": "Kernel process exited (code \(code))."])
    }
}
