import Foundation

/// A snippet shared with a project as `<project>/.runlet/snippets/<name>.php`, so a team
/// can keep it in git. Loading one only reads the file; it never runs.
public struct ProjectSnippet: Sendable, Hashable, Identifiable {
    /// The file's path.
    public var id: String
    /// `@label` from the metadata docblock, or the file name without `.php`.
    public var label: String
    /// `@description` from the metadata docblock.
    public var description: String?
    /// The file without its opening `<?php` tag and without the metadata docblock.
    public var code: String
    public var fileURL: URL

    public init(id: String, label: String, description: String?, code: String, fileURL: URL) {
        self.id = id
        self.label = label
        self.description = description
        self.code = code
        self.fileURL = fileURL
    }
}

/// Reads and writes project snippets in `<project>/.runlet/snippets/*.php`.
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
/// comments may precede it), and only counts when it has `@label` or `@description`.
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

    /// Every readable `*.php` file directly in the snippets folder, sorted by label.
    /// Hidden, unreadable, non-UTF-8, and oversized files are skipped. Never runs anything.
    public static func load(projectRoot: URL) -> [ProjectSnippet] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory(projectRoot: projectRoot), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var snippets: [ProjectSnippet] = []
        for url in entries where url.pathExtension.lowercased() == "php" {
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

    /// Parses one snippet file's contents.
    public static func parse(_ contents: String, fileURL: URL) -> ProjectSnippet {
        var text = Substring(contents)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }

        // Drop the opening tag (and anything before it, which can only be whitespace).
        var rest = text
        let start = text.drop { $0.isWhitespace }
        if start.hasPrefix("<?php") {
            let afterTag = start.dropFirst(5)
            if afterTag.first.map(\.isWhitespace) ?? true { rest = afterTag }
        }

        var label: String?
        var description: String?
        var code = String(rest)
        if let block = metadataBlock(in: rest) {
            label = block.label
            description = block.description
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
            fileURL: fileURL
        )
    }

    /// A snippet file: `<?php`, a metadata docblock (when there is a label or description),
    /// a blank line, then the code. `load` reads back the same label, description, and code.
    public static func fileContents(label: String, description: String?, code: String) -> String {
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

    /// A file name for a label: lowercase ASCII letters and digits joined by `-`, plus `.php`.
    public static func fileName(forLabel label: String) -> String {
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
        return (slug.isEmpty ? "snippet" : slug) + ".php"
    }

    /// Where `save` writes a snippet with this label.
    public static func fileURL(forLabel label: String, projectRoot: URL) -> URL {
        directory(projectRoot: projectRoot).appendingPathComponent(fileName(forLabel: label))
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
    public static func save(label: String, description: String?, code: String, projectRoot: URL, fileName: String? = nil, overwrite: Bool = false) throws -> URL {
        let name = fileName ?? self.fileName(forLabel: label)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), name.lowercased().hasSuffix(".php") else {
            throw SaveError.invalidFileName(name)
        }
        let directory = directory(projectRoot: projectRoot)
        let url = directory.appendingPathComponent(name)
        let fileManager = FileManager.default
        if !overwrite, fileManager.fileExists(atPath: url.path) { throw SaveError.fileExists(url) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(fileContents(label: label, description: description, code: code).utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Parsing helpers

    private struct MetadataBlock {
        var range: Range<Substring.Index>
        var label: String?
        var description: String?
    }

    /// The first docblock before any code, when it carries `@label` or `@description`.
    private static func metadataBlock(in text: Substring) -> MetadataBlock? {
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
                guard tags.label != nil || tags.description != nil else { return nil }
                return MetadataBlock(range: index..<close.upperBound, label: tags.label, description: tags.description)
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

    /// `@label` and `@description` (each may continue on following lines) from a docblock body.
    private static func parseTags(_ body: Substring) -> (label: String?, description: String?) {
        var label: String?
        var description: String?
        var current: Tag?
        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
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
        return (label, description)
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
