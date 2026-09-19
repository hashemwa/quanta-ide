import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var newlineOffsets: [Int] = []
    private var indexedLength = -1
    private var renderedDigits = 0
    private var renderedSize: CGFloat = 0

    private static let minimumDigits = 3

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged), name: NSText.didChangeNotification,
            object: textView)
        refreshMetrics()
    }

    private var numberSize: CGFloat { max(10, EditorTheme.fontSize - 1) }

    private var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: numberSize, weight: .regular)
    }

    func refreshMetrics() {
        let content = (textView?.string ?? "") as NSString
        let digits = max(Self.minimumDigits,
                         String(lineNumber(forCharacterAt: content.length, in: content)).count)
        let size = numberSize
        guard digits != renderedDigits || size != renderedSize else { return }
        renderedDigits = digits
        renderedSize = size
        let widest = NSAttributedString(string: String(repeating: "0", count: digits),
                                        attributes: [.font: numberFont])
        ruleThickness = ceil(widest.size().width) + DS.Space.s * 2
        needsDisplay = true
    }

    @objc private func textChanged() {
        indexedLength = -1
        refreshMetrics()
    }

    private func lineNumber(forCharacterAt charStart: Int, in content: NSString) -> Int {
        if indexedLength != content.length {
            var offsets: [Int] = []
            var chars = [unichar](repeating: 0, count: content.length)
            content.getCharacters(&chars, range: NSRange(location: 0, length: content.length))
            for (i, c) in chars.enumerated() where c == 10 { offsets.append(i) }
            newlineOffsets = offsets
            indexedLength = content.length
        }
        var lo = 0, hi = newlineOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if newlineOffsets[mid] < charStart { lo = mid + 1 } else { hi = mid }
        }
        return lo + 1
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()

        guard let tv = textView,
              let layoutManager = tv.layoutManager,
              let container = tv.textContainer else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let content = tv.string as NSString
        let inset = tv.textContainerInset.height
        let relativePoint = convert(NSPoint.zero, from: tv)

        if content.length == 0 {
            drawNumber(1, atY: relativePoint.y + inset, height: 16, attrs: attrs)
            return
        }

        let visibleRect = tv.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charStart = layoutManager.characterIndexForGlyph(at: glyphRange.location)

        var lineNumber = lineNumber(forCharacterAt: charStart, in: content)
        let startsAtLineBegin = charStart == 0 || content.character(at: charStart - 1) == 10
        if !startsAtLineBegin { lineNumber += 1 }

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true)
            let charRange = layoutManager.characterRange(forGlyphRange: effectiveRange,
                                                         actualGlyphRange: nil)
            let isLineStart = charRange.location == 0
                || content.character(at: charRange.location - 1) == 10
            if isLineStart {
                drawNumber(lineNumber,
                           atY: lineRect.minY + relativePoint.y + inset,
                           height: lineRect.height, attrs: attrs)
                lineNumber += 1
            }
            glyphIndex = NSMaxRange(effectiveRange)
        }

        if layoutManager.extraLineFragmentTextContainer != nil {
            let r = layoutManager.extraLineFragmentRect
            drawNumber(lineNumber, atY: r.minY + relativePoint.y + inset,
                       height: r.height, attrs: attrs)
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat,
                            attrs: [NSAttributedString.Key: Any]) {
        let s = NSAttributedString(string: "\(number)", attributes: attrs)
        let size = s.size()
        let x = ruleThickness - size.width - DS.Space.s
        s.draw(at: NSPoint(x: x, y: y + (height - size.height) / 2.0))
    }
}
