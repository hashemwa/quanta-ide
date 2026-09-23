import AppKit

enum EditorTheme {
    static var fontSize: CGFloat = 13
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    static var lineHeight: CGFloat {
        let f = font
        return ceil(f.ascender - f.descender + f.leading)
    }
    static let text = DS.Chrome.nsColor(.text)
    static let background = DS.Chrome.nsColor(.editor)
    private static let nativeSelection = NSTextView().selectedTextAttributes

    static func style(_ textView: NSTextView) {
        textView.insertionPointColor = DS.Chrome.nsColor(.accent)
        textView.selectedTextAttributes = AppTheme.current.palette == nil ? nativeSelection : [
            .backgroundColor: DS.Chrome.nsColor(.highlight),
            .foregroundColor: DS.Chrome.nsColor(.highlightedText),
        ]
        textView.needsDisplay = true
    }

    static let keyword = syntax(.keyword)
    static let string = syntax(.string)
    static let comment = syntax(.comment)
    static let number = syntax(.number)
    static let builtin = syntax(.builtin)
    static let defName = syntax(.definition)
    static let decorator = syntax(.decorator)

    static func syntaxHex(_ kind: PythonHighlighter.Kind, dark: Bool) -> String {
        let pair = syntaxRGB(kind)
        return String(format: "#%06X", dark ? pair.1 : pair.0)
    }

    private static func syntax(_ kind: PythonHighlighter.Kind) -> NSColor {
        let pair = syntaxRGB(kind)
        return dyn(pair.0, pair.1)
    }

    private static func syntaxRGB(_ kind: PythonHighlighter.Kind) -> (Int, Int) {
        switch kind {
        case .keyword: (0x9B2393, 0xFC5FA3)
        case .string: (0xC41A16, 0xFC6A5D)
        case .comment: (0x5D6C79, 0x6C7986)
        case .number: (0x1C00CF, 0xD0BF69)
        case .builtin: (0x6C36A9, 0xA167E6)
        case .definition: (0x0F68A0, 0x41A1C0)
        case .decorator: (0x947100, 0xFD8F3F)
        }
    }

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
