import CoreML
import Vision
import XCTest

enum VisionTestSupport {
    static func textRecognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        for (stage, devices) in try request.supportedComputeStageDevices {
            let cpu = try XCTUnwrap(devices.first {
                if case .cpu = $0 { return true }
                return false
            }, "CPU text recognition is unavailable for \(stage.rawValue)")
            request.setComputeDevice(cpu, for: stage)
        }
        return request
    }
}
