import AppKit
import CoreML
import Vision
import XCTest

enum VisionTestSupport {
    @MainActor
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

    static func textRecognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision2
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        let cpu = try XCTUnwrap(MLComputeDevice.allComputeDevices.first {
            if case .cpu = $0 { return true }
            return false
        }, "CPU text recognition is unavailable")
        request.setComputeDevice(cpu, for: .main)
        return request
    }
}
