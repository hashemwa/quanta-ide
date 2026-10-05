import CryptoKit
import Darwin
import Foundation

@MainActor
final class CopilotInstaller {
    struct Release: Sendable {
        let version: String
        let url: URL
        let sha256: String

        static let official = Release(
            version: "1.551.2",
            url: URL(string: "https://github.com/github/copilot-language-server-release/releases/download/1.551.2/copilot-language-server-darwin-arm64-1.551.2.zip")!,
            sha256: "56d45abf26a8f58913f40a347f09a6ba2aa030d46a127a227e4fe6e85cbb1fae")
    }

    typealias Downloader = @Sendable (URL) async throws -> URL

    private struct Receipt: Codable {
        let version: String
        let archiveSHA256: String
        let executablePath: String
        let executableSHA256: String
    }

    private let directory: URL
    private let bundledExecutable: URL?
    private let release: Release
    private let downloader: Downloader
    private var installation: Task<URL, Error>?

    init(installationDirectory: URL? = nil, bundledExecutable: URL? = nil,
         release: Release = .official, downloader: @escaping Downloader = CopilotInstaller.download) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = installationDirectory ?? support.appendingPathComponent("Quanta/Copilot", isDirectory: true)
        self.bundledExecutable = bundledExecutable
            ?? Bundle.main.url(forResource: "copilot-language-server", withExtension: nil, subdirectory: "Copilot")
        self.release = release
        self.downloader = downloader
    }

    func executable() async throws -> URL {
        try Task.checkCancellation()
        let task: Task<URL, Error>
        if let installation { task = installation }
        else {
            task = Task { try await locateOrInstall() }
            installation = task
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            installation = nil
            return result
        } catch {
            installation = nil
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? CopilotInstallerError { throw error }
            throw CopilotInstallerError.failed("Couldn’t install the Copilot helper: \(error.localizedDescription)")
        }
    }

    private func locateOrInstall() async throws -> URL {
        let directory = directory
        let release = release
        if let bundledExecutable {
            return try await Self.background {
                try Self.validateExecutable(bundledExecutable)
                return bundledExecutable
            }
        }
        if let cached = try await Self.background({ try Self.cachedExecutable(in: directory, release: release) }) { return cached }
        let archive = try await downloader(release.url)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Task.checkCancellation()
        return try await Self.background {
            let actualHash = try Self.sha256(of: archive)
            guard actualHash == release.sha256 else {
                throw CopilotInstallerError.failed("The Copilot download failed its integrity check. Try again; the helper was not installed.")
            }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.requireDirectory(directory)
            let staging = directory.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            try Self.extract(archive, into: staging)
            try Task.checkCancellation()
            let (executable, relativePath) = try Self.findExecutable(in: staging)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try Self.validateExecutable(executable)
            let receipt = Receipt(version: release.version, archiveSHA256: release.sha256,
                                  executablePath: relativePath, executableSHA256: try Self.sha256(of: executable))
            try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(".quanta-install.json"), options: .atomic)
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(release.version, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                try Self.requireDirectory(destination)
                guard renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw CopilotInstallerError.failed("Couldn’t replace the cached Copilot helper: \(String(cString: strerror(errno)))")
                }
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return destination.appendingPathComponent(relativePath)
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CopilotInstallerError.failed("The Copilot installation folder is not a regular directory. Remove it and try again.")
        }
    }

    nonisolated static func validateExecutable(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CopilotInstallerError.failed("The Copilot helper is missing or isn’t a regular executable. Reinstall it and try again.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 8),
              Array(header) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] else {
            throw CopilotInstallerError.failed("The Copilot helper is not a native Apple Silicon executable. Reinstall it and try again.")
        }
    }

    nonisolated private static func cachedExecutable(in directory: URL, release: Release) throws -> URL? {
        let destination = directory.appendingPathComponent(release.version, isDirectory: true)
        let receiptURL = destination.appendingPathComponent(".quanta-install.json")
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        try requireDirectory(directory)
        try requireDirectory(destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 16_384,
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == release.version, receipt.archiveSHA256 == release.sha256,
              !receipt.executablePath.hasPrefix("/"),
              !receipt.executablePath.split(separator: "/").contains("..") else { return nil }
        let components = receipt.executablePath.split(separator: "/").map(String.init)
        guard components.last == "copilot-language-server", !components.contains(".") else { return nil }
        var executable = destination
        for component in components.dropLast() {
            executable.appendPathComponent(component)
            guard (try? requireDirectory(executable)) != nil else { return nil }
        }
        executable.appendPathComponent("copilot-language-server")
        guard (try? validateExecutable(executable)) != nil else { return nil }
        guard try sha256(of: executable) == receipt.executableSHA256 else { return nil }
        return executable
    }

    nonisolated private static func findExecutable(in directory: URL) throws -> (URL, String) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            throw CopilotInstallerError.failed("Couldn’t read the downloaded Copilot helper.")
        }
        var matches: [(URL, String)] = []
        var count = 0, bytes = 0
        while let relativePath = enumerator.nextObject() as? String {
            try Task.checkCancellation()
            let item = directory.appendingPathComponent(relativePath)
            let values = try item.resourceValues(forKeys: Set(keys))
            count += 1
            bytes += values.fileSize ?? 0
            guard values.isSymbolicLink != true, count <= 10_000, bytes <= 1_073_741_824 else {
                throw CopilotInstallerError.failed("The Copilot archive contains unexpected files. The helper was not installed.")
            }
            if item.lastPathComponent == "copilot-language-server", values.isRegularFile == true { matches.append((item, relativePath)) }
        }
        guard matches.count == 1, let executable = matches.first else {
            throw CopilotInstallerError.failed("The download did not contain the expected Copilot executable.")
        }
        return executable
    }

    nonisolated private static func extract(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CopilotInstallerError.failed("Couldn’t unpack the Copilot helper: \(error.localizedDescription)") }
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        defer {
            if process.isRunning {
                let pid = process.processIdentifier
                Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
        }
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CopilotInstallerError.failed("Unpacking the Copilot helper timed out. Try again.")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CopilotInstallerError.failed("Couldn’t unpack the Copilot download. Try again.")
        }
    }

    nonisolated static func download(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Quanta-Copilot-Installer", forHTTPHeaderField: "User-Agent")
        let guardrail = CopilotDownloadDelegate()
        do {
            let (temporary, response) = try await session.download(for: request, delegate: guardrail)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CopilotInstallerError.failed("GitHub could not provide the Copilot helper (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Try again later.")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= CopilotDownloadDelegate.maximumBytes else {
                try? FileManager.default.removeItem(at: temporary)
                throw CopilotInstallerError.failed("The Copilot download had an unexpected size. Try again.")
            }
            return temporary
        } catch let error as URLError where error.code == .timedOut {
            throw CopilotInstallerError.failed("Downloading Copilot timed out. Check your connection and try again.")
        } catch {
            if guardrail.exceededLimit { throw CopilotInstallerError.failed("The Copilot download exceeded its expected size.") }
            throw error
        }
    }
}

enum CopilotInstallerError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

private final class CopilotDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maximumBytes = 128 * 1024 * 1024
    private let lock = NSLock()
    private var tooLarge = false
    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tooLarge
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes {
            lock.lock(); tooLarge = true; lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        completionHandler(request.url?.scheme == "https" && hosts.contains(request.url?.host ?? "") ? request : nil)
    }
}
