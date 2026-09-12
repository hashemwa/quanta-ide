import AppKit

enum EditorTheme {
    static var fontSize: CGFloat = 13
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    static var lineHeight: CGFloat {
        let f = font
        return ceil(f.ascender - f.descender + f.leading)
    }
    static let text = NSColor.textColor
    static let background = NSColor.textBackgroundColor

    static let keyword = dyn(0x9B2393, 0xFC5FA3)
    static let string = dyn(0xC41A16, 0xFC6A5D)
    static let comment = dyn(0x5D6C79, 0x6C7986)
    static let number = dyn(0x1C00CF, 0xD0BF69)
    static let builtin = dyn(0x6C36A9, 0xA167E6)
    static let defName = dyn(0x0F68A0, 0x41A1C0)
    static let decorator = dyn(0x947100, 0xFD8F3F)

    private static func dyn(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1)
    }
}
