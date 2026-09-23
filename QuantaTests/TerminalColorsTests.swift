import AppKit
import XCTest
@testable import Quanta

@MainActor
final class TerminalColorsTests: XCTestCase {
    func testTerminalTakesItsColorsFromTheSystem() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(TerminalSession.colors(dark: false)["background"], hex(.textBackgroundColor, in: light))
        XCTAssertEqual(TerminalSession.colors(dark: true)["background"], hex(.textBackgroundColor, in: dark))
        XCTAssertEqual(TerminalSession.colors(dark: true)["foreground"], hex(.textColor, in: dark))
        XCTAssertEqual(TerminalSession.colors(dark: false)["selectionBackground"],
                       hex(.selectedTextBackgroundColor, in: light))
    }

    private func hex(_ color: NSColor, in appearance: NSAppearance) -> String {
        var result = ""
        appearance.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB) ?? .black
            result = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                            Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        return result
    }
}
