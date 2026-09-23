import AppKit
import XCTest
@testable import Quanta

@MainActor
final class ThemeTests: XCTestCase {
    private let defaults = QuantaDefaults.store
    private var savedTheme: Any?
    private var savedMode: Any?
    private var savedCurrent = AppTheme.current
    private var savedAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        savedTheme = defaults.object(forKey: AppTheme.key)
        savedMode = defaults.object(forKey: AppearanceMode.key)
        savedCurrent = AppTheme.current
        savedAppearance = NSApp.appearance
    }

    override func tearDown() {
        defaults.set(savedTheme, forKey: AppTheme.key)
        defaults.set(savedMode, forKey: AppearanceMode.key)
        AppTheme.current = savedCurrent
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    func testAppearanceModeAppliesToTheWholeAppOnlyWhenForced() {
        XCTAssertNil(AppearanceMode.system.appearance)
        XCTAssertEqual(AppearanceMode.light.appearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.appearance?.name, .darkAqua)
        let app = AppState()
        app.appearanceMode = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        app.appearanceMode = .system
        XCTAssertNil(NSApp.appearance)
    }

    func testThemeAndAppearanceDefaultAndPersistIndependently() {
        defaults.removeObject(forKey: AppTheme.key)
        defaults.removeObject(forKey: AppearanceMode.key)
        let app = AppState()
        XCTAssertEqual(app.theme, AppTheme.standard)
        XCTAssertEqual(app.appearanceMode, .system)

        app.theme = .classic
        app.appearanceMode = .dark
        XCTAssertEqual(AppTheme.current, .classic)
        let reloaded = AppState()
        XCTAssertEqual(reloaded.theme, .classic)
        XCTAssertEqual(reloaded.appearanceMode, .dark)
    }

    func testClassicUsesSystemColorsAndLeavesChromeToThePlatform() {
        XCTAssertNil(AppTheme.classic.palette)
        XCTAssertEqual(DS.Chrome.color(.canvas, theme: .classic, dark: true), .windowBackgroundColor)
        XCTAssertEqual(DS.Chrome.color(.editor, theme: .classic, dark: false), .textBackgroundColor)
        XCTAssertEqual(DS.Chrome.color(.accent, theme: .classic, dark: false), .controlAccentColor)
        for role in [DS.Chrome.Role.sidebar, .backdrop, .rule] {
            XCTAssertEqual(DS.Chrome.color(role, theme: .classic, dark: true), .clear)
        }
    }

    func testNeutralResolvesEveryRoleFromItsPalette() {
        XCTAssertEqual(hex(DS.Chrome.color(.canvas, theme: .neutral, dark: true)), "#000000")
        XCTAssertEqual(hex(DS.Chrome.color(.editor, theme: .neutral, dark: false)), "#FFFFFF")
        XCTAssertEqual(hex(DS.Chrome.color(.sidebar, theme: .neutral, dark: true)), "#0C0C0C")
        XCTAssertEqual(hex(DS.Chrome.color(.accent, theme: .neutral, dark: true)), "#CFCFCF")
        XCTAssertEqual(hex(DS.Chrome.color(.rule, theme: .neutral, dark: false)), "#E6E6E6")
    }

    func testDynamicColorsFollowTheCurrentThemeWithoutBeingReassigned() throws {
        let canvas = DS.Chrome.nsColor(.canvas)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        AppTheme.current = .neutral
        XCTAssertEqual(hex(canvas, in: dark), "#000000")
        AppTheme.current = .classic
        XCTAssertEqual(hex(canvas, in: dark), hex(.windowBackgroundColor, in: dark))
    }

    func testTerminalColorsComeFromTheTheme() throws {
        let neutral = DS.Chrome.terminalTheme(.neutral, dark: true)
        XCTAssertEqual(neutral["background"], "#0C0C0C")
        XCTAssertEqual(neutral["foreground"], "#CFCFCF")
        XCTAssertEqual(neutral["selectionBackground"], "#2C2C2C")
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(DS.Chrome.terminalTheme(.classic, dark: false)["background"],
                       hex(.textBackgroundColor, in: light))
    }

    func testEditorsKeepNativeSelectionInClassic() {
        let native = NSTextView().selectedTextAttributes
        let textView = NSTextView()
        AppTheme.current = .neutral
        EditorTheme.style(textView)
        XCTAssertEqual(textView.selectedTextAttributes[.backgroundColor] as? NSColor,
                       DS.Chrome.nsColor(.highlight))
        AppTheme.current = .classic
        EditorTheme.style(textView)
        XCTAssertEqual(textView.selectedTextAttributes[.backgroundColor] as? NSColor,
                       native[.backgroundColor] as? NSColor)
        XCTAssertEqual(textView.selectedTextAttributes[.foregroundColor] as? NSColor,
                       native[.foregroundColor] as? NSColor)
    }

    private func hex(_ color: NSColor, in appearance: NSAppearance? = nil) -> String {
        var result = ""
        (appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB) ?? .black
            result = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                            Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        return result
    }
}
