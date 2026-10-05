import SwiftUI

typealias ViewLayoutObserver = @MainActor @Sendable (String, CGRect) -> Void

private struct ViewLayoutObserverKey: EnvironmentKey {
    static let defaultValue: ViewLayoutObserver? = nil
}

extension EnvironmentValues {
    var viewLayoutObserver: ViewLayoutObserver? {
        get { self[ViewLayoutObserverKey.self] }
        set { self[ViewLayoutObserverKey.self] = newValue }
    }
}

private struct ObservedViewLayout: ViewModifier {
    let identifier: String
    @Environment(\.viewLayoutObserver) private var observer

    @ViewBuilder
    func body(content: Content) -> some View {
        if let observer {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                observer(identifier, $0)
            }
        } else {
            content
        }
    }
}

extension View {
    func reportLayout(_ identifier: String) -> some View {
        modifier(ObservedViewLayout(identifier: identifier))
    }
}
