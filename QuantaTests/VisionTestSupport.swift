import CoreML
import Vision
import XCTest

enum VisionTestSupport {
    static func textRecognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let cpu = try XCTUnwrap(MLComputeDevice.allComputeDevices.first {
            if case .cpu = $0 { return true }
            return false
        }, "CPU text recognition is unavailable")
        request.setComputeDevice(cpu, for: .main)
        return request
    }
}
