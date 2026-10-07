import Foundation

enum EditorTextRange {
    static func isSameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.count == rhs.utf16.count && lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length
            && range.length <= length - range.location
    }

    static func isCharacterBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset >= 0, offset <= source.length else { return false }
        return offset == source.length || source.rangeOfComposedCharacterSequence(at: offset).location == offset
    }
}
