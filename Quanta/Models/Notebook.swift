import AppKit
import Combine
import Foundation

enum CellType: String {
    case code
    case markdown
    case raw
}

final class NotebookCell: ObservableObject, Identifiable {
    let id = UUID()
    var nbID: String
    @Published var cellType: CellType
    @Published var source: String
    @Published var outputs: [CellOutput]
    @Published var executionCount: Int?
    @Published var isRunning = false
    @Published var isQueued = false
    @Published var isEditingMarkdown = false
    @Published var editorHeight: CGFloat
    @Published var lastDuration: Double?
    @Published var lastExecutedSource: String?
    var hasStaleOutput: Bool { !outputs.isEmpty && lastExecutedSource.map { $0 != source } == true }
    var runStartedAt: Date?
    @Published var isSourceCollapsed = false
    @Published var isOutputCollapsed = false
    var metadata: [String: Any]
    var extraKeys: [String: Any]

    init(type: CellType,
         source: String = "",
         outputs: [CellOutput] = [],
         executionCount: Int? = nil,
         nbID: String = NotebookCell.makeNBID(),
         metadata: [String: Any] = [:],
         extraKeys: [String: Any] = [:]) {
        self.cellType = type
        self.source = source
        self.lastExecutedSource = outputs.isEmpty ? nil : source
        self.outputs = outputs
        self.executionCount = executionCount
        self.nbID = nbID
        self.metadata = metadata
        self.extraKeys = extraKeys
        let lines = source.isEmpty ? 1 : source.components(separatedBy: "\n").count
        self.editorHeight = CGFloat(max(1, lines)) * EditorTheme.lineHeight + 16.0
    }

    static func makeNBID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }
}

final class Notebook: ObservableObject {
    @Published var cells: [NotebookCell]
    var metadata: [String: Any]
    var nbformat: Int
    var nbformatMinor: Int

    init(cells: [NotebookCell], metadata: [String: Any], nbformat: Int = 4, nbformatMinor: Int = 5) {
        self.cells = cells
        self.metadata = metadata
        self.nbformat = nbformat
        self.nbformatMinor = nbformatMinor
    }

    static func empty() -> Notebook {
        Notebook(
            cells: [NotebookCell(type: .code)],
            metadata: [
                "kernelspec": ["display_name": "Python 3", "language": "python", "name": "python3"],
                "language_info": ["name": "python"],
            ])
    }

    static func load(from data: Data) throws -> Notebook {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuantaError("This file is not a valid Jupyter notebook.")
        }
        guard dict["nbformat"] as? Int == 4, let rawCells = dict["cells"] as? [[String: Any]] else {
            throw QuantaError("Unsupported notebook format — Quanta reads nbformat 4 notebooks.")
        }
        let cells = rawCells.map { parseCell($0) }
        return Notebook(
            cells: cells.isEmpty ? [NotebookCell(type: .code)] : cells,
            metadata: dict["metadata"] as? [String: Any] ?? [:],
            nbformat: dict["nbformat"] as? Int ?? 4,
            nbformatMinor: dict["nbformat_minor"] as? Int ?? 5)
    }

    private static let knownCellKeys: Set<String> = [
        "cell_type", "id", "metadata", "source", "outputs", "execution_count",
    ]

    static func parseCell(_ dict: [String: Any]) -> NotebookCell {
        let type = CellType(rawValue: dict["cell_type"] as? String ?? "code") ?? .raw
        let source = joinedText(dict["source"])
        let execCount = dict["execution_count"] as? Int
        let nbID = dict["id"] as? String ?? NotebookCell.makeNBID()
        let metadata = dict["metadata"] as? [String: Any] ?? [:]
        let extras = dict.filter { !knownCellKeys.contains($0.key) }
        let outputs = (dict["outputs"] as? [[String: Any]] ?? []).map { parseOutput($0) }
        let cell = NotebookCell(type: type, source: source, outputs: outputs,
                                executionCount: execCount, nbID: nbID, metadata: metadata,
                                extraKeys: extras)
        if let jupyter = metadata["jupyter"] as? [String: Any] {
            cell.isSourceCollapsed = jupyter["source_hidden"] as? Bool ?? false
            cell.isOutputCollapsed = jupyter["outputs_hidden"] as? Bool ?? false
        }
        return cell
    }

    static func joinedText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [String] { return arr.joined() }
        return ""
    }

    static func attachmentData(_ value: Any?) -> [String: Data] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: Data] = [:]
        let preferred = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"]
        for (name, raw) in dict {
            guard let mimes = raw as? [String: Any] else { continue }
            var encoded = ""
            for mime in preferred {
                encoded = joinedText(mimes[mime])
                if !encoded.isEmpty { break }
            }
            if encoded.isEmpty {
                for (key, payload) in mimes where key.hasPrefix("image/") {
                    encoded = joinedText(payload)
                    if !encoded.isEmpty { break }
                }
            }
            guard !encoded.isEmpty,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            else { continue }
            out[name] = data
        }
        return out
    }

    private static func parseOutput(_ dict: [String: Any]) -> CellOutput {
        CellOutput(kind: displayKind(for: dict), raw: dict)
    }

    private static func displayKind(for dict: [String: Any]) -> CellOutput.Kind {
        switch dict["output_type"] as? String {
        case "stream":
            return .stream(name: dict["name"] as? String ?? "stdout",
                           text: joinedText(dict["text"]).strippingANSI)
        case "error":
            let tb = (dict["traceback"] as? [String])?.joined(separator: "\n") ?? ""
            return .error(ename: dict["ename"] as? String ?? "Error",
                          evalue: dict["evalue"] as? String ?? "",
                          traceback: tb.strippingANSI, frames: [])
        case "execute_result", "display_data":
            let data = dict["data"] as? [String: Any] ?? [:]
            return RichOutput.kind(data)
        default:
            return .unsupported(mime: dict["output_type"] as? String ?? "unknown")
        }
    }

    var contentFingerprint: Int {
        var hasher = Hasher()
        for cell in cells {
            hasher.combine(cell.cellType.rawValue)
            hasher.combine(cell.source)
            hasher.combine(cell.outputs.count)
            hasher.combine(cell.executionCount ?? -1)
            hasher.combine(cell.isSourceCollapsed)
            hasher.combine(cell.isOutputCollapsed)
        }
        return hasher.finalize()
    }

    func serializedData() throws -> Data {
        var meta = metadata
        if meta["kernelspec"] == nil {
            meta["kernelspec"] = ["display_name": "Python 3", "language": "python", "name": "python3"]
        }
        if meta["language_info"] == nil {
            meta["language_info"] = ["name": "python"]
        }
        let dict: [String: Any] = [
            "cells": cells.map { serializeCell($0) },
            "metadata": meta,
            "nbformat": nbformat,
            "nbformat_minor": max(nbformatMinor, 5),
        ]
        return try JupyterJSON.data(dict)
    }

    func serializeCell(_ cell: NotebookCell) -> [String: Any] {
        var dict = cell.extraKeys
        if cell.cellType == .code { dict["attachments"] = nil }
        dict["cell_type"] = cell.cellType.rawValue
        dict["id"] = cell.nbID
        var metadata = cell.metadata
        var jupyter = metadata["jupyter"] as? [String: Any] ?? [:]
        jupyter["source_hidden"] = cell.isSourceCollapsed ? true : nil
        jupyter["outputs_hidden"] = cell.isOutputCollapsed ? true : nil
        metadata["jupyter"] = jupyter.isEmpty ? nil : jupyter
        dict["metadata"] = metadata
        dict["source"] = sourceLines(cell.source)
        if cell.cellType == .code {
            dict["execution_count"] = cell.executionCount ?? NSNull()
            dict["outputs"] = cell.outputs.compactMap {
                serializeOutput($0, executionCount: cell.executionCount)
            }
        }
        return dict
    }

    private static let lineBreaks: Set<Character> = [
        "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}",
        "\u{85}", "\u{2028}", "\u{2029}",
    ]

    private func sourceLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var out: [String] = []
        var current = ""
        for character in s {
            current.append(character)
            if Notebook.lineBreaks.contains(character) {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func serializeOutput(_ output: CellOutput, executionCount: Int?) -> [String: Any]? {
        if let raw = output.raw { return raw }
        if let bundle = RichOutput.bundle(output) { return RichOutput.raw(bundle) }
        switch output.kind {
        case .stream(let name, let text):
            return ["output_type": "stream", "name": name,
                    "text": sourceLines(text.strippingANSI)]
        case .executeResult(let text):
            return ["output_type": "execute_result",
                    "execution_count": executionCount ?? NSNull(),
                    "data": ["text/plain": sourceLines(text)],
                    "metadata": [:] as [String: Any]]
        case .image(let data, _),
             .plotlyFigure(_, _, let data, _, _):
            guard !data.isEmpty else {
                return textResult("<plotly figure — re-run in Quanta to view>",
                                  executionCount: executionCount)
            }
            return ["output_type": "display_data",
                    "data": ["image/png": data.base64EncodedString()],
                    "metadata": [:] as [String: Any]]
        case .error(let ename, let evalue, let traceback, _):
            return ["output_type": "error", "ename": ename, "evalue": evalue,
                    "traceback": traceback.isEmpty ? [] : traceback.components(separatedBy: "\n")]
        case .dataFrame(let payload):
            return textResult(payload.text, executionCount: executionCount)
        case .ndarray(let payload):
            return textResult(payload.text, executionCount: executionCount)
        case .jsonTree(let payload):
            return textResult(payload.text, executionCount: executionCount)
        case .objectCard(let payload):
            return textResult(payload.text, executionCount: executionCount)
        case .rich(let bundle):
            return RichOutput.raw(bundle)
        case .unsupported(let mime):
            return textResult("Unsupported output: \(mime)", executionCount: executionCount)
        }
    }

    private func textResult(_ text: String, executionCount: Int?) -> [String: Any] {
        ["output_type": "execute_result",
         "execution_count": executionCount ?? NSNull(),
         "data": ["text/plain": sourceLines(text)],
         "metadata": [:] as [String: Any]]
    }
}

enum JupyterJSON {
    static func data(_ object: Any) throws -> Data {
        var out = ""
        try write(object, indent: 0, into: &out)
        out.append("\n")
        return Data(out.utf8)
    }

    private static func write(_ value: Any, indent: Int, into out: inout String) throws {
        switch value {
        case let dictionary as [String: Any]:
            guard !dictionary.isEmpty else {
                out.append("{}")
                return
            }
            out.append("{\n")
            let keys = dictionary.keys.sorted {
                $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
            }
            for (index, key) in keys.enumerated() {
                pad(indent + 1, into: &out)
                writeString(key, into: &out)
                out.append(": ")
                try write(dictionary[key] ?? NSNull(), indent: indent + 1, into: &out)
                out.append(index == keys.count - 1 ? "\n" : ",\n")
            }
            pad(indent, into: &out)
            out.append("}")
        case let array as [Any]:
            guard !array.isEmpty else {
                out.append("[]")
                return
            }
            out.append("[\n")
            for (index, item) in array.enumerated() {
                pad(indent + 1, into: &out)
                try write(item, indent: indent + 1, into: &out)
                out.append(index == array.count - 1 ? "\n" : ",\n")
            }
            pad(indent, into: &out)
            out.append("]")
        case let string as String:
            writeString(string, into: &out)
        case is NSNull:
            out.append("null")
        case let number as NSNumber:
            writeNumber(number, into: &out)
        default:
            throw QuantaError("The notebook contains a value that is not JSON: \(type(of: value))")
        }
    }

    private static func pad(_ indent: Int, into out: inout String) {
        out.append(String(repeating: " ", count: indent))
    }

    private static func writeNumber(_ number: NSNumber, into out: inout String) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            out.append(number.boolValue ? "true" : "false")
            return
        }
        switch String(cString: number.objCType) {
        case "f", "d":
            out.append(formatDouble(number.doubleValue))
        default:
            out.append(number.stringValue)
        }
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value.magnitude >= 0x1p53, value.magnitude < 1e16 {
            return String(format: "%.0f", value) + ".0"
        }
        return value.description
    }

    private static func writeString(_ string: String, into out: inout String) {
        out.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}
