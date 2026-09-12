import Foundation

struct GitCommandResult {
    let status: Int32
    let output: Data
    let errorText: String

    var succeeded: Bool { status == 0 }
    var text: String { String(decoding: output, as: UTF8.self) }

    var failureMessage: String {
        let stderr = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "git exited with status \(status)" : stdout
    }
}

private final class PipeDrain {
    private let condition = NSCondition()
    private let handle: FileHandle
    private var storage = Data()
    private var isFinished = false

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [self] source in
            let chunk = source.availableData
            condition.lock()
            if chunk.isEmpty {
                source.readabilityHandler = nil
                isFinished = true
                condition.broadcast()
            } else {
                storage.append(chunk)
            }
            condition.unlock()
        }
    }

    func waitUntilEndOfFile(before deadline: Date) {
        condition.lock()
        while !isFinished, condition.wait(until: deadline) {}
        condition.unlock()
    }

    func stop() {
        handle.readabilityHandler = nil
        condition.lock()
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    var data: Data {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }
}

private final class TerminableProcess {
    private let lock = NSLock()
    private var process: Process?

    init(_ process: Process) { self.process = process }

    func release() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminateGroup() {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
        kill(-running.processIdentifier, SIGTERM)
    }
}

enum GitClient {
    static let queue = DispatchQueue(label: "quanta.git", qos: .userInitiated)
    private static let inheritedPipeGrace: TimeInterval = 2
    static let executable: String? = locateExecutable()

    private static func locateExecutable() -> String? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            candidates.insert(developerDirectory + "/usr/bin/git", at: 0)
        }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        if fm.isExecutableFile(atPath: "/usr/bin/git"), developerDirectoryIsConfigured() {
            return "/usr/bin/git"
        }
        return nil
    }

    private static func developerDirectoryIsConfigured() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func environment(for executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let fm = FileManager.default
        let preferred = [
            URL(fileURLWithPath: executable).deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map { String($0) }
        var path: [String] = []
        for entry in preferred + inherited where !path.contains(entry) && fm.fileExists(atPath: entry) {
            path.append(entry)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    static func literalPathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(literal)" + $0 }
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL,
                    timeout: TimeInterval = 120) -> GitCommandResult {
        guard let executable else {
            return GitCommandResult(status: -1, output: Data(), errorText: "git is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory.path] + arguments
        process.environment = environment(for: executable)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return GitCommandResult(status: -1, output: Data(),
                                    errorText: "Could not launch git: \(error.localizedDescription)")
        }

        let outputDrain = PipeDrain(stdout)
        let errorDrain = PipeDrain(stderr)

        let terminable = TerminableProcess(process)
        let watchdog = DispatchWorkItem { terminable.terminateGroup() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        terminable.release()

        let deadline = Date().addingTimeInterval(inheritedPipeGrace)
        outputDrain.waitUntilEndOfFile(before: deadline)
        errorDrain.waitUntilEndOfFile(before: deadline)
        outputDrain.stop()
        errorDrain.stop()

        return GitCommandResult(status: process.terminationStatus, output: outputDrain.data,
                                errorText: String(decoding: errorDrain.data, as: UTF8.self))
    }
}
