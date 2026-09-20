import Foundation

struct CompletionEdit: Equatable {
    let range: NSRange
    let text: String
}

struct CodeCompletion {
    let label: String
    var detail = ""
    var documentation = ""
    var kind = 0
    var filterText: String
    var sortText: String
    let edit: CompletionEdit
    var additionalEdits: [CompletionEdit] = []
    var placeholders: [NSRange] = []

    init(label: String, text: String? = nil, range: NSRange) {
        self.label = label
        filterText = label
        sortText = label
        edit = CompletionEdit(range: range, text: text ?? label)
    }

    var kindLabel: String {
        switch kind {
        case 2: "method"
        case 3: "function"
        case 5: "field"
        case 6: "variable"
        case 7: "class"
        case 9: "module"
        case 10: "property"
        case 14: "keyword"
        case 21: "constant"
        default: ""
        }
    }

    static func rank(_ value: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        if value.hasPrefix(query) { return 0 }
        let value = value.lowercased(), query = query.lowercased()
        if value.hasPrefix(query) { return 1 }
        var remaining = query[...]
        for character in value where remaining.first == character { remaining = remaining.dropFirst() }
        return remaining.isEmpty ? 2 : nil
    }

    static func parse(_ item: [String: Any], snapshot: LanguageDocument, editorID: UUID, offset: Int) -> CodeCompletion? {
        guard let label = item["label"] as? String,
              let source = snapshot.segments.first(where: { $0.editorID == editorID })?.source else { return nil }
        let prefix = (source as NSString).substring(to: offset)
        let token = String(prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
        let suffix = String((source as NSString).substring(from: offset).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        let rawEdit = item["textEdit"] as? [String: Any]
        let range: NSRange
        if let rawEdit {
            guard let parsed = snapshot.range(rawEdit["range"] ?? rawEdit["replace"], editorID: editorID) else { return nil }
            range = parsed
        } else { range = NSRange(location: offset - token.utf16.count, length: token.utf16.count + suffix.utf16.count) }
        guard range.location <= offset, NSMaxRange(range) >= offset else { return nil }
        let text = rawEdit?["newText"] as? String ?? item["insertText"] as? String ?? label
        let snippet: CompletionSnippet
        if item["insertTextFormat"] as? Int == 2 {
            guard let parsed = CompletionSnippet(text) else { return nil }
            snippet = parsed
        } else { snippet = CompletionSnippet(literal: text) }
        var completion = CodeCompletion(label: label, text: snippet.text, range: range)
        completion.placeholders = snippet.ranges
        completion.filterText = item["filterText"] as? String ?? label
        completion.sortText = item["sortText"] as? String ?? label
        completion.detail = item["detail"] as? String ?? ""
        completion.documentation = PythonLanguageService.documentation(item["documentation"])
        completion.kind = item["kind"] as? Int ?? 0
        for edit in item["additionalTextEdits"] as? [[String: Any]] ?? [] {
            guard let range = snapshot.range(edit["range"], editorID: editorID), let text = edit["newText"] as? String else { return nil }
            completion.additionalEdits.append(CompletionEdit(range: range, text: text))
        }
        guard CompletionTransaction(source: source, completion: completion) != nil else { return nil }
        return completion
    }
}

struct CompletionSnippet {
    let text: String
    let ranges: [NSRange]

    init(literal: String) { text = literal; ranges = [] }

    init?(_ snippet: String) {
        let chars = Array(snippet)
        var output = "", stops: [(Int, NSRange)] = [], i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                i += 1; output.append(chars[i]); i += 1; continue
            }
            guard chars[i] == "$" else { output.append(chars[i]); i += 1; continue }
            i += 1
            let braced = i < chars.count && chars[i] == "{"
            if braced { i += 1 }
            var number = ""
            while i < chars.count, chars[i].isNumber { number.append(chars[i]); i += 1 }
            guard let index = Int(number) else { return nil }
            var value = ""
            if braced {
                if i < chars.count, chars[i] == ":" {
                    i += 1
                    while i < chars.count, chars[i] != "}" {
                        if chars[i] == "$" || chars[i] == "{" { return nil }
                        if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                        value.append(chars[i]); i += 1
                    }
                }
                guard i < chars.count, chars[i] == "}" else { return nil }
                i += 1
            }
            stops.append((index, NSRange(location: output.utf16.count, length: value.utf16.count)))
            output += value
        }
        text = output
        ranges = stops.sorted { ($0.0 == 0 ? Int.max : $0.0) < ($1.0 == 0 ? Int.max : $1.0) }.map(\.1)
    }
}

struct CompletionTransaction {
    let edits: [CompletionEdit]
    let selection: NSRange
    let placeholders: [NSRange]

    init?(source: String, completion: CodeCompletion) {
        let edits = (completion.additionalEdits + [completion.edit]).sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        for (index, edit) in edits.enumerated() {
            guard edit.range.location >= 0, edit.range.length >= 0, NSMaxRange(edit.range) <= source.utf16.count else { return nil }
            if index > 0, NSMaxRange(edits[index - 1].range) > edit.range.location || (edits[index - 1].range.location == edit.range.location && edit.range.length == 0) { return nil }
        }
        self.edits = edits
        let shift = completion.additionalEdits.filter { $0.range.location <= completion.edit.range.location }
            .reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
        let start = completion.edit.range.location + shift
        placeholders = completion.placeholders.map { NSRange(location: start + $0.location, length: $0.length) }
        selection = placeholders.first ?? NSRange(location: start + completion.edit.text.utf16.count, length: 0)
    }
}
