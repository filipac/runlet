import AppKit
import RunletCore

/// Syntax colours for SQL tabs (#35), from the shared SQL lexer (`SQLScript`): keywords,
/// strings, comments, numbers, placeholders, function names, and identifiers (quoted
/// identifiers, and the table after FROM, JOIN, INTO, UPDATE, or TABLE, `schema.table`
/// included). Plain column names keep the text colour. It reuses the PHP theme's token kinds,
/// so both languages share one palette.
enum SQLHighlighter {
    /// Keywords after which a bare word names a table.
    private static let tableKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "EXISTS"]

    static func tokenize(_ string: NSString) -> [PHPHighlighter.Token] {
        let tokens = SQLScript.tokenize(string)
        var result: [PHPHighlighter.Token] = []
        result.reserveCapacity(tokens.count)
        // A table name may follow; a table name just ended (a `.` continues it).
        var expectsTable = false
        var afterTable = false
        for (index, token) in tokens.enumerated() {
            var kind: PHPTokenKind?
            switch token.kind {
            case .keyword:
                let word = string.substring(with: token.range).uppercased()
                kind = SQLScript.constants.contains(word) ? .constant : .keyword
                expectsTable = tableKeywords.contains(word)
                afterTable = false
            case .word, .quotedIdentifier:
                let next = tokens[(index + 1)...].first { $0.kind != .comment }
                if token.kind == .word, let next, next.kind == .punctuation, string.substring(with: next.range) == "(" {
                    kind = .function
                } else if expectsTable || token.kind == .quotedIdentifier {
                    kind = .type
                }
                afterTable = expectsTable
                expectsTable = false
            case .punctuation where string.substring(with: token.range) == "." && afterTable:
                expectsTable = true
                afterTable = false
            case .comment:
                kind = .comment
            default:
                switch token.kind {
                case .string: kind = .string
                case .number: kind = .number
                case .placeholder: kind = .variable
                default: kind = nil
                }
                expectsTable = false
                afterTable = false
            }
            if let kind { result.append(PHPHighlighter.Token(range: token.range, kind: kind)) }
        }
        return result
    }
}
