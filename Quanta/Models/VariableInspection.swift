import Foundation

struct VariableNode: Identifiable {
    let id: String
    let name: String
    let type: String
    let value: String
    let children: [VariableNode]?
    init(_ dict: [String: Any], path: String = "root") {
        id = path
        name = dict["name"] as? String ?? ""
        type = dict["type"] as? String ?? ""
        value = dict["value"] as? String ?? ""
        let nested = dict["children"] as? [[String: Any]] ?? []
        children = nested.isEmpty ? nil : nested.enumerated().map { VariableNode($0.element, path: "\(path)/\($0.offset)") }
    }
}
