import AppKit
import XCTest
@testable import Quanta

@MainActor
final class PlotExportTests: XCTestCase {
    func testJPEGInputIsEncodedAsPNG() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8,
            pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let image = try XCTUnwrap(NSImage(data: jpeg))
        let png = try PlotImageExport.pngData(image: image, original: jpeg)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 8)
        XCTAssertEqual(decoded.pixelsHigh, 6)
    }

    func testMissingPlotRendererReportsExportFailure() {
        let controller = PlotlyController()
        controller.savePNG()
        XCTAssertNotNil(controller.exportError)
        XCTAssertFalse(controller.isExporting)
        controller.copyPNG()
        XCTAssertNotNil(controller.exportError)
        XCTAssertFalse(controller.isExporting)
    }
}
