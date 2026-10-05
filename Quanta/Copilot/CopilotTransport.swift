import Darwin
import CoreFoundation
import Foundation

@MainActor
protocol CopilotTransport: AnyObject {
    var onNotification: ((String, [String: Any]) -> Void)? { get set }
    var onRequest: ((String, [String: Any]) async -> Any?)? { get set }
    var onTermination: ((String) -> Void)? { get set }
    func start(executable: URL) throws
    func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any
    func notify(_ method: String, params: [String: Any])
    func stop()
}

enum CopilotTransportError: LocalizedError {
    case unavailable, stopped, timedOut, overloaded
    case failed(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The Copilot helper is not running. Connect to Copilot and try again."
        case .stopped: return "The Copilot connection closed. Reconnect and try again."
        case .timedOut: return "Copilot took too long to respond. Try again."
        case .overloaded: return "Copilot has too many pending requests. Try again in a moment."
        case .failed(let message): return message
        case .server(_, let message): return String(message.prefix(4096))
        }
    }
}

struct CopilotMessageFramer {
    static let maximumMessageBytes = 8 * 1024 * 1024
    static let maximumHeaderBytes = 8192
    private var buffer = Data()
    private var contentLength: Int?

    var hasPartialMessage: Bool { !buffer.isEmpty || contentLength != nil }

    mutating func consume(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while true {
            if contentLength == nil {
                guard let separator = buffer.range(of: Data([13, 10, 13, 10])) else {
                    guard buffer.count <= Self.maximumHeaderBytes else { throw malformed() }
                    break
                }
                let header = buffer[..<separator.lowerBound]
                guard header.count <= Self.maximumHeaderBytes,
                      let text = String(data: header, encoding: .ascii) else { throw malformed() }
                var length: Int?
                for line in text.components(separatedBy: "\r\n") {
                    let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard fields.count == 2 else { throw malformed() }
                    if fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        let value = fields[1].trimmingCharacters(in: .whitespaces)
                        guard length == nil, !value.isEmpty, value.allSatisfy(\.isNumber),
                              let parsed = Int(value), parsed > 0,
                              parsed <= Self.maximumMessageBytes else { throw malformed() }
                        length = parsed
                    }
                }
                guard let length else { throw malformed() }
                buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
                contentLength = length
            }
            guard let length = contentLength, buffer.count >= length else { break }
            messages.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length)
            contentLength = nil
        }
        return messages
    }

    static func encode(_ message: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw CopilotTransportError.failed("Couldn’t encode a Copilot request.")
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= maximumMessageBytes else {
            throw CopilotTransportError.failed("The document is too large to send to Copilot.")
        }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }

    private func malformed() -> CopilotTransportError {
        .failed("The Copilot helper returned an invalid or oversized message. Reconnect and try again.")
    }
}

@MainActor
final class CopilotProcessTransport: CopilotTransport {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((String, [String: Any]) async -> Any?)?
    var onTermination: ((String) -> Void)?

    private struct Pending {
        let continuation: CheckedContinuation<Any, Error>
        let timeout: Task<Void, Never>
    }

    private var session: CopilotProcessConnection?
    private var generation = UUID()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var serverRequests: [String: Task<Void, Never>] = [:]
    private let configurationDirectory: URL
    private let helperEnvironment: [String: String]

    init(configurationDirectory: URL? = nil, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let configuration = configurationDirectory ?? support.appendingPathComponent("Quanta/Copilot/config", isDirectory: true)
        self.configurationDirectory = configuration
        helperEnvironment = Self.environment(inherited: inheritedEnvironment, configurationDirectory: configuration)
    }

    deinit { session?.stop() }

    nonisolated static func environment(inherited: [String: String], configurationDirectory: URL) -> [String: String] {
        var result = inherited.filter { key, _ in
            let upper = key.uppercased()
            return !upper.hasPrefix("GITHUB_") && !upper.hasPrefix("GH_") && !upper.hasPrefix("COPILOT_")
                && !["NODE_OPTIONS", "NODE_PATH", "NODE_TLS_REJECT_UNAUTHORIZED", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"].contains(upper)
        }
        result["XDG_CONFIG_HOME"] = configurationDirectory.path
        return result
    }

    func start(executable: URL) throws {
        stop()
        let identifier = UUID()
        generation = identifier
        let connection = CopilotProcessConnection(directory: configurationDirectory, environment: helperEnvironment, message: { [weak self] message in
            self?.receive(message, generation: identifier)
        }, ended: { [weak self] message in
            self?.terminated(message, generation: identifier)
        })
        do {
            try connection.start(executable: executable)
            session = connection
        } catch {
            connection.stop()
            throw CopilotTransportError.failed("Couldn’t start the Copilot helper: \(error.localizedDescription)")
        }
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> Any {
        try Task.checkCancellation()
        guard let session else { throw CopilotTransportError.unavailable }
        guard pending.count < 128 else { throw CopilotTransportError.overloaded }
        nextID += 1
        let id = nextID
        let identifier = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self] in
                    let seconds = timeout.isFinite ? max(0.01, min(timeout, 3600)) : 30
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    self?.cancel(id, generation: identifier, error: CopilotTransportError.timedOut)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                session.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id, generation: identifier, error: CancellationError())
            }
        }
    }

    func notify(_ method: String, params: [String: Any]) {
        session?.send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func stop() {
        generation = UUID()
        let connection = session
        session = nil
        completePending(with: CancellationError())
        connection?.stop()
    }

    private func cancel(_ id: Int, generation: UUID, error: Error) {
        guard self.generation == generation, let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        notify("$/cancelRequest", params: ["id": id])
        request.continuation.resume(throwing: error)
    }

    private func receive(_ message: [String: Any], generation: UUID) {
        guard self.generation == generation, session != nil else { return }
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"], let key = requestKey(id) {
                guard serverRequests.count < 32, serverRequests[key] == nil else {
                    respond(id, error: ["code": -32603, "message": "Too many pending client requests."])
                    return
                }
                guard let onRequest else {
                    respond(id, error: ["code": -32601, "message": "Method not supported."])
                    return
                }
                serverRequests[key] = Task { @MainActor [weak self] in
                    let result = await onRequest(method, params)
                    guard let self, self.generation == generation, self.session != nil else { return }
                    self.serverRequests.removeValue(forKey: key)
                    if Task.isCancelled { self.respond(id, error: ["code": -32800, "message": "Request canceled."]) }
                    else { self.session?.send(["jsonrpc": "2.0", "id": id, "result": result ?? NSNull()]) }
                }
            } else {
                if method == "$/cancelRequest", let id = params["id"], let key = requestKey(id) {
                    serverRequests[key]?.cancel()
                }
                onNotification?(method, params)
            }
            return
        }
        guard let id = numericID(message["id"]), let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if let error = message["error"] as? [String: Any] {
            request.continuation.resume(throwing: CopilotTransportError.server(
                error["code"] as? Int ?? -32603, error["message"] as? String ?? "Copilot could not complete the request."))
        } else if let result = message["result"] {
            request.continuation.resume(returning: result)
        } else {
            request.continuation.resume(throwing: CopilotTransportError.failed("Copilot returned an incomplete response."))
        }
    }

    private func requestKey(_ id: Any) -> String? {
        if let string = id as? String { return "s:" + string }
        if let number = numericID(id) { return "n:\(number)" }
        return nil
    }

    private func numericID(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    private func respond(_ id: Any, error: [String: Any]) {
        session?.send(["jsonrpc": "2.0", "id": id, "error": error])
    }

    private func terminated(_ message: String, generation: UUID) {
        guard self.generation == generation, session != nil else { return }
        session = nil
        self.generation = UUID()
        completePending(with: CopilotTransportError.failed(message))
        onTermination?(message)
    }

    private func completePending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        serverRequests.values.forEach { $0.cancel() }
        serverRequests.removeAll()
    }
}

private final class CopilotProcessConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let deliverySlots = DispatchSemaphore(value: 64)
    private let encodingQueue = DispatchQueue(label: "quanta.copilot.encode", qos: .userInitiated)
    private let message: @MainActor ([String: Any]) -> Void
    private let ended: @MainActor (String) -> Void
    private let directory: URL
    private let environment: [String: String]
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe(), wake = Pipe()
    private var outgoing: [Data] = []
    private var bufferedBytes = 0
    private var queuedEncodings = 0
    private var stopped = false
    private var closed = false
    private var failure: String?

    init(directory: URL, environment: [String: String], message: @escaping @MainActor ([String: Any]) -> Void,
         ended: @escaping @MainActor (String) -> Void) {
        self.directory = directory
        self.environment = environment
        self.message = message
        self.ended = ended
    }

    func start(executable: URL) throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CopilotTransportError.failed("The installed helper is missing or isn’t executable.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CopilotTransportError.failed("The Copilot profile folder is not a regular directory.")
        }
        for handle in [stdin.fileHandleForWriting, stdout.fileHandleForReading,
                       stderr.fileHandleForReading, wake.fileHandleForReading, wake.fileHandleForWriting] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) >= 0 else {
                throw POSIXError(.EIO)
            }
        }
        for handle in [stdin.fileHandleForWriting, wake.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw POSIXError(.EIO) }
        }
        process.executableURL = executable
        process.arguments = ["--stdio"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async { [self] in run() }
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        guard !closed, !stopped else { lock.unlock(); return }
        guard queuedEncodings < 32 else {
            lock.unlock()
            stop("Copilot stopped accepting requests. Reconnect and try again.")
            return
        }
        queuedEncodings += 1
        lock.unlock()
        encodingQueue.async { [self] in
            defer { lock.lock(); queuedEncodings -= 1; lock.unlock() }
            do {
                let frame = try CopilotMessageFramer.encode(message)
                lock.lock()
                guard !closed, !stopped else { lock.unlock(); return }
                guard bufferedBytes + frame.count <= 16 * 1024 * 1024 else {
                    failure = "Copilot stopped accepting requests. Reconnect and try again."
                    stopped = true
                    wakeReader()
                    lock.unlock()
                    return
                }
                outgoing.append(frame)
                bufferedBytes += frame.count
                wakeReader()
                lock.unlock()
            } catch {
                stop(error.localizedDescription)
            }
        }
    }

    func stop(_ reason: String? = nil) {
        lock.lock()
        stopped = true
        if let reason { failure = reason }
        if !closed { wakeReader() }
        if process.isRunning {
            let pid = process.processIdentifier
            Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
        lock.unlock()
    }

    private func wakeReader() {
        var byte: UInt8 = 1
        _ = Darwin.write(wake.fileHandleForWriting.fileDescriptor, &byte, 1)
    }

    private func run() {
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        let wakeFD = wake.fileHandleForReading.fileDescriptor
        var outputs: Set<Int32> = [outputFD, errorFD]
        var framer = CopilotMessageFramer()
        var frame = Data(), offset = 0
        var errorOutput = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var exitDeadline: TimeInterval?
        var endMessage = "The Copilot helper stopped. Reconnect and try again."
        do {
            while true {
                lock.lock()
                let shouldStop = stopped
                if let failure { endMessage = failure }
                if frame.isEmpty, !outgoing.isEmpty { frame = outgoing.removeFirst(); offset = 0 }
                lock.unlock()
                if shouldStop { break }
                if !process.isRunning {
                    if exitDeadline == nil { exitDeadline = ProcessInfo.processInfo.systemUptime + 0.5 }
                    if outputs.isEmpty || ProcessInfo.processInfo.systemUptime >= exitDeadline! { break }
                }
                var descriptors = outputs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                descriptors.append(pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0))
                if !frame.isEmpty { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
                let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw CopilotTransportError.failed("The Copilot connection could not be read.")
                }
                for descriptor in descriptors where descriptor.revents != 0 {
                    if descriptor.fd == inputFD {
                        if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                            throw CopilotTransportError.stopped
                        }
                        let written = frame.withUnsafeBytes { pointer in
                            Darwin.write(inputFD, pointer.baseAddress!.advanced(by: offset), min(65_536, frame.count - offset))
                        }
                        if written > 0 {
                            offset += written
                            lock.lock(); bufferedBytes -= written; lock.unlock()
                            if offset == frame.count { frame = Data(); offset = 0 }
                        } else if written < 0 && errno != EINTR && errno != EAGAIN {
                            throw CopilotTransportError.stopped
                        }
                    } else {
                        let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                        if count > 0 {
                            if descriptor.fd == outputFD {
                                for body in try framer.consume(Data(bytes.prefix(count))) {
                                    guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                                          payload["jsonrpc"] as? String == "2.0" else {
                                        throw CopilotTransportError.failed("The Copilot helper returned an invalid response.")
                                    }
                                    while deliverySlots.wait(timeout: .now() + 0.1) == .timedOut {
                                        lock.lock(); let interrupted = stopped; lock.unlock()
                                        if interrupted { throw CopilotTransportError.stopped }
                                    }
                                    DispatchQueue.main.async { [message, deliverySlots] in
                                        message(payload)
                                        deliverySlots.signal()
                                    }
                                }
                            } else if descriptor.fd == errorFD {
                                errorOutput.append(contentsOf: bytes.prefix(count).suffix(8192))
                                if errorOutput.count > 8192 { errorOutput.removeFirst(errorOutput.count - 8192) }
                            }
                        } else if count == 0 || errno != EINTR && errno != EAGAIN {
                            outputs.remove(descriptor.fd)
                            if descriptor.fd == outputFD && process.isRunning {
                                throw CopilotTransportError.stopped
                            }
                        }
                    }
                }
            }
            if framer.hasPartialMessage { endMessage = "The Copilot helper closed during a response. Reconnect and try again." }
        } catch {
            endMessage = error.localizedDescription
        }
        lock.lock()
        closed = true
        outgoing.removeAll()
        bufferedBytes = 0
        lock.unlock()
        for handle in [stdin.fileHandleForWriting, stdout.fileHandleForReading, stderr.fileHandleForReading,
                       wake.fileHandleForReading, wake.fileHandleForWriting] { try? handle.close() }
        if process.isRunning {
            let pid = process.processIdentifier
            Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
        if !process.isRunning, process.terminationStatus != 0 {
            let detail = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { endMessage += "\n" + String(detail.suffix(2000)) }
        }
        DispatchQueue.main.async { [ended, endMessage] in ended(endMessage) }
    }
}
