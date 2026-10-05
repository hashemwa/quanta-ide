import AppKit
import XCTest

@MainActor
final class LayoutTestSupport {
    var frames: [String: CGRect] = [:]

    static func snapshot(of view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(bounds.width * scale)),
            pixelsHigh: Int(ceil(bounds.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
        view.displayIgnoringOpacity(bounds, in: context)
        return bitmap
    }
}
