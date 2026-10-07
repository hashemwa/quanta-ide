import Combine
import Foundation

final class OutputPresentation: ObservableObject {
    static let preferenceKey = "QuantaEnhancedDataOutputs"
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    @Published private(set) var usesEnhancedDataOutputs: Bool

    init(defaults: UserDefaults = QuantaDefaults.store) {
        self.defaults = defaults
        usesEnhancedDataOutputs = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func setEnhancedDataOutputs(_ enabled: Bool) {
        guard usesEnhancedDataOutputs != enabled else { return }
        usesEnhancedDataOutputs = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        onChange?()
    }
}

extension CellOutput {
    var enhancedDataText: String? {
        switch kind {
        case .dataFrame(let payload): return payload.text.isEmpty ? payload.tsv : payload.text
        case .ndarray(let payload): return payload.text.isEmpty ? "ndarray(shape=(\(payload.shapeLabel)), dtype=\(payload.dtype))" : payload.text
        case .jsonTree(let payload):
            if !payload.text.isEmpty { return payload.text }
            guard let data = try? JSONSerialization.data(withJSONObject: payload.value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return payload.summary }
            return String(decoding: data, as: UTF8.self)
        case .objectCard(let payload): return payload.text.isEmpty ? payload.title : payload.text
        default: return nil
        }
    }
}
