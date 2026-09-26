import AppKit
import Foundation

struct FileOperationReport {
    var completed: [(source: URL, destination: URL)] = []
    var skipped: [URL] = []
    var failures: [(URL, String)] = []

    var summary: String? {
        guard !failures.isEmpty || !skipped.isEmpty else { return nil }
        var parts: [String] = []
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        return parts.joined(separator: " · ")
    }
}

enum FileCollisionChoice { case keepBoth, skip, cancel }

enum FileOperations {
    static func transfer(_ sources: [URL], to directory: URL, copying: Bool,
                         collision: (URL) -> FileCollisionChoice) -> FileOperationReport {
        var report = FileOperationReport()
        let fm = FileManager.default
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for source in normalized(sources) {
            let sourcePath = source.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(source.lastPathComponent).standardizedFileURL.path
            if directoryPath == sourcePath || directoryPath.hasPrefix(sourcePath + "/") {
                report.failures.append((source, "A folder can’t be moved into itself."))
                continue
            }
            if !copying, source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == directoryPath {
                report.skipped.append(source)
                continue
            }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                switch collision(destination) {
                case .keepBoth: destination = availableURL(for: destination)
                case .skip: report.skipped.append(source); continue
                case .cancel: return report
                }
            }
            do {
                if copying { try fm.copyItem(at: source, to: destination) }
                else { try fm.moveItem(at: source, to: destination) }
                report.completed.append((source, destination))
            } catch {
                report.failures.append((source, error.localizedDescription))
            }
        }
        return report
    }

    static func duplicate(_ sources: [URL]) -> FileOperationReport {
        var report = FileOperationReport()
        let fm = FileManager.default
        for source in normalized(sources) {
            let destination = availableURL(for: source, copySuffix: true)
            do {
                try fm.copyItem(at: source, to: destination)
                report.completed.append((source, destination))
            } catch {
                report.failures.append((source, error.localizedDescription))
            }
        }
        return report
    }

    private static func normalized(_ urls: [URL]) -> [URL] {
        let sorted = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path.count < $1.path.count }
        return sorted.filter { candidate in
            !sorted.contains { other in
                other != candidate && candidate.path.hasPrefix(other.path + "/")
            }
        }
    }

    private static func availableURL(for url: URL, copySuffix: Bool = false) -> URL {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = copySuffix ? (index == 1 ? " copy" : " copy \(index)") : " \(index)"
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
