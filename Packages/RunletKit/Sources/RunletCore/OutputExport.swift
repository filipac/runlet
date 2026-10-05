import Foundation

/// Values as JSON or PHP source, for copying a table row or a value. Built from the bounded
/// `ValueNode` tree: what the runner left out stays out, and nothing runs.
public enum ValueExport {
    /// JSON for a list of keyed fields (a table row), keys in order.
    public static func json(fields: [ValueTable.Field], pretty: Bool = true) -> String {
        var output = ""
        writeObject(fields.map { ($0.key, $0.value) }, into: &output, indent: 0, pretty: pretty)
        return output
    }

    /// JSON for one value. Lists (keys 0…n-1) become arrays, other arrays and objects become
    /// objects of their entries.
    public static func json(_ node: ValueNode, pretty: Bool = true) -> String {
        var output = ""
        writeJSON(node, into: &output, indent: 0, pretty: pretty)
        return output
    }

    /// A PHP array literal for a list of keyed fields (a table row), keys kept.
    public static func php(fields: [ValueTable.Field]) -> String {
        var output = ""
        writePHPArray(fields.map { ($0.key, $0.keyType, $0.value) }, isList: false, into: &output, indent: 0)
        return output
    }

    /// PHP source for one value: scalars as literals, arrays as `[...]`, objects as an array
    /// of their properties preceded by a `/* Class */` comment.
    public static func php(_ node: ValueNode) -> String {
        var output = ""
        writePHP(node, into: &output, indent: 0)
        return output
    }

    // MARK: JSON

    private static func writeJSON(_ node: ValueNode, into output: inout String, indent: Int, pretty: Bool) {
        switch node.type {
        case .null:
            output += "null"
        case .bool:
            output += node.scalar == "true" ? "true" : "false"
        case .int:
            output += node.scalar ?? "0"
        case .float:
            let scalar = node.scalar ?? "0"
            output += Double(scalar)?.isFinite == true ? scalar : quoted(scalar)
        case .string:
            output += quoted(node.displayString)
        case .enum:
            if let backing = node.backingValue {
                output += Int(backing) != nil ? backing : quoted(backing)
            } else {
                output += quoted(node.scalar ?? "")
            }
        case .array:
            let entries = node.entries ?? []
            if isList(entries) {
                writeArray(entries.map(\.value), into: &output, indent: indent, pretty: pretty)
            } else {
                writeObject(entries.map { ($0.key, $0.value) }, into: &output, indent: indent, pretty: pretty)
            }
        case .object:
            if let entries = node.entries, node.repeated != true {
                // #307: a Values collection's items are a list.
                if node.collection != nil, isList(entries) {
                    writeArray(entries.map(\.value), into: &output, indent: indent, pretty: pretty)
                    return
                }
                writeObject(entries.map { ($0.key, $0.value) }, into: &output, indent: indent, pretty: pretty)
            } else {
                output += quoted(node.inlineSummary)
            }
        case .closure, .resource, .unknown:
            output += quoted(node.inlineSummary)
        }
    }

    private static func writeArray(_ values: [ValueNode], into output: inout String, indent: Int, pretty: Bool) {
        guard !values.isEmpty else { output += "[]"; return }
        output += "["
        for (index, value) in values.enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            writeJSON(value, into: &output, indent: indent + 1, pretty: pretty)
        }
        output += pretty ? "\n" + String(repeating: "  ", count: indent) + "]" : "]"
    }

    private static func writeObject(_ fields: [(String, ValueNode)], into output: inout String, indent: Int, pretty: Bool) {
        guard !fields.isEmpty else { output += "{}"; return }
        output += "{"
        for (index, field) in fields.enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            output += quoted(field.0) + (pretty ? ": " : ":")
            writeJSON(field.1, into: &output, indent: indent + 1, pretty: pretty)
        }
        output += pretty ? "\n" + String(repeating: "  ", count: indent) + "}" : "}"
    }

    private static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    private static func isList(_ entries: [ValueNode.Entry]) -> Bool {
        entries.enumerated().allSatisfy { index, entry in entry.keyType == "int" && entry.key == String(index) }
    }

    // MARK: PHP

    private static func writePHP(_ node: ValueNode, into output: inout String, indent: Int) {
        switch node.type {
        case .null:
            output += "null"
        case .bool:
            output += node.scalar == "true" ? "true" : "false"
        case .int:
            output += node.scalar ?? "0"
        case .float:
            output += node.scalar ?? "0.0"
        case .string:
            output += phpString(node.displayString)
        case .enum:
            output += "\\\(node.className ?? "Enum")::\(node.scalar ?? "")"
        case .array:
            let entries = node.entries ?? []
            writePHPArray(entries.map { ($0.key, $0.keyType, $0.value) }, isList: isList(entries), into: &output, indent: indent)
        case .object:
            if let entries = node.entries, node.repeated != true {
                output += "/* \(node.className ?? "object") */ "
                // #307: a Values collection's items keep their keys (a list stays a list).
                if node.collection != nil {
                    writePHPArray(entries.map { ($0.key, $0.keyType, $0.value) }, isList: isList(entries), into: &output, indent: indent)
                    return
                }
                writePHPArray(entries.map { ($0.key, "string", $0.value) }, isList: false, into: &output, indent: indent)
            } else {
                output += "null /* \(node.inlineSummary.replacingOccurrences(of: "*/", with: "* /")) */"
            }
        case .closure, .resource, .unknown:
            output += "null /* \(node.inlineSummary.replacingOccurrences(of: "*/", with: "* /")) */"
        }
    }

    private static func writePHPArray(_ entries: [(String, String, ValueNode)], isList: Bool, into output: inout String, indent: Int) {
        guard !entries.isEmpty else { output += "[]"; return }
        output += "[\n"
        for (key, keyType, value) in entries {
            output += String(repeating: "    ", count: indent + 1)
            if !isList {
                output += (keyType == "int" ? key : phpString(key)) + " => "
            }
            writePHP(value, into: &output, indent: indent + 1)
            output += ",\n"
        }
        output += String(repeating: "    ", count: indent) + "]"
    }

    /// A single-quoted PHP string literal.
    public static func phpString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// Markdown building blocks for Copy Output as Markdown and Save Output As….
public enum MarkdownText {
    /// A fenced code block whose fence is longer than any backtick run in `text`.
    public static func fence(_ text: String, language: String = "") -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let marker = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return "\(marker)\(language)\n\(body)\n\(marker)"
    }

    /// A Markdown table with the row keys as the first column. Pipes are escaped and line
    /// breaks become `<br>`; at most `maxRows` rows, with a note for the rest.
    public static func table(_ table: ValueTable, maxRows: Int = 200) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        var lines = ["| # | " + table.columns.map(cell).joined(separator: " | ") + " |"]
        lines.append("|" + String(repeating: " --- |", count: table.columns.count + 1))
        for (index, row) in table.rows.prefix(maxRows).enumerated() {
            lines.append("| " + cell(table.rowKeys[index]) + " | " + row.map { cell($0.text) }.joined(separator: " | ") + " |")
        }
        let hidden = max(0, table.rows.count - maxRows) + table.omittedRows
        if hidden > 0 { lines.append("\n_\(hidden) more rows not shown._") }
        return lines.joined(separator: "\n")
    }

    /// A value as a table when it is tabular, else as a fenced dump.
    public static func value(_ node: ValueNode) -> String {
        if let table = ValueTable.make(from: node) {
            return Self.table(table)
        }
        return fence(node.plainText())
    }

    /// Text safe inside a Markdown heading or paragraph (no accidental formatting).
    public static func inline(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_[]#<>|".contains(character) { output.append("\\") }
            output.append(character == "\n" ? " " : character)
        }
        return output
    }
}

/// Web links in plain output (Plain and Raw modes, stdout and stderr cards).
public enum OutputLinks {
    /// Text longer than this (UTF-16 units) is not scanned, so huge output stays fast.
    public static let maxScannedLength = 512 * 1024

    /// `http`, `https`, and `mailto` URLs written out with their scheme, in order.
    public static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let source = text as NSString
        guard source.length > 0, source.length <= maxScannedLength, text.contains(":"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
            // Only links written with their scheme: "example.com" alone stays text.
            guard source.substring(with: match.range).lowercased().hasPrefix(scheme + ":") else { return nil }
            return (match.range, url)
        }
    }
}
