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
