import Foundation

struct WorkspaceSearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regularExpression = false
    var include = ""
    var exclude = ""

    func expression(for query: String) throws -> NSRegularExpression {
        let pattern = regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        return try NSRegularExpression(pattern: wholeWord ? "\\b(?:\(pattern))\\b" : pattern,
                                       options: caseSensitive ? [] : [.caseInsensitive])
    }

    func accepts(_ path: String) -> Bool {
        func matches(_ patterns: String) -> Bool {
            patterns.split(separator: ",").contains { raw in
                let glob = raw.trimmingCharacters(in: .whitespaces)
                guard !glob.isEmpty else { return false }
                let escaped = NSRegularExpression.escapedPattern(for: glob)
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\*\\*", with: "§")
                    .replacingOccurrences(of: "\\*", with: "[^/]*")
                    .replacingOccurrences(of: "\\?", with: "[^/]")
                    .replacingOccurrences(of: "§/", with: "(?:.*/)?")
                    .replacingOccurrences(of: "§", with: ".*")
                let target = glob.contains("/") ? path : (path as NSString).lastPathComponent
                return target.range(of: "^\(escaped)$", options: .regularExpression) != nil
            }
        }
        return (include.trimmingCharacters(in: .whitespaces).isEmpty || matches(include)) && !matches(exclude)
    }
}

enum WorkspaceIndex {
    static func files(in node: FileNode) -> [URL] {
        node.isDirectory ? (node.children ?? []).flatMap { files(in: $0) } : [node.url]
    }

    static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let text = candidate.lowercased()
        let query = query.lowercased()
        if text == query { return 0 }
        if text.hasPrefix(query) { return 1 }
        if text.contains(query) { return 2 }
        var cursor = text.startIndex
        var gaps = 0
        for character in query {
            guard let found = text[cursor...].firstIndex(of: character) else { return nil }
            gaps += text.distance(from: cursor, to: found)
            cursor = text.index(after: found)
        }
        return 3 + gaps
    }
}

struct WorkspaceSearchReport {
    var results: [AppState.FileSearchResult] = []
    var truncated = false
    var skippedFiles = 0
    var error: String?
}

enum WorkspaceSearcher {
    static let limit = 400

    static func search(root: URL, query: String, options: WorkspaceSearchOptions) -> WorkspaceSearchReport {
        guard !query.isEmpty else { return WorkspaceSearchReport() }
        let expression: NSRegularExpression
        do { expression = try options.expression(for: query) }
        catch { return WorkspaceSearchReport(error: "Invalid regular expression: \(error.localizedDescription)") }
        var report = WorkspaceSearchReport()
        let searchable: Set<String> = ["py", "ipynb", "md", "txt", "json", "yaml", "yml", "toml", "csv", "cfg", "ini", "sh", "rst", "swift", "js", "ts", "html", "css"]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if ["__pycache__", "node_modules", "venv", "build", "dist"].contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard options.accepts(path), searchable.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            guard (values.fileSize ?? 0) < 8_000_000, let data = try? Data(contentsOf: url) else { report.skippedFiles += 1; continue }
            let sources: [(String, Int?)]
            if url.pathExtension.lowercased() == "ipynb" {
                guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cells = dict["cells"] as? [[String: Any]] else { report.skippedFiles += 1; continue }
                sources = cells.enumerated().map { index, cell in
                    ((cell["source"] as? [String])?.joined() ?? cell["source"] as? String ?? "", index)
                }
            } else {
                guard let text = String(data: data, encoding: .utf8) else { report.skippedFiles += 1; continue }
                sources = [(text, nil)]
            }
            for (source, cellIndex) in sources {
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let text = line as NSString
                    guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { continue }
                    if report.results.count == limit { report.truncated = true; return report }
                    let start = max(0, match.range.location - 40)
                    let end = min(text.length, max(start + 160, NSMaxRange(match.range)))
                    let preview = (start > 0 ? "…" : "") + text.substring(with: NSRange(location: start, length: end - start)) + (end < text.length ? "…" : "")
                    report.results.append(AppState.FileSearchResult(fileURL: url, line: index + 1, preview: preview, cellIndex: cellIndex))
                }
            }
        }
        report.results.sort { $0.fileURL.path == $1.fileURL.path ? ($0.cellIndex ?? -1, $0.line) < ($1.cellIndex ?? -1, $1.line) : $0.fileURL.path < $1.fileURL.path }
        return report
    }
}
