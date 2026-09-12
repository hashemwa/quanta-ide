import AppKit
import Combine
import SwiftUI

final class ScrollActivityMonitor: ObservableObject {
    static let shared = ScrollActivityMonitor()

    private(set) var isLiveScrolling = false
    @Published private(set) var settled = 0
    private var quietWorkItem: DispatchWorkItem?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.beginActivity()
        }
        center.addObserver(forName: NSScrollView.didLiveScrollNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.beginActivity()
        }
    }

    private func beginActivity() {
        isLiveScrolling = true
        quietWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isLiveScrolling = false
            self.settled &+= 1
        }
        quietWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

struct ScrollAwareHover: ViewModifier {
    @Binding var hovering: Bool
    @ObservedObject private var monitor = ScrollActivityMonitor.shared
    @State private var lastKnown = false

    func body(content: Content) -> some View {
        content
            .onHover { value in
                lastKnown = value
                if !monitor.isLiveScrolling, hovering != value { hovering = value }
            }
            .onChange(of: monitor.settled) { _, _ in
                if hovering != lastKnown { hovering = lastKnown }
            }
    }
}

extension View {
    func scrollAwareHover(_ hovering: Binding<Bool>) -> some View {
        modifier(ScrollAwareHover(hovering: hovering))
    }
}
