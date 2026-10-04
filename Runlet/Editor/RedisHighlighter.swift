import AppKit
import RunletCore

/// Syntax colours for Redis tabs (#190), from `RedisScript.tokenize`: commands (and a
/// container's subcommand) as keywords, option words as constants, quoted strings, numbers,
/// and `#` comments. Keys and values keep the text colour. It reuses the PHP theme's palette.
enum RedisHighlighter {
    static func tokenize(_ string: NSString) -> [PHPHighlighter.Token] {
        RedisScript.tokenize(string).compactMap { token in
            let kind: PHPTokenKind? = switch token.kind {
            case .command: .keyword
            case .unknownCommand: .function
            case .option: .constant
            case .string: .string
            case .number: .number
            case .comment: .comment
            case .argument: nil
            }
            return kind.map { PHPHighlighter.Token(range: token.range, kind: $0) }
        }
    }
}
