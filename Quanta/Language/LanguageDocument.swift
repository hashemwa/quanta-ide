import Foundation

struct LanguagePosition: Equatable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) { self.line = line; self.character = character }
    init?(_ value: Any?) {
        guard let dict = value as? [String: Any], let line = dict["line"] as? Int,
              let character = dict["character"] as? Int, line >= 0, character >= 0 else { return nil }
        self.init(line: line, character: character)
    }
    var json: [String: Int] { ["line": line, "character": character] }

    static func offset(_ position: LanguagePosition, in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(position.line) else { return nil }
        let line = lines[position.line]
        let count = line.utf16.count - (line.hasSuffix("\r") ? 1 : 0)
        guard position.character <= count else { return nil }
        return lines.prefix(position.line).reduce(0) { $0 + $1.utf16.count + 1 } + position.character
    }

    static func at(_ offset: Int, in text: String) -> LanguagePosition? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: offset).components(separatedBy: "\n")
        return LanguagePosition(line: prefix.count - 1, character: prefix.last?.utf16.count ?? 0)
    }
}

struct LanguageDocument: Equatable {
    struct Segment: Equatable {
        let editorID: UUID
        let range: NSRange
        let source: String
    }

    let documentID: UUID
    let uri: String
    let text: String
    let segments: [Segment]

    init?(document: Document, root: URL) {
        documentID = document.id
        if document.kind == .script, document.url == nil || ["py", "pyi"].contains(document.url?.pathExtension.lowercased() ?? "") {
            uri = (document.url ?? root.appendingPathComponent(".quanta-\(document.id).py")).absoluteString
            text = document.text
            segments = [Segment(editorID: document.id, range: NSRange(location: 0, length: text.utf16.count), source: text)]
        } else if let notebook = document.notebook {
            let directory = document.url?.deletingLastPathComponent() ?? root
            uri = directory.appendingPathComponent(".quanta-notebook-\(document.id).py").absoluteString
            var source = ""
            var parts: [Segment] = []
            for cell in notebook.cells where cell.cellType == .code {
                if !parts.isEmpty { source += "\n\n" }
                parts.append(Segment(editorID: cell.id, range: NSRange(location: source.utf16.count, length: cell.source.utf16.count), source: cell.source))
                source += cell.source
            }
            text = source
            segments = parts
        } else { return nil }
    }

    func position(editorID: UUID, offset: Int) -> LanguagePosition? {
        guard let segment = segments.first(where: { $0.editorID == editorID }),
              offset >= 0, offset <= segment.range.length else { return nil }
        return LanguagePosition.at(segment.range.location + offset, in: text)
    }

    func location(_ position: LanguagePosition) -> (editorID: UUID, offset: Int)? {
        guard let offset = LanguagePosition.offset(position, in: text),
              let part = segments.first(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) else { return nil }
        return (part.editorID, offset - part.range.location)
    }

    func range(_ value: Any?, editorID: UUID) -> NSRange? {
        guard let dict = value as? [String: Any], let start = LanguagePosition(dict["start"]),
              let end = LanguagePosition(dict["end"]), let first = location(start), let last = location(end),
              first.editorID == editorID, last.editorID == editorID, last.offset >= first.offset else { return nil }
        return NSRange(location: first.offset, length: last.offset - first.offset)
    }
}

struct LanguageDiagnostic: Identifiable, Equatable {
    let editorID: UUID
    let range: NSRange
    let message: String
    let severity: Int
    let line: Int
    var id: String { "\(editorID):\(range.location):\(range.length):\(message)" }
}
