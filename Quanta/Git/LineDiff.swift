import Foundation

struct DiffRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case context
        case added
        case removed
        case gap
    }

    let id: Int
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let text: String
    let hiddenCount: Int
    let runStart: Int

    init(id: Int, kind: Kind, oldLine: Int?, newLine: Int?, text: String,
         hiddenCount: Int = 0, runStart: Int = 0) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
        self.hiddenCount = hiddenCount
        self.runStart = runStart
    }

    static func gap(hiding count: Int, runStart: Int) -> DiffRow {
        DiffRow(id: -(runStart + 1), kind: .gap, oldLine: nil, newLine: nil, text: "",
                hiddenCount: count, runStart: runStart)
    }
}

enum LineDiff {
    static let maximumEditWork = 8_000
    static let missingNewlineMarker = " \\ No newline at end of file"

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func align(old: [String], new: [String]) -> [DiffRow] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if oldMiddle.isEmpty || newMiddle.isEmpty
            || oldMiddle.count + newMiddle.count > maximumEditWork {
            removed = Set(oldMiddle.indices)
            inserted = Set(newMiddle.indices)
        } else {
            let difference = newMiddle.difference(from: oldMiddle)
            for change in difference.removals {
                if case .remove(let offset, _, _) = change { removed.insert(offset) }
            }
            for change in difference.insertions {
                if case .insert(let offset, _, _) = change { inserted.insert(offset) }
            }
        }

        var rows: [DiffRow] = []
        rows.reserveCapacity(old.count + new.count - prefix - suffix)
        for index in 0..<prefix {
            rows.append(DiffRow(id: rows.count, kind: .context, oldLine: index + 1,
                                newLine: index + 1, text: old[index]))
        }
        var i = 0
        var j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            if i < oldMiddle.count, removed.contains(i) {
                rows.append(DiffRow(id: rows.count, kind: .removed, oldLine: prefix + i + 1,
                                    newLine: nil, text: oldMiddle[i]))
                i += 1
            } else if j < newMiddle.count, inserted.contains(j) {
                rows.append(DiffRow(id: rows.count, kind: .added, oldLine: nil,
                                    newLine: prefix + j + 1, text: newMiddle[j]))
                j += 1
            } else if i < oldMiddle.count, j < newMiddle.count {
                rows.append(DiffRow(id: rows.count, kind: .context, oldLine: prefix + i + 1,
                                    newLine: prefix + j + 1, text: oldMiddle[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        for index in 0..<suffix {
            let oldIndex = old.count - suffix + index
            let newIndex = new.count - suffix + index
            rows.append(DiffRow(id: rows.count, kind: .context, oldLine: oldIndex + 1,
                                newLine: newIndex + 1, text: old[oldIndex]))
        }
        return rows
    }
}

struct DiffDocument: Equatable {
    let oldLabel: String
    let newLabel: String
    let rows: [DiffRow]
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isTooLarge: Bool
    let isNotebook: Bool

    static let maximumLines = 60_000

    var hasChanges: Bool { additions > 0 || deletions > 0 }

    static func compare(oldText: String, newText: String, oldLabel: String, newLabel: String,
                        isNotebook: Bool) -> DiffDocument {
        let old = LineDiff.lines(oldText)
        let new = LineDiff.lines(newText)
        guard old.count + new.count <= maximumLines else {
            return DiffDocument(oldLabel: oldLabel, newLabel: newLabel, rows: [], additions: 0,
                                deletions: 0, isBinary: false, isTooLarge: true,
                                isNotebook: isNotebook)
        }
        var rows = LineDiff.align(old: old, new: new)
        let oldEndsWithNewline = oldText.hasSuffix("\n")
        let newEndsWithNewline = newText.hasSuffix("\n")
        if old == new, !old.isEmpty, oldEndsWithNewline != newEndsWithNewline {
            let last = rows.count - 1
            let oldText = old[old.count - 1] + (oldEndsWithNewline ? "" : LineDiff.missingNewlineMarker)
            let newText = new[new.count - 1] + (newEndsWithNewline ? "" : LineDiff.missingNewlineMarker)
            rows[last] = DiffRow(id: last, kind: .removed, oldLine: old.count, newLine: nil, text: oldText)
            rows.append(DiffRow(id: rows.count, kind: .added, oldLine: nil, newLine: new.count, text: newText))
        }
        var additions = 0
        var deletions = 0
        for row in rows {
            switch row.kind {
            case .added: additions += 1
            case .removed: deletions += 1
            default: break
            }
        }
        return DiffDocument(oldLabel: oldLabel, newLabel: newLabel, rows: rows,
                            additions: additions, deletions: deletions, isBinary: false,
                            isTooLarge: false, isNotebook: isNotebook)
    }

    static func binary(oldLabel: String, newLabel: String) -> DiffDocument {
        DiffDocument(oldLabel: oldLabel, newLabel: newLabel, rows: [], additions: 0, deletions: 0,
                     isBinary: true, isTooLarge: false, isNotebook: false)
    }

    func displayRows(context: Int, expanded: Set<Int>) -> [DiffRow] {
        var out: [DiffRow] = []
        var index = 0
        let count = rows.count
        while index < count {
            guard rows[index].kind == .context else {
                out.append(rows[index])
                index += 1
                continue
            }
            var end = index
            while end < count, rows[end].kind == .context { end += 1 }
            let leading = index == 0 ? 0 : context
            let trailing = end == count ? 0 : context
            let hidden = (end - index) - leading - trailing
            if hidden <= 1 || expanded.contains(index) {
                out.append(contentsOf: rows[index..<end])
            } else {
                out.append(contentsOf: rows[index..<(index + leading)])
                out.append(DiffRow.gap(hiding: hidden, runStart: index))
                out.append(contentsOf: rows[(end - trailing)..<end])
            }
            index = end
        }
        return out
    }

    static func isBinaryData(_ data: Data) -> Bool {
        let sample = data.prefix(8000)
        return sample.contains(0)
    }

    static func text(from data: Data) -> String? {
        if data.isEmpty { return "" }
        if isBinaryData(data) { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

struct DiffSource: Equatable {
    let path: String
    let originalPath: String?
    let url: URL
    let area: GitChange.Area
    let status: GitChange.Status
    let isAdHoc: Bool

    init(change: GitChange) {
        path = change.path
        originalPath = change.originalPath
        url = change.url
        area = change.area
        status = change.status
        isAdHoc = false
    }

    init(path: String, url: URL, area: GitChange.Area, status: GitChange.Status) {
        self.path = path
        self.originalPath = nil
        self.url = url
        self.area = area
        self.status = status
        self.isAdHoc = true
    }

    static func == (lhs: DiffSource, rhs: DiffSource) -> Bool {
        lhs.path == rhs.path && lhs.area == rhs.area
    }

    var fileName: String { url.lastPathComponent }
    var isNotebook: Bool { url.pathExtension.lowercased() == "ipynb" }

    var oldLabel: String {
        switch area {
        case .staged: return "HEAD"
        case .unstaged: return "Index"
        case .conflicted: return "HEAD"
        }
    }

    var newLabel: String {
        switch area {
        case .staged: return "Index"
        case .unstaged, .conflicted: return "Working Tree"
        }
    }

    static func load(_ source: DiffSource, root: URL) -> Result<DiffDocument, QuantaError> {
        let oldData: Data?
        let newData: Data?
        switch source.area {
        case .staged:
            oldData = source.status == .added
                ? Data()
                : blob("HEAD:\(source.originalPath ?? source.path)", root: root)
            newData = source.status == .deleted ? Data() : blob(":\(source.path)", root: root)
        case .unstaged:
            oldData = source.status == .untracked ? Data() : blob(":\(source.path)", root: root)
            newData = source.status == .deleted ? Data() : (try? Data(contentsOf: source.url))
        case .conflicted:
            oldData = blob("HEAD:\(source.path)", root: root) ?? Data()
            newData = try? Data(contentsOf: source.url)
        }
        guard let oldData else {
            return .failure(QuantaError("git has no \(source.oldLabel) version of \(source.fileName)."))
        }
        guard let newData else {
            return .failure(QuantaError("\(source.fileName) could not be read from \(source.newLabel)."))
        }
        if source.isNotebook,
           let oldText = flattenedNotebook(oldData), let newText = flattenedNotebook(newData) {
            return .success(DiffDocument.compare(oldText: oldText, newText: newText,
                                                 oldLabel: source.oldLabel, newLabel: source.newLabel,
                                                 isNotebook: true))
        }
        guard let oldText = DiffDocument.text(from: oldData),
              let newText = DiffDocument.text(from: newData) else {
            return .success(DiffDocument.binary(oldLabel: source.oldLabel, newLabel: source.newLabel))
        }
        return .success(DiffDocument.compare(oldText: oldText, newText: newText,
                                             oldLabel: source.oldLabel, newLabel: source.newLabel,
                                             isNotebook: false))
    }

    private static func blob(_ spec: String, root: URL) -> Data? {
        let result = GitClient.run(["show", spec], in: root)
        return result.succeeded ? result.output : nil
    }

    private static func flattenedNotebook(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        return NotebookSemantics.flattened(data)
    }
}
