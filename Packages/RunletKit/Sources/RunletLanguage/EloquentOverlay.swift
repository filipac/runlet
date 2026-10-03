import Foundation

/// In-memory copies of a project's Eloquent model files, adjusted so PHPantom 0.10.0 reads two
/// common model shapes it otherwise gets wrong (#55):
///
/// - **Relations with only a native return type.** `public function posts(): HasMany` with
///   `return $this->hasMany(Post::class)` is read as a bare `HasMany`, so `$user->posts` is a
///   collection of the base `Model`. PHPantom infers the related model from the body only when
///   the method declares no return type. The copy blanks the native return type (same width, so
///   no line or column moves), and PHPantom's own body inference names the related model.
/// - **`casts()` arrays without a trailing comma.** PHPantom drops the last entry of a `casts()`
///   return array when no comma follows it. The copy adds that comma.
///
/// The copies are opened in the language server under the files' own URIs, so they replace the
/// disk version for that session only. Nothing is written anywhere: the user's files are read and
/// never modified, and PHP treats both changes as equivalent code. A copy is only made when one of
/// the two shapes is present and PHPantom's inference would name the same relation the method
/// declares; any file the scanner cannot read with confidence is left alone.
public enum EloquentOverlay {
    /// Relation builder methods in the order PHPantom 0.10.0 tries them when it infers a relation
    /// from a method body (`RELATIONSHIP_METHOD_FQN_MAP`), with the relation class each one names.
    static let relationBuilders: [(method: String, relation: String)] = [
        ("hasOne", "HasOne"),
        ("hasMany", "HasMany"),
        ("belongsTo", "BelongsTo"),
        ("belongsToMany", "BelongsToMany"),
        ("morphOne", "MorphOne"),
        ("morphMany", "MorphMany"),
        ("morphTo", "MorphTo"),
        ("morphToMany", "MorphToMany"),
        ("morphedByMany", "MorphToMany"),
        ("hasManyThrough", "HasManyThrough"),
        ("hasOneThrough", "HasOneThrough"),
    ]

    /// Relation types whose related model PHPantom can take from the body (`MorphTo` has none).
    static let relationTypes: Set<String> = Set(relationBuilders.map(\.relation)).subtracting(["MorphTo"])

    /// Limits for scanning a project, so a large tree cannot delay the language server.
    public struct Limits: Sendable {
        public var maxFilesVisited = 5_000
        public var maxFileBytes = 1_000_000
        public var maxDocuments = 1_000
        public init() {}
    }

    /// One adjusted copy: the file's URI (built from the workspace root as given, like the root
    /// URI sent to the server) and the text to open in its place.
    public struct Document: Sendable, Equatable {
        public var uri: String
        public var text: String
    }

    // MARK: Project scan

    /// Adjusted copies for every PHP file under the project's own autoload directories that needs
    /// one. Composer `autoload.psr-4` directories inside the root are scanned (or `app/` when there
    /// are none); `vendor`, `node_modules`, and hidden directories are skipped.
    public static func documents(root: URL, limits: Limits = Limits()) -> [Document] {
        let fm = FileManager.default
        var visited = 0
        var documents: [Document] = []
        var seen = Set<String>()
        for directory in sourceDirectories(root: root) {
            let base = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fm.enumerator(atPath: base.path) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                let fromRoot = directory.isEmpty ? relative : directory + "/" + relative
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    if name.hasPrefix(".") || name == "vendor" || name == "node_modules" || fromRoot == "storage" || fromRoot == "bootstrap/cache" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard !name.hasPrefix("."), name.hasSuffix(".php") else { continue }
                visited += 1
                if visited > limits.maxFilesVisited || documents.count >= limits.maxDocuments { return documents }
                guard ((enumerator.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0) <= limits.maxFileBytes else { continue }
                guard let data = fm.contents(atPath: base.path + "/" + relative),
                      mightNeedOverlay(data),
                      let source = String(data: data, encoding: .utf8),
                      let text = overlay(for: source)
                else { continue }
                // Built from the root as given (not a resolved path), like the root URI the server gets.
                let uri = root.appendingPathComponent(fromRoot, isDirectory: false).absoluteString
                guard seen.insert(uri).inserted else { continue }
                documents.append(Document(uri: uri, text: text))
            }
        }
        return documents
    }

    /// Project-relative autoload directories: Composer `autoload.psr-4` entries that stay inside
    /// the root and outside `vendor`, or `app` when composer.json names none.
    static func sourceDirectories(root: URL) -> [String] {
        var directories: [String] = []
        if let data = FileManager.default.contents(atPath: root.appendingPathComponent("composer.json").path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let psr4 = (json["autoload"] as? [String: Any])?["psr-4"] as? [String: Any] {
            for value in psr4.values {
                let paths = (value as? [String]) ?? ((value as? String).map { [$0] } ?? [])
                for path in paths {
                    let normalized = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }.joined(separator: "/")
                    guard !normalized.hasPrefix("/"), !path.hasPrefix("/"), !normalized.split(separator: "/").contains(".."),
                          normalized.split(separator: "/").first != "vendor" else { continue }
                    directories.append(normalized)
                }
            }
        }
        if directories.isEmpty { directories = ["app"] }
        // Drop nested duplicates ("" covers everything, "app" covers "app/Models").
        var unique: [String] = []
        for directory in Set(directories).sorted(by: { $0.count < $1.count }) {
            if unique.contains(where: { $0.isEmpty || directory == $0 || directory.hasPrefix($0 + "/") }) { continue }
            unique.append(directory)
        }
        return unique
    }

    /// Cheap byte search before a file is decoded and scanned.
    static func mightNeedOverlay(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return prefilterNeedles.contains { needle in
                needle.withUnsafeBytes { memmem(base, buffer.count, $0.baseAddress, needle.count) != nil }
            }
        }
    }

    private static let prefilterNeedles: [[UInt8]] = (["function casts"] + relationTypes.sorted()).map { Array($0.utf8) }

    // MARK: Single file

    /// The adjusted text for one PHP file, or nil when it needs no change (or cannot be scanned
    /// with confidence).
    public static func overlay(for source: String) -> String? {
        var bytes = Array(source.utf8)
        guard let scan = PHPSourceScan(bytes) else { return nil }
        var blanks: [Range<Int>] = []
        var insertions: [Int] = []
        for method in scan.methods() {
            if method.name == "casts", method.parameters.isEmpty {
                if let comma = castsTrailingCommaPosition(method, scan: scan) { insertions.append(comma) }
            } else if let returnType = relationReturnTypeToBlank(method, scan: scan) {
                blanks.append(returnType)
            }
        }
        guard !blanks.isEmpty || !insertions.isEmpty else { return nil }
        for range in blanks {
            for index in range { bytes[index] = UInt8(ascii: " ") }
        }
        for position in insertions.sorted(by: >) {
            bytes.insert(UInt8(ascii: ","), at: position)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The byte range from the `:` to the end of the native return type, when the method returns
    /// only a relation type, has no `@return` docblock tag, and PHPantom's body inference would
    /// name the same relation with a related model.
    static func relationReturnTypeToBlank(_ method: PHPSourceScan.Method, scan: PHPSourceScan) -> Range<Int>? {
        guard let returnType = method.returnType, let colon = method.returnTypeColon else { return nil }
        let typeName = scan.text(returnType)
        let shortName = typeName.split(separator: "\\").last.map(String.init) ?? typeName
        guard relationTypes.contains(shortName),
              typeName.range(of: #"^\\?([A-Za-z_][A-Za-z0-9_]*\\)*[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              let body = method.body
        else { return nil }
        if let docComment = scan.docComment(before: method.declarationStart), hasReturnTag(docComment) { return nil }
        // Mirror PHPantom's `infer_relationship_from_body`: the first builder (in its order) whose
        // `$this->name(` appears anywhere in the raw body text, with a `::class` first argument.
        let bodyText = scan.text(body)
        for builder in relationBuilders {
            let needle = "$this->\(builder.method)("
            guard let call = bodyText.range(of: needle) else { continue }
            guard builder.relation == shortName else { return nil }
            let arguments = bodyText[call.upperBound...]
            guard let close = arguments.firstIndex(of: ")") else { return nil }
            let first = arguments[..<close].split(separator: ",", omittingEmptySubsequences: false).first ?? ""
            guard let classToken = first.range(of: "::class") else { return nil }
            let className = first[..<classToken.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            guard !className.isEmpty else { return nil }
            return colon..<returnType.upperBound
        }
        return nil
    }

    static func hasReturnTag(_ docComment: String) -> Bool {
        docComment.range(of: #"@(phpstan-|psalm-)?return\b"#, options: .regularExpression) != nil
    }

    /// Where to insert a comma in a `casts()` method's returned array, mirroring how PHPantom
    /// finds it (the first `return`, then the first `[` after it). Nil when the last entry already
    /// has a trailing comma, the array is empty, or the array cannot be located with confidence.
    static func castsTrailingCommaPosition(_ method: PHPSourceScan.Method, scan: PHPSourceScan) -> Int? {
        guard let body = method.body else { return nil }
        let bodyBytes = scan.bytes[body]
        guard let returnOffset = firstIndex(of: Array("return".utf8), in: bodyBytes, of: scan.bytes),
              let open = scan.bytes[returnOffset..<body.upperBound].firstIndex(of: UInt8(ascii: "[")),
              scan.isCode(open),
              let close = scan.matchingBracket(open, until: body.upperBound)
        else { return nil }
        guard let last = scan.lastSignificantCode(before: close, after: open) else { return nil }
        let character = scan.bytes[last]
        guard character != UInt8(ascii: ","), character != UInt8(ascii: "[") else { return nil }
        return last + 1
    }

    static func firstIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>, of buffer: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = haystack.startIndex
        while index <= haystack.endIndex - needle.count {
            if PHPSourceScan.matches(buffer, needle, at: index) { return index }
            index += 1
        }
        return nil
    }
}

/// A small PHP source scanner: it separates code from comments, strings, heredocs, and inline
/// HTML, and finds method declarations. It is deliberately conservative: input it cannot scan to
/// the end (an unterminated string or comment) is rejected.
struct PHPSourceScan {
    let bytes: [UInt8]
    /// `bytes` with every comment, string body, and inline HTML byte replaced by a space (line
    /// breaks kept), so offsets match `bytes` and only code remains.
    private(set) var code: [UInt8]
    /// Byte ranges of `/** … */` comments.
    private(set) var docComments: [Range<Int>] = []

    struct Method {
        var name: String
        var declarationStart: Int
        var parameters: Range<Int>
        var returnTypeColon: Int?
        var returnType: Range<Int>?
        /// From `{` through `}`; nil for abstract or interface methods.
        var body: Range<Int>?
    }

    init?(_ bytes: [UInt8]) {
        self.bytes = bytes
        code = bytes
        guard scan() else { return nil }
    }

    /// Offsets inside comments, string bodies, heredocs, and inline HTML.
    private var blanked = IndexSet()

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    func isCode(_ index: Int) -> Bool { !blanked.contains(index) }

    private mutating func blank(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        for index in range where bytes[index] != 0x0A && bytes[index] != 0x0D { code[index] = 0x20 }
        blanked.insert(integersIn: range)
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80
    }

    private func hasPrefix(_ prefix: StaticString, at index: Int) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        let start = prefix.utf8Start
        for offset in 0..<count where bytes[index + offset] != start[offset] { return false }
        return true
    }

    /// Whether `buffer` holds `needle` at `index` (no allocation).
    static func matches(_ buffer: [UInt8], _ needle: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= buffer.count else { return false }
        for offset in needle.indices where buffer[index + offset] != needle[offset] { return false }
        return true
    }

    /// Walks the file once, blanking everything that is not code. Returns false when a comment,
    /// string, or heredoc does not end.
    private mutating func scan() -> Bool {
        let count = bytes.count
        var index = 0
        var inPHP = false
        while index < count {
            if !inPHP {
                let start = index
                while index < count, !(hasPrefix("<?php", at: index) || hasPrefix("<?=", at: index)) { index += 1 }
                blank(start..<index)
                guard index < count else { return true }
                index += hasPrefix("<?php", at: index) ? 5 : 3
                inPHP = true
                continue
            }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "?") where hasPrefix("?>", at: index):
                index += 2
                inPHP = false
            case UInt8(ascii: "#") where !hasPrefix("#[", at: index), UInt8(ascii: "/") where hasPrefix("//", at: index):
                let start = index
                while index < count, bytes[index] != 0x0A, !hasPrefix("?>", at: index) { index += 1 }
                blank(start..<index)
            case UInt8(ascii: "/") where hasPrefix("/*", at: index):
                let start = index
                index += 2
                while index < count, !hasPrefix("*/", at: index) { index += 1 }
                guard index < count else { return false }
                index += 2
                if hasPrefix("/**", at: start), index - start > 4 { docComments.append(start..<index) }
                blank(start..<index)
            case UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"):
                let start = index
                index += 1
                while index < count, bytes[index] != byte {
                    index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard index < count else { return false }
                blank(start + 1..<index)
                index += 1
            case UInt8(ascii: "<") where hasPrefix("<<<", at: index):
                guard let end = heredocEnd(from: index) else { return false }
                blank(index + 3..<end)
                index = end
            default:
                index += 1
            }
        }
        return true
    }

    /// The offset just after a heredoc/nowdoc's closing identifier.
    private func heredocEnd(from start: Int) -> Int? {
        var index = start + 3
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
        let quote = index < bytes.count && (bytes[index] == UInt8(ascii: "'") || bytes[index] == UInt8(ascii: "\"")) ? bytes[index] : nil
        if quote != nil { index += 1 }
        let nameStart = index
        while index < bytes.count, Self.isIdentifier(bytes[index]) { index += 1 }
        guard index > nameStart else { return nil }
        let name = Array(bytes[nameStart..<index])
        if let quote {
            guard index < bytes.count, bytes[index] == quote else { return nil }
            index += 1
        }
        // The closing identifier starts a line (after optional indentation) and is not followed
        // by another identifier character.
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: 0x0A) else { return nil }
            var cursor = newline + 1
            while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
            if Self.matches(bytes, name, at: cursor),
               cursor + name.count == bytes.count || !Self.isIdentifier(bytes[cursor + name.count]) {
                return cursor + name.count
            }
            index = newline + 1
        }
        return nil
    }

    // MARK: Structure

    private func skipSpace(_ index: Int, limit: Int? = nil) -> Int {
        var index = index
        let limit = limit ?? code.count
        while index < limit, code[index] == 0x20 || code[index] == 0x09 || code[index] == 0x0A || code[index] == 0x0D { index += 1 }
        return index
    }

    /// The closing bracket matching the opener at `open` (`(`, `[`, or `{`), counting only code.
    func matchingBracket(_ open: Int, until limit: Int? = nil) -> Int? {
        let opener = code[open]
        let closer: UInt8
        switch opener {
        case UInt8(ascii: "("): closer = UInt8(ascii: ")")
        case UInt8(ascii: "["): closer = UInt8(ascii: "]")
        case UInt8(ascii: "{"): closer = UInt8(ascii: "}")
        default: return nil
        }
        var depth = 0
        var index = open
        let limit = limit ?? code.count
        while index < limit {
            if code[index] == opener, !blanked.contains(index) {
                depth += 1
            } else if code[index] == closer, !blanked.contains(index) {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The last code byte that is not whitespace in `after+1 ..< before`.
    func lastSignificantCode(before: Int, after: Int) -> Int? {
        var index = before - 1
        while index > after {
            let byte = code[index]
            if !(byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) { return index }
            index -= 1
        }
        return nil
    }

    /// Text of the `/** … */` comment that directly precedes `start` (only whitespace between).
    func docComment(before start: Int) -> String? {
        guard let comment = docComments.last(where: { $0.upperBound <= start }) else { return nil }
        let between = bytes[comment.upperBound..<start]
        guard between.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return nil }
        return text(comment)
    }

    /// Method and function declarations, in source order.
    func methods() -> [Method] {
        var result: [Method] = []
        let keyword = Array("function".utf8)
        var index = 0
        while index + keyword.count <= code.count {
            defer { index += 1 }
            guard code[index] == keyword[0], Self.matches(code, keyword, at: index),
                  index == 0 || !Self.isIdentifier(code[index - 1]),
                  index + keyword.count < code.count, !Self.isIdentifier(code[index + keyword.count]),
                  !blanked.contains(index)
            else { continue }
            var cursor = skipSpace(index + keyword.count)
            if cursor < code.count, code[cursor] == UInt8(ascii: "&") { cursor = skipSpace(cursor + 1) }
            let nameStart = cursor
            while cursor < code.count, Self.isIdentifier(code[cursor]) { cursor += 1 }
            guard cursor > nameStart else { continue } // a closure
            let name = String(decoding: code[nameStart..<cursor], as: UTF8.self)
            cursor = skipSpace(cursor)
            guard cursor < code.count, code[cursor] == UInt8(ascii: "("), let close = matchingBracket(cursor) else { continue }
            var method = Method(name: name, declarationStart: declarationStart(beforeKeyword: index), parameters: cursor + 1..<close)
            let parameterText = String(decoding: code[cursor + 1..<close], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if parameterText.isEmpty { method.parameters = cursor + 1..<cursor + 1 }
            cursor = skipSpace(close + 1)
            if cursor < code.count, code[cursor] == UInt8(ascii: ":") {
                method.returnTypeColon = cursor
                let typeStart = skipSpace(cursor + 1)
                var typeEnd = typeStart
                while typeEnd < code.count, Self.isIdentifier(code[typeEnd]) || code[typeEnd] == UInt8(ascii: "\\") || code[typeEnd] == UInt8(ascii: "?") || code[typeEnd] == UInt8(ascii: "|") || code[typeEnd] == UInt8(ascii: "&") || code[typeEnd] == UInt8(ascii: "(") || code[typeEnd] == UInt8(ascii: ")") {
                    typeEnd += 1
                }
                guard typeEnd > typeStart else { continue }
                method.returnType = typeStart..<typeEnd
                cursor = skipSpace(typeEnd)
            }
            if cursor < code.count, code[cursor] == UInt8(ascii: "{"), let end = matchingBracket(cursor) {
                method.body = cursor..<end + 1
            }
            result.append(method)
        }
        return result
    }

    /// Start of a declaration: before its modifiers and attributes.
    private func declarationStart(beforeKeyword keyword: Int) -> Int {
        var start = keyword
        while true {
            var cursor = start - 1
            while cursor >= 0, code[cursor] == 0x20 || code[cursor] == 0x09 || code[cursor] == 0x0A || code[cursor] == 0x0D { cursor -= 1 }
            guard cursor >= 0 else { return start }
            if code[cursor] == UInt8(ascii: "]") {
                // An attribute group `#[ … ]`.
                var depth = 0
                var open = cursor
                while open >= 0 {
                    if code[open] == UInt8(ascii: "]") { depth += 1 }
                    if code[open] == UInt8(ascii: "[") { depth -= 1; if depth == 0 { break } }
                    open -= 1
                }
                guard open > 0, code[open - 1] == UInt8(ascii: "#") else { return start }
                start = open - 1
                continue
            }
            guard Self.isIdentifier(code[cursor]) else { return start }
            var wordStart = cursor
            while wordStart > 0, Self.isIdentifier(code[wordStart - 1]) { wordStart -= 1 }
            let word = String(decoding: code[wordStart...cursor], as: UTF8.self).lowercased()
            guard ["public", "protected", "private", "static", "final", "abstract", "readonly"].contains(word) else { return start }
            start = wordStart
        }
    }
}
