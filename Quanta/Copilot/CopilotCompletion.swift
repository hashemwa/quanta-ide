import Foundation

struct CopilotSuggestion {
    let source: String
    let caret: Int
    let range: NSRange
    let text: String
    let item: [String: Any]
    let revision: Int
    let uri: String

    init(source: String, caret: Int, range: NSRange, text: String,
         item: [String: Any] = [:], revision: Int = 0, uri: String = "") {
        self.source = source
        self.caret = caret
        self.range = range
        self.text = text
        self.item = item
        self.revision = revision
        self.uri = uri
    }
}

struct CopilotTextPosition: Equatable {
    let line: Int
    let character: Int

    var dictionary: [String: Int] { ["line": line, "character": character] }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ value: Any?) {
        guard let value = value as? [String: Any],
              let line = value["line"] as? Int, let character = value["character"] as? Int,
              line >= 0, character >= 0 else { return nil }
        self.init(line: line, character: character)
    }

    init?(offset: Int, in source: String) {
        let text = source as NSString
        guard offset >= 0, offset <= text.length,
              Self.isCharacterBoundary(offset, in: text) else { return nil }
        var start = 0
        var line = 0
        while start < text.length {
            let (contentEnd, end) = Self.lineBounds(from: start, in: text)
            if offset <= contentEnd {
                self.init(line: line, character: offset - start)
                return
            }
            guard offset >= end else { return nil }
            start = end
            line += 1
        }
        self.init(line: line, character: 0)
    }

    func offset(in source: String) -> Int? {
        guard line >= 0, character >= 0 else { return nil }
        let text = source as NSString
        var start = 0
        var currentLine = 0
        while currentLine < line, start < text.length {
            let (contentEnd, end) = Self.lineBounds(from: start, in: text)
            guard contentEnd < end else { return nil }
            start = end
            currentLine += 1
        }
        guard currentLine == line else { return nil }
        let contentEnd = Self.lineBounds(from: start, in: text).contentEnd
        guard character <= contentEnd - start else { return nil }
        let offset = start + character
        guard Self.isCharacterBoundary(offset, in: text) else { return nil }
        return offset
    }

    private static func isCharacterBoundary(_ offset: Int, in text: NSString) -> Bool {
        offset == text.length || text.rangeOfComposedCharacterSequence(at: offset).location == offset
    }

    private static func lineBounds(from start: Int, in text: NSString) -> (contentEnd: Int, end: Int) {
        var end = start
        while end < text.length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
        let contentEnd = end
        if end < text.length {
            let isCR = text.character(at: end) == 13
            end += 1
            if isCR, end < text.length, text.character(at: end) == 10 { end += 1 }
        }
        return (contentEnd, end)
    }
}

struct CopilotDocumentSnapshot {
    static let contextLimit = 256 * 1_024
    static let suggestionLimit = 8 * 1_024

    let uri: String
    let languageID: String
    let text: String
    let source: String
    let caret: Int
    let cellRange: NSRange
    let position: CopilotTextPosition

    init?(document: Document, sourceID: UUID, source: String, caret: Int) {
        guard source.utf16.count <= Self.contextLimit,
              caret >= 0, caret <= source.utf16.count,
              Range(NSRange(location: caret, length: 0), in: source) != nil else { return nil }
        var before: [String] = []
        var after: [String] = []
        var markdownCell: NotebookCell?
        if document.kind == .notebook {
            guard let active = document.notebook?.cells.first(where: { $0.id == sourceID }),
                  active.cellType != .raw else { return nil }
            if active.cellType == .markdown {
                markdownCell = active
            } else {
                let cells = document.notebook?.cells.filter { $0.cellType == .code } ?? []
                guard let index = cells.firstIndex(where: { $0.id == sourceID }) else { return nil }
                var remaining = Self.contextLimit - source.utf16.count
                for cell in cells[..<index].reversed() {
                    let count = cell.source.utf16.count
                    guard count <= remaining - 2 else { break }
                    before.append(cell.source)
                    remaining -= count + 2
                }
                for cell in cells.dropFirst(index + 1) {
                    let count = cell.source.utf16.count
                    guard count <= remaining - 2 else { break }
                    after.append(cell.source)
                    remaining -= count + 2
                }
            }
        } else {
            guard document.kind == .script, sourceID == document.id else { return nil }
        }
        let prefix = before.reversed().map { $0 + "\n\n" }.joined()
        text = prefix + source + after.map { "\n\n" + $0 }.joined()
        cellRange = NSRange(location: prefix.utf16.count, length: source.utf16.count)
        guard let position = CopilotTextPosition(offset: cellRange.location + caret, in: text) else { return nil }
        self.position = position
        self.source = source
        self.caret = caret
        languageID = markdownCell == nil ? "python" : "markdown"
        if let markdownCell {
            let name = "\(document.url?.lastPathComponent ?? document.id.uuidString).cell-\(markdownCell.id.uuidString).md"
            uri = document.url?.deletingLastPathComponent().appendingPathComponent(name).absoluteString
                ?? "untitled:quanta-\(name)"
        } else {
            uri = document.url?.absoluteString ?? "untitled:quanta-\(document.id.uuidString).py"
        }
    }

    func suggestion(from item: [String: Any], revision: Int) -> CopilotSuggestion? {
        guard let insertion = item["insertText"] as? String,
              !insertion.isEmpty, insertion.utf16.count <= Self.suggestionLimit else { return nil }
        let start: Int
        let end: Int
        if let range = item["range"] as? [String: Any] {
            guard let first = CopilotTextPosition(range["start"])?.offset(in: text),
                  let last = CopilotTextPosition(range["end"])?.offset(in: text) else { return nil }
            start = first
            end = last
        } else if item["range"] == nil {
            start = cellRange.location + caret
            end = start
        } else {
            return nil
        }
        guard start >= cellRange.location, end >= start,
              end <= cellRange.location + cellRange.length,
              start <= cellRange.location + caret, end >= cellRange.location + caret else { return nil }
        let normalized = insertion.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let newText = source.contains("\r\n") ? normalized.replacingOccurrences(of: "\n", with: "\r\n") : normalized
        return CopilotSuggestion(source: source, caret: caret,
                                 range: NSRange(location: start - cellRange.location, length: end - start),
                                 text: newText, item: item, revision: revision, uri: uri)
    }
}
