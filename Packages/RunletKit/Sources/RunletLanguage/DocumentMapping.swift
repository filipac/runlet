import Foundation

/// Maps between the editor's text and the PHP document PHPantom sees.
///
/// Snippets usually omit `<?php`. For the language service only, a synthetic opening tag
/// is added on its own line, so every editor line maps to the LSP line below it and
/// columns never shift. Positions use UTF-16 code units on both sides (the LSP default and
/// NSString's native unit), so multibyte text maps without conversion.
public struct ScratchDocumentMapping: Sendable, Equatable {
    public static let syntheticPrefix = "<?php\n"
    /// Appended after tagless snippets so an omitted final semicolon (accepted by the runner)
    /// is not reported as a syntax error. It sits after all editor text, so no position moves.
    public static let syntheticSuffix = "\n;"

    public let hasSyntheticTag: Bool
    /// `@var` declarations for variables a driver injects (e.g. `$app`), so the language
    /// service can type them. Only used for tagless scratch snippets; never shown in the editor.
    public let declarations: [String: String]

    public init(editorText: String, declarations: [String: String] = [:]) {
        hasSyntheticTag = !Self.startsWithOpenTag(editorText)
        let valid = declarations.filter { name, type in
            name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
                && type.range(of: #"^[A-Za-z_\\][A-Za-z0-9_\\|\[\]<>, ]*$"#, options: .regularExpression) != nil
        }
        self.declarations = hasSyntheticTag ? valid : [:]
    }

    private var prefix: String {
        var text = Self.syntheticPrefix
        for name in declarations.keys.sorted() {
            let type = declarations[name]!
            let qualified = type.first.map { $0.isUppercase || $0 == "\\" } == true && !type.hasPrefix("\\") && type.contains("\\") ? "\\" + type : type
            text += "/** @var \(qualified) $\(name) */\n"
        }
        return text
    }

    public static func startsWithOpenTag(_ text: String) -> Bool {
        let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        return trimmed.hasPrefix("<?php") || trimmed.hasPrefix("<?=")
    }

    public var lineOffset: Int { hasSyntheticTag ? 1 + declarations.count : 0 }

    public func lspText(for editorText: String) -> String {
        hasSyntheticTag ? prefix + editorText + Self.syntheticSuffix : editorText
    }

    public func toLSP(_ position: LSPPosition) -> LSPPosition {
        LSPPosition(line: position.line + lineOffset, character: position.character)
    }

    /// Positions inside the synthetic tag line clamp to the start of the editor text.
    public func toEditor(_ position: LSPPosition) -> LSPPosition {
        if position.line < lineOffset { return LSPPosition(line: 0, character: 0) }
        return LSPPosition(line: position.line - lineOffset, character: position.character)
    }

    public func toEditor(_ range: LSPRange) -> LSPRange {
        LSPRange(start: toEditor(range.start), end: toEditor(range.end))
    }

    public func toEditor(_ edit: LSPTextEdit) -> LSPTextEdit {
        LSPTextEdit(range: toEditor(edit.range), newText: edit.newText)
    }
}

/// Converts between UTF-16 offsets and line/character positions for one text snapshot.
public struct TextLineIndex: Sendable {
    private let lineStarts: [Int]
    public let length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A {
                if !previousWasCR { starts.append(offset) } else { starts[starts.count - 1] = offset }
                previousWasCR = false
            } else if unit == 0x0D {
                starts.append(offset)
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        lineStarts = starts
        length = offset
    }

    public var lineCount: Int { lineStarts.count }

    public func position(at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, length))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return LSPPosition(line: low, character: clamped - lineStarts[low])
    }

    public func offset(of position: LSPPosition) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < lineStarts.count else { return length }
        let start = lineStarts[position.line]
        let nextStart = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] : length
        // Clamp to the end of the line (excluding its newline).
        var lineEnd = nextStart
        if position.line + 1 < lineStarts.count { lineEnd -= 1 }
        return min(start + max(0, position.character), max(start, lineEnd))
    }

    public func nsRange(of range: LSPRange) -> NSRange {
        let start = offset(of: range.start)
        let end = max(start, offset(of: range.end))
        return NSRange(location: start, length: end - start)
    }
}

/// Converts LSP snippet syntax into plain text, since the editor inserts plain text.
/// Returns the text and the UTF-16 cursor offset (`$0`, else the first placeholder).
public enum SnippetText {
    public static func plain(_ snippet: String) -> (text: String, cursor: Int?) {
        var output = ""
        var outputUTF16 = 0
        var finalCursor: Int?
        var firstStop: Int?
        var characters = Array(snippet)
        var index = 0

        func append(_ string: String) {
            output += string
            outputUTF16 += string.utf16.count
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, "$}\\".contains(characters[index + 1]) {
                append(String(characters[index + 1]))
                index += 2
                continue
            }
            guard character == "$", index + 1 < characters.count else {
                append(String(character))
                index += 1
                continue
            }
            let next = characters[index + 1]
            if next.isNumber {
                var end = index + 1
                while end < characters.count, characters[end].isNumber { end += 1 }
                let number = Int(String(characters[(index + 1)..<end])) ?? 0
                if number == 0 { finalCursor = outputUTF16 } else if firstStop == nil { firstStop = outputUTF16 }
                index = end
                continue
            }
            if next == "{" {
                var end = index + 2
                var number = ""
                while end < characters.count, characters[end].isNumber { number.append(characters[end]); end += 1 }
                if !number.isEmpty {
                    let stop = Int(number) ?? 0
                    if stop == 0 { finalCursor = outputUTF16 } else if firstStop == nil { firstStop = outputUTF16 }
                    if end < characters.count, characters[end] == ":" {
                        // Placeholder text up to the matching brace (nested placeholders flattened).
                        var depth = 1
                        var placeholder: [Character] = []
                        end += 1
                        while end < characters.count {
                            if characters[end] == "\\", end + 1 < characters.count { placeholder.append(characters[end + 1]); end += 2; continue }
                            if characters[end] == "{" { depth += 1 }
                            if characters[end] == "}" { depth -= 1; if depth == 0 { break } }
                            placeholder.append(characters[end])
                            end += 1
                        }
                        let inner = plain(String(placeholder)).text
                        append(inner)
                        index = end + 1
                        continue
                    }
                    if end < characters.count, characters[end] == "|" {
                        // Choice: take the first option.
                        var choice = ""
                        end += 1
                        while end < characters.count, characters[end] != "," && characters[end] != "|" { choice.append(characters[end]); end += 1 }
                        while end < characters.count, characters[end] != "}" { end += 1 }
                        append(choice)
                        index = end + 1
                        continue
                    }
                    if end < characters.count, characters[end] == "}" {
                        index = end + 1
                        continue
                    }
                }
            }
            append("$")
            index += 1
        }
        characters.removeAll()
        return (output, finalCursor ?? firstStop)
    }
}
