import AppKit
import SwiftUI
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

    func testEachThemeHandsAppKitItsOwnColorObjects() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        AppTheme.current = .neutral
        let neutral = DS.Chrome.nsColor(.canvas)
        XCTAssertEqual(hex(neutral, in: dark), "#000000")
        AppTheme.current = .classic
        let classic = DS.Chrome.nsColor(.canvas)
        XCTAssertEqual(classic, .windowBackgroundColor)
        XCTAssertFalse(neutral === classic)
    }

    func testOpenNotebookRecolorsInPlaceWhenTheThemeChanges() throws {
        let app = AppState.shared
        let previous = app.theme
        app.theme = .classic
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: "x = 1")], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let hosting = NSHostingView(rootView: NotebookScrollView(document: document, notebook: notebook,
                                                                  scrollRequest: nil)
            .themeScope()
            .frame(width: 900, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        addTeardownBlock {
            window.close()
            app.theme = previous
        }
        settle(hosting)
        let scroll = try XCTUnwrap(first(NSScrollView.self, in: hosting))
        let editor = try XCTUnwrap(first(NSTextView.self, in: hosting))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let classicBackground = scroll.backgroundColor
        XCTAssertEqual(classicBackground, .windowBackgroundColor)

        app.theme = .neutral
        settle(hosting)
        XCTAssertFalse(scroll.backgroundColor === classicBackground)
        XCTAssertEqual(hex(scroll.backgroundColor, in: dark), "#000000")
        XCTAssertEqual(hex(try XCTUnwrap(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                                         as? NSColor), in: dark), "#CFCFCF")
        let cardFill = try XCTUnwrap(cardLayer(in: hosting)?.backgroundColor)
        XCTAssertEqual(hex(try XCTUnwrap(NSColor(cgColor: cardFill))), "#151515")
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

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.first(type, in: $0) }.first
    }

    private func cardLayer(in view: NSView) -> CALayer? {
        if String(describing: Swift.type(of: view)).contains("CardView"),
           let layer = view.layer, layer.borderWidth > 0, layer.backgroundColor?.alpha == 1 {
            return layer
        }
        return view.subviews.lazy.compactMap { self.cardLayer(in: $0) }.first
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
