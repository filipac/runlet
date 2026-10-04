import Foundation

/// A snippet shared with a project as `<project>/.runlet/snippets/<name>.php` (or `.sql`,
/// #130), so a team can keep it in git. Loading one only reads the file; it never runs.
public struct ProjectSnippet: Sendable, Hashable, Identifiable {
    /// The file's path.
    public var id: String
    /// `@label` from the metadata docblock (or comment), or the file name without its extension.
    public var label: String
    /// `@description` from the metadata docblock.
    public var description: String?
    /// The file without its opening `<?php` tag and without the metadata docblock.
    public var code: String
    public var fileURL: URL
    /// `@input` declarations from the metadata docblock and any other docblock before the
    /// code (#14). Opening a snippet with inputs asks for their values first.
    public var inputs: SnippetInputSet
    /// The `@input` declarations (the text after `@input`) of the metadata docblock, which is
    /// not part of `code`; `personalCode` keeps them.
    public var metadataInputDeclarations: [String]
    /// `.sql` files are SQL snippets (#130) and open as SQL tabs; they have no inputs.
    public var language: TabLanguage
    /// `@connection` of an SQL snippet's metadata (#149): the connection it opens on, by name
    /// (`.named`), or `.saved` with the `(saved)` marker. nil for PHP snippets.
    public var connection: SQLConnectionReference?

    public init(id: String, label: String, description: String?, code: String, fileURL: URL, inputs: SnippetInputSet = .none, metadataInputDeclarations: [String] = [], language: TabLanguage = .php, connection: SQLConnectionReference? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.code = code
        self.fileURL = fileURL
        self.inputs = inputs
        self.metadataInputDeclarations = metadataInputDeclarations
        self.language = language
        self.connection = language.usesDatabaseConnection ? connection : nil
    }

    /// The code for a personal copy: `code`, after a docblock with the metadata docblock's
    /// `@input` lines, so the copy asks for the same inputs.
    public var personalCode: String {
        guard !metadataInputDeclarations.isEmpty else { return code }
        // #207: a MongoDB snippet keeps its inputs as `// @input` lines.
        if language == .mongodb { return MongoSnippets.code(header: DatabaseSnippetHeader(inputs: metadataInputDeclarations), body: code) }
        let lines = metadataInputDeclarations.map { " * @input " + $0.replacingOccurrences(of: "*/", with: "* /") }
        return (["/**"] + lines + [" */"]).joined(separator: "\n") + (code.isEmpty ? "" : "\n" + code)
    }
}

/// Reads and writes project snippets in `<project>/.runlet/snippets/*.php` and `*.sql`.
///
/// File format (compatible with Tinkerwell's `.tinkerwell/snippets`):
///
/// ```php
/// <?php
/// /**
///  * @label Recent users
///  * @description The ten newest accounts
///  */
///
/// User::latest()->take(10)->get();
/// ```
///
/// The metadata docblock is the first docblock, before any code (whitespace and other
/// comments may precede it), and only counts when it has `@label`, `@description`, or
/// `@input` (#14, see `SnippetInputs`).
///
/// SQL snippets (#130) are `.sql` files whose metadata is the first run of `--` comment lines
/// (a blank line ends it) or a `/** … */` docblock, before any statement:
///
/// ```sql
/// -- @label Recent users
/// -- @description The ten newest accounts
///
/// SELECT * FROM users ORDER BY created_at DESC LIMIT 10;
/// ```
///
/// They have no `@input`s. `@connection` (#149) names the connection the snippet opens on:
///
/// ```sql
/// -- @label Monthly revenue
/// -- @connection reporting
/// ```
///
/// A bare name is a saved connection with that name when the target has one (its own, then
/// one of all targets), else the application's connection with that name. `-- @connection
/// Reporting (saved)` means only a saved connection, and opens on the default connection with
/// a note when there is none. Saving a snippet from an SQL tab writes it.
///
/// Project drivers live directly in `.runlet/` (`*Driver.php`) and are never read from
/// the `snippets/` subfolder.
public enum ProjectSnippets {
    /// The snippets folder, relative to the project root.
    public static let relativeDirectory = ".runlet/snippets"
    /// Files larger than this are skipped.
    public static let maxFileBytes = 1024 * 1024

    public static func directory(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".runlet", isDirectory: true).appendingPathComponent("snippets", isDirectory: true)
    }

    /// Every readable `*.php` and `*.sql` file directly in the snippets folder, sorted by
    /// label. Hidden, unreadable, non-UTF-8, and oversized files are skipped. Never runs anything.
    public static func load(projectRoot: URL) -> [ProjectSnippet] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory(projectRoot: projectRoot), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var snippets: [ProjectSnippet] = []
        for url in entries where ["php", "sql", "mongodb"].contains(url.pathExtension.lowercased()) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes { continue }
            guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes, let contents = String(data: data, encoding: .utf8) else { continue }
            snippets.append(parse(contents, fileURL: url.standardizedFileURL))
        }
        return snippets.sorted { a, b in
            switch a.label.localizedStandardCompare(b.label) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.fileURL.lastPathComponent < b.fileURL.lastPathComponent
            }
        }
    }

    /// Parses one snippet file's contents: a `.sql` file as an SQL snippet, any other as PHP.
    public static func parse(_ contents: String, fileURL: URL) -> ProjectSnippet {
        var text = Substring(contents)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        if TabLanguage.forFile(fileURL) == .sql { return parseSQL(text, fileURL: fileURL) }
        if TabLanguage.forFile(fileURL) == .mongodb { return parseMongo(text, fileURL: fileURL) }

        // Drop the opening tag (and anything before it, which can only be whitespace).
        var rest = text
        let start = text.drop { $0.isWhitespace }
        if start.hasPrefix("<?php") {
            let afterTag = start.dropFirst(5)
            if afterTag.first.map(\.isWhitespace) ?? true { rest = afterTag }
        }

        var label: String?
        var description: String?
        var metadataInputs: [String] = []
        var code = String(rest)
        if let block = metadataBlock(in: rest) {
            label = block.label
            description = block.description
            metadataInputs = block.inputs
            code = String(rest[..<block.range.lowerBound]) + String(rest[block.range.upperBound...])
        }

        let fallback = fileURL.deletingPathExtension().lastPathComponent
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProjectSnippet(
            id: fileURL.path,
            label: trimmedLabel.isEmpty ? fallback : trimmedLabel,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            code: tidy(code),
            fileURL: fileURL,
            inputs: SnippetInputs.parse(declarations: SnippetInputs.declarations(inLeadingCommentsOf: rest)),
            metadataInputDeclarations: metadataInputs
        )
    }

    /// SQL snippets (#130): the metadata comment (or docblock) is dropped from the code.
    private static func parseSQL(_ text: Substring, fileURL: URL) -> ProjectSnippet {
        var label: String?
        var description: String?
        var code = String(text)
        var connection: SQLConnectionReference?
        if let block = metadataBlock(in: text, sql: true) ?? sqlMetadataComment(in: text) {
            label = block.label
            description = block.description
            connection = block.connection.flatMap(parseConnection)
            code = String(text[..<block.range.lowerBound]) + String(text[block.range.upperBound...])
        }
        let fallback = fileURL.deletingPathExtension().lastPathComponent
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProjectSnippet(
            id: fileURL.path,
            label: trimmedLabel.isEmpty ? fallback : trimmedLabel,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            code: tidy(code),
            fileURL: fileURL,
            language: .sql,
            connection: connection
        )
    }

    /// MongoDB snippets (#207): a leading `//` block with `@title`, `@description`,
    /// `@connection`, and `@input` (`DatabaseSnippetHeader`), then one JSON query whose
    /// `{"$input": "name"}` placeholders take the inputs' values (`MongoSnippets.substitute`).
    private static func parseMongo(_ text: Substring, fileURL: URL) -> ProjectSnippet {
        let (inputs, body, header) = MongoSnippets.parse(String(text))
        let fallback = fileURL.deletingPathExtension().lastPathComponent
        let title = header?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = header?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProjectSnippet(
            id: fileURL.path,
            label: title.isEmpty ? fallback : title,
            description: description.isEmpty ? nil : description,
            code: body,
            fileURL: fileURL,
            inputs: inputs,
            metadataInputDeclarations: header?.inputs ?? [],
            language: .mongodb,
            connection: header?.connection.flatMap(parseConnection)
        )
    }

    /// The `(saved)` marker after an `@connection` name: only a saved connection (#149).
    static let savedConnectionMarker = "(saved)"

    /// `reporting` → `.named("reporting")`; `Reporting (saved)` → `.saved(name: "Reporting")`.
    static func parseConnection(_ value: String) -> SQLConnectionReference? {
        var name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var saved = false
        if name.lowercased().hasSuffix(savedConnectionMarker) {
            name = String(name.dropLast(savedConnectionMarker.count)).trimmingCharacters(in: .whitespaces)
            saved = true
        }
        guard !name.isEmpty else { return nil }
        return saved ? .saved(name: name) : .named(name)
    }

    /// The `@connection` value for a reference: an application connection's name, or a saved
    /// connection's with the `(saved)` marker. nil for the default connection.
    static func connectionLine(_ connection: SQLConnectionReference?) -> String? {
        guard let connection = connection?.forSnippet, let name = connection.name else { return nil }
        let value = docblockLine(name)
        guard !value.isEmpty else { return nil }
        if case .saved = connection { return value + " " + savedConnectionMarker }
        return value
    }

    /// The first run of `--` comment lines before any statement, when it carries `@label`,
    /// `@description`, or `@connection` (#149). A blank line or anything that is not a `--`
    /// comment ends the run.
    private static func sqlMetadataComment(in text: Substring) -> MetadataBlock? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let start = index
        var end = index
        var body: [Substring] = []
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[index..<lineEnd].drop { $0 == " " || $0 == "\t" }
            guard line.hasPrefix("--") else { break }
            body.append(line.dropFirst(2))
            end = lineEnd
            index = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        guard !body.isEmpty else { return nil }
        let tags = parseTags(Substring(body.joined(separator: "\n")))
        guard tags.label != nil || tags.description != nil || tags.connection != nil else { return nil }
        return MetadataBlock(range: start..<end, label: tags.label, description: tags.description, inputs: [], connection: tags.connection)
    }

    /// A snippet file: `<?php`, a metadata docblock (when there is a label or description),
    /// a blank line, then the code. `load` reads back the same label, description, and code.
    /// SQL snippets (#130) start with `-- @label` and `-- @description` lines instead, and an
    /// `-- @connection` line (#149) when they have a connection.
    public static func fileContents(label: String, description: String?, code: String, language: TabLanguage = .php, connection: SQLConnectionReference? = nil) -> String {
        if language == .mongodb {
            // #207: `// @title`, `// @description`, `// @connection`; a header the code already has keeps its inputs.
            let (_, body, existing) = MongoSnippets.parse(code)
            let header = DatabaseSnippetHeader(title: docblockLine(label), description: description.map(docblockLine), connection: connectionLine(connection), inputs: existing?.inputs ?? [])
            let text = MongoSnippets.code(header: header, body: body)
            return text.isEmpty ? "" : text + "\n"
        }
        if language == .sql {
            var header: [String] = []
            let label = docblockLine(label)
            let description = docblockLine(description ?? "")
            if !label.isEmpty { header.append("-- @label \(label)") }
            if !description.isEmpty { header.append("-- @description \(description)") }
            if let connection = connectionLine(connection) { header.append("-- @connection \(connection)") }
            let tidied = tidy(code)
            let body = tidied.isEmpty ? "" : tidied + "\n"
            return header.isEmpty ? body : header.joined(separator: "\n") + "\n\n" + body
        }
        var header = ["<?php"]
        let label = docblockLine(label)
        let description = docblockLine(description ?? "")
        if !label.isEmpty || !description.isEmpty {
            header.append("/**")
            if !label.isEmpty { header.append(" * @label \(label)") }
            if !description.isEmpty { header.append(" * @description \(description)") }
            header.append(" */")
        }
        var body = Substring(code)
        let start = body.drop { $0.isWhitespace }
        if start.hasPrefix("<?php"), start.dropFirst(5).first.map(\.isWhitespace) ?? true {
            body = start.dropFirst(5)
        }
        let tidied = tidy(String(body))
        return header.joined(separator: "\n") + "\n\n" + (tidied.isEmpty ? "" : tidied + "\n")
    }

    /// A file name for a label: lowercase ASCII letters and digits joined by `-`, plus `.php`
    /// (`.sql` for SQL snippets, #130).
    public static func fileName(forLabel label: String, language: TabLanguage = .php) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        slug = String(slug.prefix(60))
        while slug.hasSuffix("-") { slug.removeLast() }
        return (slug.isEmpty ? "snippet" : slug) + "." + fileExtension(for: language)
    }

    /// `php`, `sql` (#130), or `mongodb` (#207).
    public static func fileExtension(for language: TabLanguage) -> String {
        switch language {
        case .sql: "sql"
        case .mongodb: "mongodb"
        default: "php"
        }
    }

    /// Where `save` writes a snippet with this label.
    public static func fileURL(forLabel label: String, projectRoot: URL, language: TabLanguage = .php) -> URL {
        directory(projectRoot: projectRoot).appendingPathComponent(fileName(forLabel: label, language: language))
    }

    public enum SaveError: Error, Equatable, CustomStringConvertible {
        /// The file exists and `overwrite` was false.
        case fileExists(URL)
        case invalidFileName(String)

        public var description: String {
            switch self {
            case .fileExists(let url): "\(url.lastPathComponent) already exists in \(ProjectSnippets.relativeDirectory)."
            case .invalidFileName(let name): "“\(name)” is not a valid snippet file name."
            }
        }
    }

    /// Writes a snippet into the project's snippets folder (creating it) and returns the file.
    /// Refuses to replace an existing file unless `overwrite` is true.
    @discardableResult
    public static func save(label: String, description: String?, code: String, projectRoot: URL, fileName: String? = nil, overwrite: Bool = false, language: TabLanguage = .php, connection: SQLConnectionReference? = nil) throws -> URL {
        let name = fileName ?? self.fileName(forLabel: label, language: language)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), name.lowercased().hasSuffix("." + fileExtension(for: language)) else {
            throw SaveError.invalidFileName(name)
        }
        let directory = directory(projectRoot: projectRoot)
        let url = directory.appendingPathComponent(name)
        let fileManager = FileManager.default
        if !overwrite, fileManager.fileExists(atPath: url.path) { throw SaveError.fileExists(url) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(fileContents(label: label, description: description, code: code, language: language, connection: connection).utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Parsing helpers

    private struct MetadataBlock {
        var range: Range<Substring.Index>
        var label: String?
        var description: String?
        var inputs: [String]
        /// `@connection` (#149), read for SQL snippets only.
        var connection: String? = nil
    }

    /// The first docblock before any code, when it carries `@label`, `@description`, or `@input`
    /// (or, in an SQL snippet, `@connection`, #149).
    private static func metadataBlock(in text: Substring, sql: Bool = false) -> MetadataBlock? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            let remainder = text[index...]
            if remainder.hasPrefix("/**"), !remainder.hasPrefix("/**/") {
                let bodyStart = text.index(index, offsetBy: 3)
                guard let close = text.range(of: "*/", range: bodyStart..<text.endIndex) else { return nil }
                let tags = parseTags(text[bodyStart..<close.lowerBound])
                guard tags.label != nil || tags.description != nil || !tags.inputs.isEmpty || (sql && tags.connection != nil) else { return nil }
                return MetadataBlock(range: index..<close.upperBound, label: tags.label, description: tags.description, inputs: tags.inputs, connection: sql ? tags.connection : nil)
            }
            if remainder.hasPrefix("/*") {
                guard let close = text.range(of: "*/", range: text.index(index, offsetBy: 2)..<text.endIndex) else { return nil }
                index = close.upperBound
                continue
            }
            if remainder.hasPrefix("//") || (remainder.hasPrefix("#") && !remainder.hasPrefix("#[")) {
                index = remainder.firstIndex(where: \.isNewline) ?? text.endIndex
                continue
            }
            return nil
        }
        return nil
    }

    private enum Tag { case label, description }

    /// `@label` and `@description` (each may continue on following lines), the `@input`
    /// declarations (one line each), and `@connection` (one line, #149) from a docblock body.
    private static func parseTags(_ body: Substring) -> (label: String?, description: String?, inputs: [String], connection: String?) {
        var label: String?
        var description: String?
        var inputs: [String] = []
        var connection: String?
        var current: Tag?
        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let declaration = SnippetInputs.declaration(inDocblockLine: rawLine) {
                inputs.append(declaration)
                current = nil
                continue
            }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty {
                current = nil
                continue
            }
            if line.hasPrefix("@") {
                let name = line.prefix { !$0.isWhitespace }
                let value = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "@label":
                    label = value
                    current = .label
                case "@description":
                    description = value
                    current = .description
                case "@connection":
                    connection = value.isEmpty ? nil : value
                    current = nil
                default:
                    current = nil
                }
                continue
            }
            switch current {
            case .label: label = joined(label, line)
            case .description: description = joined(description, line)
            case nil: break
            }
        }
        return (label, description, inputs, connection)
    }

    private static func joined(_ existing: String?, _ line: String) -> String {
        guard let existing, !existing.isEmpty else { return line }
        return existing + " " + line
    }

    /// Drops leading blank lines (keeping the first code line's indentation, unless it shares
    /// a line with the removed tag) and trailing whitespace.
    private static func tidy(_ code: String) -> String {
        guard let first = code.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        let lineStart = code[..<first].lastIndex(where: \.isNewline).map { code.index(after: $0) } ?? first
        var result = code[lineStart...]
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }

    /// One docblock-safe line: whitespace collapsed, no comment terminator.
    private static func docblockLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "*/", with: "* /")
    }
}
