import Foundation

struct LanguageMessageFramer {
    private var buffer = Data()
    private var length: Int?
    static let limit = 16 * 1024 * 1024

    mutating func consume(_ bytes: Data) throws -> [[String: Any]] {
        buffer.append(bytes)
        var messages: [[String: Any]] = []
        while true {
            if length == nil {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 8192 { throw QuantaError("Invalid language-server header") }
                    break
                }
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lengths = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let pair = line.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
                    return Int(pair[1].trimmingCharacters(in: .whitespaces))
                }
                guard lengths.count == 1, let size = lengths.first, size > 0, size <= Self.limit else {
                    throw QuantaError("Invalid language-server message size")
                }
                length = size
                buffer.removeSubrange(..<end.upperBound)
            }
            guard let size = length, buffer.count >= size else { break }
            let payload = Data(buffer.prefix(size))
            buffer.removeFirst(size)
            length = nil
            guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw QuantaError("Invalid language-server response")
            }
            messages.append(message)
        }
        return messages
    }

    static func encode(_ message: [String: Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: message)
        guard bytes.count <= limit else { throw QuantaError("Document exceeds the language-server message limit") }
        return Data("Content-Length: \(bytes.count)\r\n\r\n".utf8) + bytes
    }
}

final class LanguageServer {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((String, [String: Any]) -> Any)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var pending: [Int: (Any?) -> Void] = [:]
    private var nextID = 0
    private var generation = 0
    private let writeQueue = DispatchQueue(label: "quanta.language.write")

    func start(executable: URL, root: URL, environment: [String: String]) throws {
        stop()
        let generation = self.generation
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stdio"]
        process.currentDirectoryURL = root
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let parser = LanguageParser()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            parser.queue.async {
                do {
                    let messages = try parser.framer.consume(bytes)
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        messages.forEach(self.receive)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.fail("Language server exited (\(process.terminationStatus)). Check its installation, then restart analysis.")
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
    }

    func stop() {
        generation += 1
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        output = nil
        errors = nil
        let replies = pending.values
        pending.removeAll()
        replies.forEach { $0(nil) }
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any], reply: @escaping (Any?) -> Void) -> Int {
        nextID += 1
        let id = nextID
        guard input != nil else { reply(nil); return id }
        pending[id] = reply
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.cancel(id) }
        return id
    }

    func cancel(_ id: Int) {
        guard let reply = pending.removeValue(forKey: id) else { return }
        notify("$/cancelRequest", ["id": id])
        reply(nil)
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func receive(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                let result = onRequest?(method, params) ?? NSNull()
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } else { onNotification?(method, params) }
        } else if let id = message["id"] as? Int, let reply = pending.removeValue(forKey: id) {
            reply(message["error"] == nil ? message["result"] : nil)
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input else { return }
        let generation = self.generation
        do {
            let bytes = try LanguageMessageFramer.encode(message)
            writeQueue.async { [weak self] in
                do { try input.write(contentsOf: bytes) }
                catch {
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.fail("Could not communicate with the language server.")
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    private final class LanguageParser {
        let queue = DispatchQueue(label: "quanta.language.parse")
        var framer = LanguageMessageFramer()
    }
}
