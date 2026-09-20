import AppKit
import SwiftUI
import XCTest
@testable import Quanta

@MainActor
final class PlotAppearanceSettingsTests: XCTestCase {
    func testPlotAppearancePreferenceDefaultsOnAndPersists() {
        let key = "QuantaAdaptsPlotTheme"
        let defaults = QuantaDefaults.store
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.removeObject(forKey: key)
        let app = AppState()
        XCTAssertTrue(app.adaptsPlotTheme)
        app.adaptsPlotTheme = false
        XCTAssertFalse(AppState().adaptsPlotTheme)
        app.adaptsPlotTheme = true
        XCTAssertTrue(AppState().adaptsPlotTheme)
    }

    func testStatusSymbolsContrastAgainstNativeSurfaces() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for foreground in [NSColor(DS.StatusColors.warning), NSColor(DS.StatusColors.success)] {
                    for background in [NSColor.windowBackgroundColor, .controlBackgroundColor, .textBackgroundColor] {
                        let first = luminance(foreground)
                        let second = luminance(background)
                        XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 3,
                                                    "Insufficient symbol contrast in \(name.rawValue)")
                    }
                }
            }
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { XCTFail("Color did not resolve"); return 0 }
        func linear(_ value: CGFloat) -> Double {
            let component = Double(value)
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
