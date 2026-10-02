import Foundation

/// The text and caret the editor inserts when a completion item is accepted.
///
/// PHPantom 0.10.0 sends snippet syntax for calls even though the client declines snippets:
/// `split(${1:\$pattern})$0` (required parameters as placeholders), `count()$0`, `array_map()$0`
/// (built-in functions carry no parameter list), `DateTimeZone(${1:\$timezone})$0` after `new`.
/// The editor has no tab stops, so a call is inserted as `name()` with no placeholder text: the
/// caret goes between the parentheses when the callable takes parameters (signature help then
/// shows them) and after `)` when it takes none. Other items (properties, variables, class names,
/// keywords) insert their text as before.
public struct CompletionInsertion: Sendable, Equatable {
    public var text: String
    /// UTF-16 offset of the caret within `text`.
    public var cursor: Int
    /// The caret is inside a call's argument list, so signature help should open.
    public var showsSignatureHelp: Bool
    /// The caret was put between empty parentheses without knowing whether the callable takes
    /// parameters (PHPantom labels built-in functions and classes without a parameter list).
    /// The editor moves it past `)` when signature help reports no parameters.
    public var parametersUnknown: Bool

    public init(text: String, cursor: Int, showsSignatureHelp: Bool, parametersUnknown: Bool = false) {
        self.text = text
        self.cursor = cursor
        self.showsSignatureHelp = showsSignatureHelp
        self.parametersUnknown = parametersUnknown
    }

    /// - Parameter followingCharacter: the character right after the replaced text. When it is
    ///   `(`, a call inserts only its name and reuses the existing argument list.
    public static func make(item: CompletionItem, followingCharacter: Character?) -> CompletionInsertion {
        let snippet = item.textEdit?.newText ?? item.insertText ?? item.label
        if let call = call(snippet: snippet, item: item, followingCharacter: followingCharacter) { return call }
        let plain = SnippetText.plain(snippet)
        return CompletionInsertion(
            text: plain.text,
            cursor: plain.cursor ?? (plain.text as NSString).length,
            showsSignatureHelp: plain.text.hasSuffix("(") || (plain.cursor != nil && plain.text.contains("("))
        )
    }

    /// `name(…)` items: methods, functions, constructors, and classes after `new`. Keyword and
    /// snippet items (kinds 14, 15) are not calls even when they read like one (`fn(…) =>`).
    private static func call(snippet: String, item: CompletionItem, followingCharacter: Character?) -> CompletionInsertion? {
        guard ![14, 15].contains(item.kind ?? 0) else { return nil }
        let dropped = SnippetText.plain(snippet, placeholders: .drop)
        let text = dropped.text as NSString
        let open = text.range(of: "(").location
        guard open != NSNotFound, open > 0 else { return nil }
        let name = text.substring(to: open)
        guard isName(name) else { return nil }
        if followingCharacter == "(" {
            return CompletionInsertion(text: name, cursor: open, showsSignatureHelp: false)
        }
        let close = matchingParenthesis(in: text, from: open) ?? text.length
        let arguments = text.substring(with: NSRange(location: open + 1, length: close - open - 1))
        let suffix = close < text.length ? text.substring(from: close + 1) : ""
        // Dropped placeholders leave only their separators (`replace(, , )`); clear those.
        let kept = arguments.trimmingCharacters(in: CharacterSet(charactersIn: ", \t\r\n")).isEmpty ? "" : arguments
        let tabStop = dropped.cursor.flatMap { $0 > open && $0 <= close ? $0 : nil }
        // A tab stop between the parentheses means required parameters; otherwise the label's
        // parameter list (`trim($characters = ...)`, `upper()`) tells, when there is one.
        let hasParameters: Bool? = tabStop != nil ? true : labelParameters(item.label).map { !$0.isEmpty }
        let inside = hasParameters ?? true
        let afterClose = open + 1 + (kept as NSString).length + 1
        let cursor = inside ? (kept.isEmpty ? open + 1 : tabStop ?? open + 1) : afterClose
        return CompletionInsertion(
            text: name + "(" + kept + ")" + suffix,
            cursor: cursor,
            showsSignatureHelp: inside,
            parametersUnknown: hasParameters == nil
        )
    }

    /// A PHP (optionally namespace-qualified) name.
    private static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || $0 == "\\" || $0.value > 127 || CharacterSet.alphanumerics.contains($0) }
    }

    /// The text between the label's outer parentheses, or nil when the label has none.
    private static func labelParameters(_ label: String) -> String? {
        guard let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close else { return nil }
        return label[label.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
    }

    private static func matchingParenthesis(in text: NSString, from open: Int) -> Int? {
        var depth = 0
        for index in open..<text.length {
            switch text.character(at: index) {
            case 40: depth += 1
            case 41:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}
