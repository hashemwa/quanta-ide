import Darwin
import Foundation

struct PythonSourceInput: Codable, Equatable, Sendable {
    let id: UUID
    let source: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && EditorTextRange.isSameText(lhs.source, rhs.source)
    }
}

struct PythonDiagnostic: Identifiable, Codable, Hashable, Sendable {
    enum Severity: String, Codable, Sendable {
        case error, warning
    }

    let sourceID: UUID
    let line: Int
    let column: Int
    let endLine: Int
    let endColumn: Int
    let message: String
    let code: String
    let severity: Severity

    var id: String { "\(sourceID):\(line):\(column):\(endLine):\(endColumn):\(code):\(message)" }
}

struct PythonAnalysisResult: Sendable {
    let diagnostics: [PythonDiagnostic]
    let toolName: String
    let notice: String?
}

enum PythonToolingError: LocalizedError {
    case unavailable, cancelled, timedOut, outputLimit, inputLimit, invalidResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The Python analysis helper is missing from Quanta."
        case .cancelled: "Python analysis was cancelled."
        case .timedOut: "Python analysis took too long. Try checking a smaller document."
        case .outputLimit: "Python analysis returned too much output."
        case .inputLimit: "This document is too large for background Python analysis."
        case .invalidResponse: "The Python analysis helper returned an invalid response."
        case .failed(let message): message
        }
    }
}

@MainActor
final class PythonTooling {
    private let helperURL: URL?
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var generation = 0
    private var currentRequest: PythonToolingRequest?

    init(helperURL: URL? = nil, timeout: TimeInterval = 12, outputLimit: Int = 8 * 1_024 * 1_024) {
        self.helperURL = helperURL
            ?? Bundle.main.url(forResource: "quanta_analysis", withExtension: "py")
            ?? Bundle.main.url(forResource: "quanta_analysis", withExtension: "py", subdirectory: "Resources")
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    deinit { currentRequest?.cancel() }

    func analyze(sources: [PythonSourceInput], python: String, workingDirectory: URL?, isNotebook: Bool = false,
                 completion: @escaping (Result<PythonAnalysisResult, Error>) -> Void) {
        let input = PythonToolingInput(op: "analyze", sources: sources, source: nil, isNotebook: isNotebook)
        run(input: input, python: python, workingDirectory: workingDirectory, transform: { response in
            let sourceLines = Dictionary(sources.map {
                ($0.id, $0.source.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n"))
            }, uniquingKeysWith: { first, _ in first })
            let diagnostics = (response.diagnostics ?? []).compactMap { diagnostic -> PythonDiagnostic? in
                guard let lines = sourceLines[diagnostic.sourceID], !lines.isEmpty else { return nil }
                let line = min(max(1, diagnostic.line), lines.count)
                let endLine = min(max(line, diagnostic.endLine), lines.count)
                let column = Self.characterColumn(diagnostic.column, in: lines[line - 1], roundingUp: false)
                let endColumn = Self.characterColumn(diagnostic.endColumn, in: lines[endLine - 1], roundingUp: true)
                return PythonDiagnostic(sourceID: diagnostic.sourceID, line: line, column: column,
                                        endLine: endLine, endColumn: endLine == line ? max(column, endColumn) : endColumn,
                                        message: diagnostic.message, code: diagnostic.code, severity: diagnostic.severity)
            }
            guard let toolName = response.toolName else { throw PythonToolingError.invalidResponse }
            return PythonAnalysisResult(diagnostics: diagnostics, toolName: toolName, notice: response.notice)
        }, completion: completion)
    }

    func format(source: String, python: String, workingDirectory: URL?, isNotebook: Bool = false,
                completion: @escaping (Result<String, Error>) -> Void) {
        run(input: PythonToolingInput(op: "format", sources: nil, source: source, isNotebook: isNotebook), python: python,
            workingDirectory: workingDirectory, transform: { response in
                guard let source = response.source else { throw PythonToolingError.invalidResponse }
                return source
            }, completion: completion)
    }

    func cancel() {
        generation += 1
        currentRequest?.cancel()
        currentRequest = nil
    }

    private func run<Value>(input: PythonToolingInput, python: String, workingDirectory: URL?,
                            transform: @escaping (PythonToolingResponse) throws -> Value,
                            completion: @escaping (Result<Value, Error>) -> Void) {
        cancel()
        guard let helperURL else {
            completion(.failure(PythonToolingError.unavailable))
            return
        }
        let request = PythonToolingRequest()
        currentRequest = request
        let currentGeneration = generation
        let timeout = timeout
        let outputLimit = outputLimit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<Value, Error> {
                let inputData = try JSONEncoder().encode(input)
                guard inputData.count <= 8 * 1_024 * 1_024 else { throw PythonToolingError.inputLimit }
                let data = try request.run(python: python, helperURL: helperURL, input: inputData,
                                           workingDirectory: workingDirectory, timeout: timeout, outputLimit: outputLimit)
                let response = try JSONDecoder().decode(PythonToolingResponse.self, from: data)
                if let error = response.error { throw PythonToolingError.failed(error) }
                return try transform(response)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.currentRequest = nil
                completion(result)
            }
        }
    }

    nonisolated private static func characterColumn(_ column: Int, in line: String, roundingUp: Bool) -> Int {
        let offset = max(0, column - 1)
        var scalars = 0
        var characters = 1
        for character in line {
            if scalars >= offset { return characters }
            let next = scalars + character.unicodeScalars.count
            if next > offset { return characters + (roundingUp ? 1 : 0) }
            scalars = next
            characters += 1
        }
        return characters
    }
}

private struct PythonToolingInput: Encodable {
    let op: String
    let sources: [PythonSourceInput]?
    let source: String?
    let isNotebook: Bool
}

private struct PythonToolingResponse: Decodable {
    let diagnostics: [PythonDiagnostic]?
    let toolName: String?
    let notice: String?
    let source: String?
    let error: String?
}

private final class PythonToolingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(python: String, helperURL: URL, input: Data, workingDirectory: URL?,
             timeout: TimeInterval, outputLimit: Int) throws -> Data {
        if isCancelled { throw PythonToolingError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-u", helperURL.path]
        process.currentDirectoryURL = workingDirectory ?? FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let inputHandle = stdin.fileHandleForWriting
        let outputHandle = stdout.fileHandleForReading
        let errorHandle = stderr.fileHandleForReading
        let inputFD = inputHandle.fileDescriptor
        let outputFD = outputHandle.fileDescriptor
        let errorFD = errorHandle.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var inputOffset = 0
        var inputOpen = true
        var openOutputs: Set<Int32> = [outputFD, errorFD]
        var output = Data(), errors = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while process.isRunning || !openOutputs.isEmpty {
            if isCancelled { throw PythonToolingError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw PythonToolingError.timedOut }
            var descriptors = openOutputs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if inputOpen { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
            let result = poll(&descriptors, nfds_t(descriptors.count), 50)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                if descriptor.fd == inputFD {
                    if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        try? inputHandle.close()
                        inputOpen = false
                        continue
                    }
                    let count = input.withUnsafeBytes { pointer in
                        Darwin.write(inputFD, pointer.baseAddress!.advanced(by: inputOffset),
                                     min(65_536, input.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    if inputOffset == input.count || count < 0 && errno != EAGAIN && errno != EINTR {
                        try? inputHandle.close()
                        inputOpen = false
                    }
                } else {
                    let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
                    if count > 0 {
                        guard output.count + errors.count + count <= outputLimit else {
                            throw PythonToolingError.outputLimit
                        }
                        if descriptor.fd == outputFD { output.append(contentsOf: buffer.prefix(count)) }
                        else { errors.append(contentsOf: buffer.prefix(count)) }
                    } else if count == 0 || errno != EAGAIN && errno != EINTR {
                        openOutputs.remove(descriptor.fd)
                    }
                }
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PythonToolingError.failed(message.isEmpty ? "Python analysis stopped unexpectedly." : message)
        }
        return output
    }
}
