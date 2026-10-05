import Combine
import Darwin
import Foundation

struct PythonPackage: Decodable, Identifiable, Equatable {
    let name: String
    let version: String
    var id: String { name.lowercased() }
}

@MainActor
final class PythonEnvironmentManager: ObservableObject {
    enum Operation: Equatable {
        case listing, installing, creating

        var title: String {
            switch self {
            case .listing: return "Loading installed packages…"
            case .installing: return "Installing packages…"
            case .creating: return "Creating workspace environment…"
            }
        }
    }

    @Published private(set) var python: String?
    @Published private(set) var workspace: URL?
    @Published private(set) var packages: [PythonPackage] = []
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var commandOutput = ""
    @Published private(set) var hasLoadedPackages = false
    @Published private(set) var workspaceEnvironmentExists = false
    @Published private(set) var restartRecommended = false
    @Published private(set) var isMutating = false
    @Published private(set) var trusted = false
    @Published private(set) var kernelBusy = false

    private let operationTimeout: TimeInterval
    private let listingTimeout: TimeInterval
    private let onMutationChanged: (Bool) -> Void
    private var mutationCount = 0
    private var contextID = UUID()
    private var operationID: UUID?
    private var command: PythonEnvironmentCommand?

    init(operationTimeout: TimeInterval = 600, listingTimeout: TimeInterval = 30,
         onMutationChanged: @escaping (Bool) -> Void = { _ in }) {
        self.operationTimeout = operationTimeout
        self.listingTimeout = listingTimeout
        self.onMutationChanged = onMutationChanged
    }

    var isBusy: Bool { operation != nil || isMutating }
    var canManage: Bool { python != nil && trusted && !kernelBusy && !isBusy }

    func configure(python: String?, workspace: URL?, trusted: Bool, kernelBusy: Bool) {
        let workspace = workspace?.standardizedFileURL
        if self.python != python || self.workspace != workspace || self.trusted != trusted {
            command?.cancel()
            command = nil
            contextID = UUID()
            operationID = nil
            operation = nil
            packages = []
            hasLoadedPackages = false
            errorMessage = nil
            statusMessage = nil
            commandOutput = ""
            restartRecommended = false
        } else if kernelBusy && !self.kernelBusy {
            cancel()
        }
        self.python = python
        self.workspace = workspace
        self.trusted = trusted
        self.kernelBusy = kernelBusy
        updateWorkspaceEnvironment()
    }

    func refreshPackages() async {
        guard let python = readyInterpreter() else { return }
        let result = await perform(.listing, python: python,
                                   arguments: pipArguments + ["list", "--format=json"],
                                   timeout: listingTimeout)
        guard let result else { return }
        guard accept(result, for: .listing) else { return }
        guard !result.outputTruncated else {
            errorMessage = "The installed package list is too large to display. Use this interpreter’s pip in Terminal to inspect it."
            return
        }
        do {
            let decoded = try JSONDecoder().decode([PythonPackage].self, from: result.output)
            var seen = Set<String>()
            packages = decoded.filter { seen.insert($0.id).inserted }.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            hasLoadedPackages = true
        } catch {
            errorMessage = "Python returned an unreadable package list. Check the selected interpreter, then refresh."
        }
    }

    @discardableResult
    func installPackages(_ input: String) async -> Bool {
        guard let python = readyInterpreter() else { return false }
        let requirements: [String]
        do { requirements = try Self.packageRequirements(input) }
        catch { errorMessage = error.localizedDescription; return false }
        let result = await perform(.installing, python: python,
                                   arguments: pipArguments + ["install", "--no-user", "--progress-bar", "off", "--"] + requirements,
                                   timeout: operationTimeout)
        guard let result else { return false }
        restartRecommended = result.launched
        guard accept(result, for: .installing) else { return false }
        hasLoadedPackages = false
        statusMessage = "Packages installed. Restart the Python session before importing updated packages."
        return true
    }

    func createEnvironment() async -> String? {
        guard let python = readyInterpreter() else { return nil }
        guard let workspace else {
            errorMessage = "Open a workspace folder before creating an environment."
            return nil
        }
        let destination = workspace.appendingPathComponent(".venv", isDirectory: true)
        guard mkdir(destination.path, 0o755) == 0 else {
            let code = errno
            updateWorkspaceEnvironment()
            errorMessage = workspaceEnvironmentExists
                ? "A .venv already exists in this workspace. Select its Python interpreter from the Python menu, or choose another workspace."
                : "Couldn’t create .venv: \(String(cString: strerror(code)))"
            return nil
        }
        updateWorkspaceEnvironment()
        let result = await perform(.creating, python: python,
                                   arguments: ["-I", "-m", "venv", destination.path],
                                   timeout: operationTimeout)
        guard let result else { return nil }
        guard accept(result, for: .creating) else {
            let detail = "The incomplete .venv remains in this workspace. Inspect it and remove it before trying again."
            if let errorMessage { self.errorMessage = errorMessage + "\n" + detail }
            else { statusMessage = (statusMessage ?? "Creation stopped.") + " " + detail }
            return nil
        }
        let interpreter = ["bin/python3", "bin/python"].map { destination.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let interpreter else {
            errorMessage = "Creation finished without a Python executable. Inspect the workspace’s .venv before trying again."
            return nil
        }
        statusMessage = "Created .venv in \(workspace.lastPathComponent). Choose it as the Python environment for this workspace."
        return interpreter
    }

    func cancel() {
        guard let command else { return }
        statusMessage = "Canceling…"
        command.cancel()
    }

    static func packageRequirements(_ input: String) throws -> [String] {
        let requirements = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = "[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
        let extras = "(?:\\[" + name + "(?:," + name + ")*\\])?"
        let constraint = "(?:===|==|!=|~=|>=|<=|>|<)[A-Za-z0-9.*+!_-]+"
        let pattern = "^" + name + extras + "(?:" + constraint + "(?:," + constraint + ")*)?$"
        guard !requirements.isEmpty, requirements.count <= 64, input.utf8.count <= 4096,
              requirements.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) else {
            throw PackageInputError()
        }
        return requirements
    }

    private var pipArguments: [String] {
        ["-I", "-u", "-m", "pip", "--isolated", "--disable-pip-version-check", "--no-input"]
    }

    private func readyInterpreter() -> String? {
        guard !Task.isCancelled else { return nil }
        guard !isBusy else { return nil }
        guard trusted else { errorMessage = "Trust this workspace before managing Python packages."; return nil }
        guard !kernelBusy else { errorMessage = "Wait for running code to finish before managing Python packages."; return nil }
        guard let python, FileManager.default.isExecutableFile(atPath: python) else {
            errorMessage = "Select an available Python interpreter from the Python menu."
            return nil
        }
        return python
    }

    private func updateWorkspaceEnvironment() {
        workspaceEnvironmentExists = workspace.map {
            (try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent(".venv").path)) != nil
        } ?? false
    }

    private func perform(_ operation: Operation, python: String, arguments: [String],
                         timeout: TimeInterval) async -> PythonEnvironmentCommandResult? {
        let context = contextID
        let identifier = UUID()
        let command = PythonEnvironmentCommand()
        if operation != .listing { setMutationCount(mutationCount + 1) }
        defer {
            if operation != .listing { setMutationCount(mutationCount - 1) }
        }
        operationID = identifier
        self.command = command
        self.operation = operation
        errorMessage = nil
        if operation != .listing { statusMessage = nil; commandOutput = "" }
        let directory = workspace ?? FileManager.default.temporaryDirectory
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = command.run(python: python, arguments: arguments, directory: directory,
                                             timeout: timeout) { [weak self] output in
                        guard operation != .listing else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.contextID == context, self.operationID == identifier else { return }
                            self.commandOutput = output
                        }
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            command.cancel()
        }
        guard contextID == context, operationID == identifier else { return nil }
        self.command = nil
        self.operation = nil
        operationID = nil
        if operation != .listing { commandOutput = result.log }
        updateWorkspaceEnvironment()
        return result
    }

    private func setMutationCount(_ count: Int) {
        mutationCount = count
        let mutating = count > 0
        guard mutating != isMutating else { return }
        isMutating = mutating
        onMutationChanged(mutating)
    }

    private func accept(_ result: PythonEnvironmentCommandResult, for operation: Operation) -> Bool {
        if result.cancelled {
            statusMessage = operation == .installing
                ? "Installation canceled. Some packages may have changed; restart the Python session before continuing."
                : "Operation canceled."
            return false
        }
        if result.timedOut {
            errorMessage = "The operation timed out. Check the interpreter and network connection, then try again."
            return false
        }
        guard result.status == 0 else {
            let detail = result.failureMessage
            if detail.contains("No module named pip") {
                errorMessage = "This Python environment has no pip. Create a workspace .venv, or enable pip for the selected interpreter using python -m ensurepip in Terminal."
            } else if detail.contains("No module named venv") || detail.contains("ensurepip is not available") {
                errorMessage = "This Python installation cannot create virtual environments. Choose a Python installation with venv and ensurepip, then try again."
            } else if detail.contains("externally-managed-environment") || detail.contains("not writeable") || detail.contains("Permission denied") {
                errorMessage = "This Python environment cannot be modified directly. Create a workspace .venv and select it before installing packages.\n" + detail
            } else {
                errorMessage = detail
            }
            return false
        }
        return true
    }
}

private struct PackageInputError: LocalizedError {
    var errorDescription: String? {
        "Enter package names separated by spaces, such as pandas numpy or pandas>=2,<3. URLs, local paths and pip options must be used in Terminal."
    }
}

private struct PythonEnvironmentCommandResult {
    var status: Int32 = -1
    var output = Data()
    var error = ""
    var log = ""
    var outputTruncated = false
    var cancelled = false
    var timedOut = false
    var launched = false

    var failureMessage: String {
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return String(message.suffix(4096)) }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Python exited with status \(status)." : String(text.suffix(4096))
    }
}

private final class PythonEnvironmentCommand: @unchecked Sendable {
    private enum StopReason { case cancelled, timeout }
    private let condition = NSCondition()
    private var process: Process?
    private var processGroup: pid_t?
    private var stopReason: StopReason?
    private var output = Data()
    private var errors = Data()
    private var log = Data()
    private var outputTruncated = false
    private var endedStreams = 0
    private var lastReport = Date.distantPast
    private let outputLimit = 1_048_576
    private let logLimit = 32_768

    func cancel() { stop(.cancelled) }

    func run(python: String, arguments: [String], directory: URL, timeout: TimeInterval,
             report: @escaping @Sendable (String) -> Void) -> PythonEnvironmentCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PIP_") && !$0.key.hasPrefix("PYTHON") }
        environment["PIP_CONFIG_FILE"] = "/dev/null"
        process.environment = environment
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in drain(handle, isError: false, report: report) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in drain(handle, isError: true, report: report) }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        condition.lock()
        guard stopReason == nil else {
            condition.unlock()
            return PythonEnvironmentCommandResult(cancelled: true)
        }
        do {
            try process.run()
            self.process = process
            let pid = process.processIdentifier
            processGroup = getpgid(pid) == pid ? pid : nil
            condition.unlock()
        } catch {
            condition.unlock()
            return PythonEnvironmentCommandResult(error: "Couldn’t launch Python: \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { [self] in stop(.timeout) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        condition.lock()
        if stopReason != nil, let processGroup { kill(-processGroup, SIGKILL) }
        self.process = nil
        let deadline = Date().addingTimeInterval(1)
        while endedStreams < 2, condition.wait(until: deadline) {}
        let result = PythonEnvironmentCommandResult(status: process.terminationStatus, output: output,
                                                    error: String(decoding: errors, as: UTF8.self),
                                                    log: String(decoding: log, as: UTF8.self),
                                                    outputTruncated: outputTruncated,
                                                    cancelled: stopReason == .cancelled,
                                                    timedOut: stopReason == .timeout, launched: true)
        condition.unlock()
        return result
    }

    private func drain(_ handle: FileHandle, isError: Bool, report: @escaping @Sendable (String) -> Void) {
        let chunk = handle.availableData
        condition.lock()
        guard !chunk.isEmpty else {
            handle.readabilityHandler = nil
            endedStreams += 1
            condition.broadcast()
            condition.unlock()
            return
        }
        if isError {
            errors.append(chunk.prefix(max(0, outputLimit - errors.count)))
        } else {
            outputTruncated = outputTruncated || chunk.count > outputLimit - output.count
            output.append(chunk.prefix(max(0, outputLimit - output.count)))
        }
        log.append(chunk.suffix(logLimit))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
        let shouldReport = Date().timeIntervalSince(lastReport) >= 0.1
        let text = shouldReport ? String(decoding: log, as: UTF8.self) : nil
        if shouldReport { lastReport = Date() }
        condition.unlock()
        if let text { report(text) }
    }

    private func stop(_ reason: StopReason) {
        condition.lock()
        guard stopReason == nil else { condition.unlock(); return }
        stopReason = reason
        if let process, process.isRunning { signal(process, SIGTERM) }
        condition.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            condition.lock()
            if let process, process.isRunning { signal(process, SIGKILL) }
            condition.unlock()
        }
    }

    private func signal(_ process: Process, _ value: Int32) {
        let pid = process.processIdentifier
        kill(getpgid(pid) == pid ? -pid : pid, value)
    }
}
