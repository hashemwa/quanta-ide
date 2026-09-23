import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class PaneTabsTests: XCTestCase {
    private let width: CGFloat = 280

    func testSidebarPanesAreNativeTabsWithNamesTooltipsAndFullWidth() throws {
        let segments = SidebarPane.allCases.map {
            IconSegmentedControl<SidebarPane>.Segment(value: $0, icon: $0.icon, title: $0.title, help: $0.help)
        }
        let control = try host(IconSegmentedControl(segments: segments, selection: .constant(.files))
            .tint(Color(white: 0.8)))
        XCTAssertEqual(control.segmentCount, SidebarPane.allCases.count)
        for (index, pane) in SidebarPane.allCases.enumerated() {
            XCTAssertEqual(control.toolTip(forSegment: index), pane.help)
            XCTAssertEqual(control.image(forSegment: index)?.accessibilityDescription, pane.title)
        }
        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertNil(control.selectedSegmentBezelColor)
        if #available(macOS 27.0, *) { XCTAssertEqual(control.role, .tabs) }
        if #available(macOS 26.0, *) { XCTAssertEqual(control.frame.width, width, accuracy: 1) }
    }

    func testBottomPanesStayCompactTextTabs() throws {
        let segments = BottomPane.allCases.map {
            IconSegmentedControl<BottomPane>.Segment(value: $0, title: $0.rawValue, help: $0.rawValue)
        }
        let control = try host(HStack {
            IconSegmentedControl(segments: segments, selection: .constant(.terminal), fillsWidth: false)
            Spacer()
        })
        XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) },
                       BottomPane.allCases.map(\.rawValue))
        XCTAssertEqual(control.selectedSegment, 1)
        XCTAssertLessThan(control.frame.width, width)
    }

    private func host(_ view: some View) throws -> NSSegmentedControl {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: DS.Bar.primary))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: DS.Bar.primary),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        addTeardownBlock { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        return try XCTUnwrap(segmentedControl(in: hosting))
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }
}
