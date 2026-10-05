import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class ArrayOutputLayoutTests: XCTestCase {
    func testArrayStatisticsRemainReadableAtSplitPaneWidths() throws {
        let array = try XCTUnwrap(NDArrayPayload(dict: [
            "shape": [10000, 200], "dtype": "float64",
            "stats": ["min": -0.00000123, "max": 12345678.9, "mean": 12345.6, "std": 3210.3],
            "series": [0, 1, 0.5, 0.8, 0.2], "text": "array([0, 1])",
        ]))
        let labels = ["ndarray \(array.shapeLabel)", array.dtype]
            + ["min", "max", "mean", "std"].map { "\($0) \(NDArrayView.compact(array.stats[$0]!))" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-output-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var singleLineSizes: [String: CGSize] = [:]
        for width in [1000.0, 180.0, 280.0, 440.0] {
            let layout = LayoutTestSupport()
            let hosting = NSHostingView(rootView: NDArrayView(payload: array)
                .environment(\.viewLayoutObserver) { layout.frames[$0] = $1 }
                .environment(\.monoFontSize, 12)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Space.m)
                .background(Color(nsColor: .textBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 16, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            defer { window.close() }
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                hosting.layoutSubtreeIfNeeded()
            }
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, width + 16, accuracy: 1)
            XCTAssertGreaterThan(size.height, 20)
            hosting.setFrameSize(size)
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                hosting.layoutSubtreeIfNeeded()
            }
            let bitmap = try LayoutTestSupport.snapshot(of: hosting)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("array-fixed-\(Int(width)).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "array-\(Int(width))"
            add(attachment)
            var frames: [CGRect] = []
            for label in labels {
                let frame = try XCTUnwrap(layout.frames["pill.\(label)"], "Missing statistic: \(label)")
                XCTAssertGreaterThan(frame.width, 0, label)
                XCTAssertGreaterThan(frame.height, 0, label)
                XCTAssertGreaterThanOrEqual(frame.minX, 0, label)
                XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX, label)
                XCTAssertGreaterThanOrEqual(frame.minY, 0, label)
                XCTAssertLessThanOrEqual(frame.maxY, hosting.bounds.maxY, label)
                if width == 1000 {
                    singleLineSizes[label] = frame.size
                } else {
                    let ideal = try XCTUnwrap(singleLineSizes[label])
                    XCTAssertEqual(frame.width, ideal.width, accuracy: 1, "Truncated statistic: \(label)")
                    XCTAssertEqual(frame.height, ideal.height, accuracy: 1, "Wrapped statistic: \(label)")
                }
                for previous in frames {
                    XCTAssertFalse(frame.intersects(previous), "Overlapping statistic: \(label)")
                }
                frames.append(frame)
            }
        }
    }
}
