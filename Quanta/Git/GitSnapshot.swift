import Foundation

enum GitChangeScope: String, CaseIterable {
    case all = "All"
    case staged = "Staged"
    case unstaged = "Unstaged"

    func includes(_ area: GitChange.Area) -> Bool {
        area == .conflicted || self == .all || (self == .staged && area == .staged)
            || (self == .unstaged && area == .unstaged)
    }
}

struct GitChange: Identifiable, Hashable {
    enum Area: Hashable {
        case staged
        case unstaged
        case conflicted

        var label: String {
            switch self {
            case .staged: return "Staged"
            case .unstaged: return "Changes"
            case .conflicted: return "Conflict"
            }
        }
    }

    enum Status: Hashable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case typeChanged
        case untracked
        case conflicted

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .copied: return "C"
            case .typeChanged: return "T"
            case .untracked: return "U"
            case .conflicted: return "!"
            }
        }

        var label: String {
            switch self {
            case .modified: return "Modified"
            case .added: return "Added"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .copied: return "Copied"
            case .typeChanged: return "Type changed"
            case .untracked: return "Untracked"
            case .conflicted: return "Conflict"
            }
        }
    }

    let path: String
    let originalPath: String?
    let status: Status
    let area: Area
    let url: URL

    var id: String { "\(area.label)|\(path)" }
    var fileName: String { url.lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isNotebook: Bool { url.pathExtension.lowercased() == "ipynb" }
    var existsOnDisk: Bool { status != .deleted }
}

struct GitSnapshot {
    let workspace: URL
    let root: URL
    let workspacePrefix: String
    let branch: String?
    let isDetached: Bool
    let headOID: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let hasCommits: Bool
    let branches: [String]
    let remotes: [String]
    let staged: [GitChange]
    let unstaged: [GitChange]
    let conflicted: [GitChange]
    let hiddenNotebooks: [GitChange]
    let truncatedCount: Int
    let statusByPath: [String: GitChange.Status]
    let directoriesWithChanges: Set<String>

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
    var visibleChanges: [GitChange] { conflicted + staged + unstaged }
    var changedPathCount: Int { statusByPath.count }
    var publishRemote: String? {
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes.first : nil
    }

    var headDescription: String {
        if isDetached {
            let short = headOID.map { String($0.prefix(7)) } ?? "HEAD"
            return "\(short) (detached)"
        }
        return branch ?? "HEAD"
    }

    static let maximumEntries = 2000

    private static func describesMissingRepository(_ result: GitCommandResult) -> Bool {
        let stderr = result.errorText.lowercased()
        return stderr.contains("not a git repository")
            || stderr.contains("does not have a commit checked out")
    }

    static func load(workspace: URL, hideOutputOnlyNotebooks: Bool) -> Result<GitSnapshot, QuantaError>? {
        let location = GitClient.run(["rev-parse", "--show-toplevel", "--show-prefix"], in: workspace)
        guard location.succeeded else {
            return describesMissingRepository(location) ? nil
                                                        : .failure(QuantaError(location.failureMessage))
        }
        let lines = location.text.components(separatedBy: "\n")
        let rootPath = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rootPath.isEmpty else { return nil }
        let prefix = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        let status = GitClient.run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root)
        guard status.succeeded else { return .failure(QuantaError(status.failureMessage)) }
        let parsed = GitStatusParser.parse(status.output)

        let refs = GitClient.run(
            ["for-each-ref", "--format=%(refname:short)", "--sort=refname", "refs/heads"], in: root)
        let branches = refs.succeeded
            ? refs.text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
            : []
        let remoteResult = GitClient.run(["remote"], in: root)
        let remotes = remoteResult.succeeded ? remoteResult.text.split(separator: "\n").map(String.init) : []

        func fileURL(for path: String) -> URL {
            if prefix.isEmpty { return workspace.appendingPathComponent(path) }
            if path.hasPrefix(prefix) {
                return workspace.appendingPathComponent(String(path.dropFirst(prefix.count)))
            }
            return root.appendingPathComponent(path)
        }

        var staged: [GitChange] = []
        var unstaged: [GitChange] = []
        var conflicted: [GitChange] = []
        var hidden: [GitChange] = []
        var statusByPath: [String: GitChange.Status] = [:]
        var truncated = 0

        for entry in parsed.entries {
            let url = fileURL(for: entry.path)
            if entry.isConflicted {
                let change = GitChange(path: entry.path, originalPath: nil, status: .conflicted,
                                       area: .conflicted, url: url)
                conflicted.append(change)
                statusByPath[url.path] = .conflicted
                continue
            }
            var shown: GitChange.Status?
            if let stagedStatus = entry.staged {
                staged.append(GitChange(path: entry.path, originalPath: entry.originalPath,
                                        status: stagedStatus, area: .staged, url: url))
                shown = stagedStatus
            }
            if let unstagedStatus = entry.unstaged {
                let change = GitChange(path: entry.path, originalPath: nil, status: unstagedStatus,
                                       area: .unstaged, url: url)
                if hideOutputOnlyNotebooks, unstagedStatus == .modified, change.isNotebook,
                   NotebookSemantics.indexMatchesWorkingTree(path: entry.path, url: url, root: root) {
                    hidden.append(change)
                } else if unstagedStatus == .untracked, unstaged.count >= maximumEntries {
                    truncated += 1
                } else {
                    unstaged.append(change)
                    if shown != .added && shown != .renamed { shown = unstagedStatus }
                }
            }
            if let shown { statusByPath[url.path] = shown }
        }
        staged.sort { $0.path < $1.path }
        unstaged.sort { $0.path < $1.path }
        conflicted.sort { $0.path < $1.path }

        var directories = Set<String>()
        let workspacePath = workspace.path
        for change in conflicted + staged + unstaged {
            var parent = change.url.deletingLastPathComponent()
            while parent.path.hasPrefix(workspacePath), parent.path != workspacePath,
                  parent.path.count > 1 {
                directories.insert(parent.path)
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
        }

        let header = parsed.header
        return .success(GitSnapshot(
            workspace: workspace,
            root: root,
            workspacePrefix: prefix,
            branch: header.branch == "(detached)" ? nil : header.branch,
            isDetached: header.branch == "(detached)",
            headOID: header.oid == "(initial)" ? nil : header.oid,
            upstream: header.upstream,
            ahead: header.ahead,
            behind: header.behind,
            hasCommits: header.oid != nil && header.oid != "(initial)",
            branches: branches,
            remotes: remotes,
            staged: staged,
            unstaged: unstaged,
            conflicted: conflicted,
            hiddenNotebooks: hidden,
            truncatedCount: truncated,
            statusByPath: statusByPath,
            directoriesWithChanges: directories))
    }

    func repositoryPath(for url: URL) -> String? {
        let base = workspace.path
        let path = url.path
        if path == base { return nil }
        if path.hasPrefix(base + "/") {
            return workspacePrefix + String(path.dropFirst(base.count + 1))
        }
        let resolvedBase = root.resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedBase + "/") else { return nil }
        return String(resolved.dropFirst(resolvedBase.count + 1))
    }
}

enum GitStatusParser {
    struct Header {
        var branch: String?
        var oid: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
    }

    struct Entry: Equatable {
        let staged: GitChange.Status?
        let unstaged: GitChange.Status?
        let isConflicted: Bool
        let path: String
        let originalPath: String?
    }

    struct Result {
        let header: Header
        let entries: [Entry]
    }

    static func parse(_ data: Data) -> Result {
        var header = Header()
        var entries: [Entry] = []
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                parseHeader(record, into: &header)
                continue
            }
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                entries.append(Entry(staged: status(fields[1].first),
                                     unstaged: status(fields[1].last),
                                     isConflicted: false,
                                     path: String(fields[8]),
                                     originalPath: nil))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, index < records.count else { continue }
                let original = records[index]
                index += 1
                entries.append(Entry(staged: status(fields[1].first),
                                     unstaged: status(fields[1].last),
                                     isConflicted: false,
                                     path: String(fields[9]),
                                     originalPath: original))
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                entries.append(Entry(staged: nil, unstaged: nil, isConflicted: true,
                                     path: String(fields[10]), originalPath: nil))
            case "?":
                guard record.count > 2 else { continue }
                entries.append(Entry(staged: nil, unstaged: .untracked, isConflicted: false,
                                     path: String(record.dropFirst(2)), originalPath: nil))
            default:
                continue
            }
        }
        return Result(header: header, entries: entries)
    }

    private static func parseHeader(_ line: String, into header: inout Header) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }
        switch parts[1] {
        case "branch.oid":
            header.oid = String(parts[2])
        case "branch.head":
            header.branch = String(parts[2])
        case "branch.upstream":
            header.upstream = String(parts[2])
        case "branch.ab":
            guard parts.count >= 4 else { return }
            header.ahead = Int(parts[2].dropFirst()) ?? 0
            header.behind = Int(parts[3].dropFirst()) ?? 0
        default:
            break
        }
    }

    private static func status(_ code: Character?) -> GitChange.Status? {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return nil
        }
    }
}

enum NotebookSemantics {
    struct CellSignature: Equatable {
        let type: String
        let source: String
    }

    static func cells(in data: Data) -> [CellSignature]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = object["cells"] as? [[String: Any]] else { return nil }
        return cells.map {
            CellSignature(type: $0["cell_type"] as? String ?? "code",
                          source: Notebook.joinedText($0["source"]))
        }
    }

    static func sameUserContent(_ a: Data, _ b: Data) -> Bool {
        guard let first = cells(in: a), let second = cells(in: b) else { return false }
        return first == second
    }

    static func flattened(_ data: Data) -> String? {
        guard let cells = cells(in: data) else { return nil }
        var parts: [String] = []
        for cell in cells {
            parts.append(cell.type == "code" ? "# %%" : "# %% [\(cell.type)]")
            parts.append(cell.source)
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    static func indexMatchesWorkingTree(path: String, url: URL, root: URL) -> Bool {
        let index = GitClient.run(["show", ":\(path)"], in: root)
        guard index.succeeded, let working = try? Data(contentsOf: url) else { return false }
        return sameUserContent(index.output, working)
    }
}
