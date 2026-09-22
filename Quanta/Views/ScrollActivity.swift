import AppKit
import Combine
import SwiftUI

final class ScrollActivityMonitor: ObservableObject {
    static let shared = ScrollActivityMonitor()

    @Published private(set) var isLiveScrolling = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.beginActivity()
        }
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.endActivity()
        }
    }

    private func beginActivity() {
        guard !isLiveScrolling else { return }
        isLiveScrolling = true
    }

    private func endActivity() {
        guard isLiveScrolling else { return }
        isLiveScrolling = false
    }
}

struct ScrollAwareHover: ViewModifier {
    @Binding var hovering: Bool
    @ObservedObject private var monitor = ScrollActivityMonitor.shared

    func body(content: Content) -> some View {
        content
            .onHover { value in
                if !monitor.isLiveScrolling, hovering != value { hovering = value }
            }
            .allowsHitTesting(!monitor.isLiveScrolling)
            .onChange(of: monitor.isLiveScrolling) { _, active in
                if active, hovering { hovering = false }
            }
    }
}

extension View {
    func scrollAwareHover(_ hovering: Binding<Bool>) -> some View {
        modifier(ScrollAwareHover(hovering: hovering))
    }
}
