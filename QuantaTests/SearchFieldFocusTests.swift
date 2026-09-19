import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class SearchFieldFocusTests: XCTestCase {
    private final class State {
        var text = ""
        var handled = 0
    }

    private func coordinator(_ state: State) -> SearchField.Coordinator {
        SearchField.Coordinator(SearchField(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            prompt: "Search", focusRequest: 1,
            handledFocusRequest: Binding(get: { state.handled }, set: { state.handled = $0 }),
            onSubmit: {}))
    }

    private func drainFocusRequest() async {
        let pending = expectation(description: "Focus request processed")
        DispatchQueue.main.async { pending.fulfill() }
        await fulfillment(of: [pending], timeout: 2)
    }

    func testFocusWaitsForWindowAttachment() async {
        let state = State()
        let coordinator = coordinator(state)
        let field = FocusableSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.onWindowAvailable = { [weak field] in
            if let field { coordinator.scheduleFocus(field) }
        }
        coordinator.scheduleFocus(field)
        await drainFocusRequest()
        XCTAssertEqual(state.handled, 0)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        await drainFocusRequest()
        XCTAssertEqual(state.handled, 1)
        XCTAssertTrue(window.firstResponder === field || window.firstResponder === field.currentEditor())
    }

    func testConsumedFocusDoesNotStealFromAnotherInput() async {
        let state = State()
        state.handled = 1
        let coordinator = coordinator(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let other = NSTextView(frame: NSRect(x: 0, y: 30, width: 200, height: 50))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        coordinator.scheduleFocus(field)
        await drainFocusRequest()
        XCTAssertTrue(window.firstResponder === other)
    }

    func testClosingSearchCancelsPendingFocus() async {
        let state = State()
        let coordinator = coordinator(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        coordinator.scheduleFocus(field)
        SearchField.dismantleNSView(field, coordinator: coordinator)
        await drainFocusRequest()
        XCTAssertEqual(state.handled, 0)
    }
}
