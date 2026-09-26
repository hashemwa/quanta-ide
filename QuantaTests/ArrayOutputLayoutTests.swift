import AppKit
import SwiftUI
import Vision
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
        for width in [180.0, 280.0, 440.0] {
            let hosting = NSHostingView(rootView: NDArrayView(payload: array)
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
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("array-fixed-\(Int(width)).png"))
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:]).perform([recognition])
            let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            for label in labels {
                XCTAssertTrue(lines.contains { normalized($0).contains(normalized(label)) },
                              "Array statistic is not readable on one line: \(label); rendered lines: \(lines)")
            }
        }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "−", with: "-")
    }
}
