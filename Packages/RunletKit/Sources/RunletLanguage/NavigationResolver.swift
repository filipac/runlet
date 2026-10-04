import Foundation
import RunletCore

/// Where a definition or reference goes (#22), decided from its URI.
public enum NavigationDestination: Sendable, Equatable {
    /// The tab's own code: the caret moves there (editor coordinates).
    case scratch(LSPRange)
    /// A line Runlet adds before the snippet and never shows: `<?php`, or a driver variable's
    /// `@var` declaration. Carries the variable's name and type when it is one.
    case hiddenLine(variable: String?, type: String?)
    /// A project file on this Mac: opens in the external editor at its line.
    case projectFile(NavigationFile)
    /// Shown read-only inside Runlet.
    case peek(NavigationFile)
    /// Nothing to open, and why.
    case unavailable(String)
}

/// A file location outside the tab, as the editor shows it.
public struct NavigationFile: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// Under the project's `vendor/`.
        case vendor
        /// A project file (peeked only when no external editor is set).
        case project
        /// On this Mac, outside the project.
        case outsideProject
        /// Text Runlet keeps in memory: another tab's code, or Runlet's snippet API.
        case inMemory
    }

    public var uri: String
    /// The file on this Mac; nil for in-memory documents.
    public var path: String?
    /// The definition's range in the file (LSP coordinates of that file).
    public var range: LSPRange
    public var origin: Origin
    /// The path relative to the project root, or the full path outside it.
    public var displayPath: String
    /// Where the target's PHP sees the file (a container or server path), when that differs.
    public var runtimePath: String?
    public var runtimeLocation: String?

    /// 1-based line, as editors number them.
    public var line: Int { range.start.line + 1 }
    public var fileName: String { (displayPath as NSString).lastPathComponent }
}

/// Decides where locations from PHPantom go, for one tab.
public struct NavigationResolver: Sendable {
    public var scratchURI: String
    public var mapping: ScratchDocumentMapping
    public var editorLineCount: Int
    public var workspaceRoot: String
    public var workspaceKind: LanguageWorkspace.Kind
    /// How the target's paths relate to this Mac's (Docker and SSH targets with a local folder).
    public var pathMapping: EditorPathMapping
    /// An external editor is set; without one, project files are peeked too.
    public var hasExternalEditor: Bool
    public var fileExists: @Sendable (String) -> Bool

    public init(scratchURI: String, mapping: ScratchDocumentMapping, editorLineCount: Int, workspaceRoot: String, workspaceKind: LanguageWorkspace.Kind,
                pathMapping: EditorPathMapping = .host, hasExternalEditor: Bool, fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.scratchURI = scratchURI
        self.mapping = mapping
        self.editorLineCount = editorLineCount
        self.workspaceRoot = workspaceRoot
        self.workspaceKind = workspaceKind
        self.pathMapping = pathMapping
        self.hasExternalEditor = hasExternalEditor
        self.fileExists = fileExists
    }

    /// The folder Runlet's in-memory documents live under (never created on disk).
    private var scratchFolder: String {
        (Self.normalize(workspaceRoot) as NSString).appendingPathComponent(".runlet-scratch")
    }

    public func destination(for location: LSPLocation) -> NavigationDestination {
        if location.uri == scratchURI { return scratchDestination(location.range) }
        guard let url = URL(string: location.uri), url.isFileURL else {
            // PHPantom 0.10 points built-in classes' members at its embedded stubs.
            if let url = URL(string: location.uri), url.scheme == "phpantom-stub" {
                let name = url.host ?? url.path
                return .unavailable(name.isEmpty ? "This is built into PHP; there is no source to show." : "\(name) is built into PHP; there is no source to show.")
            }
            return .unavailable("\(location.uri) isn't a file.")
        }
        let path = Self.normalize(url.path)
        let root = Self.normalize(workspaceRoot)
        if path.hasPrefix(scratchFolder + "/") {
            let name = (path as NSString).lastPathComponent
            let label = name == "runlet-api.php" ? "Runlet's snippet API" : "Another tab's code"
            return .peek(NavigationFile(uri: location.uri, path: nil, range: location.range, origin: .inMemory, displayPath: label))
        }
        let relative: String? = workspaceKind == .project && (path == root || path.hasPrefix(root == "/" ? "/" : root + "/"))
            ? String(path.dropFirst(root == "/" ? 1 : root.count + 1)) : nil
        guard fileExists(path) else {
            return .unavailable("\(relative ?? path) isn't on this Mac.")
        }
        let runtime = pathMapping.runtimePath(forHostPath: path)
        let runtimeName = pathMapping.runtimeLocationName
        guard let relative else {
            return .peek(NavigationFile(uri: location.uri, path: path, range: location.range, origin: .outsideProject, displayPath: path, runtimePath: runtime, runtimeLocation: runtime == nil ? nil : runtimeName))
        }
        let isVendor = relative.split(separator: "/").contains("vendor")
        let file = NavigationFile(uri: location.uri, path: path, range: location.range, origin: isVendor ? .vendor : .project,
                                  displayPath: relative, runtimePath: runtime, runtimeLocation: runtime == nil ? nil : runtimeName)
        if isVendor || !hasExternalEditor { return .peek(file) }
        return .projectFile(file)
    }

    private func scratchDestination(_ range: LSPRange) -> NavigationDestination {
        if range.start.line < mapping.lineOffset {
            // Line 0 is `<?php`; the declarations follow in name order (`ScratchDocumentMapping`).
            let index = range.start.line - 1
            let names = mapping.declarations.keys.sorted()
            if index >= 0, index < names.count {
                return .hiddenLine(variable: names[index], type: mapping.declarations[names[index]])
            }
            return .hiddenLine(variable: nil, type: nil)
        }
        var mapped = mapping.toEditor(range)
        // The hidden `;` after a tagless snippet: the end of its last line.
        let last = max(0, editorLineCount - 1)
        if mapped.start.line > last {
            let end = LSPPosition(line: last, character: Int.max / 4)
            mapped = LSPRange(start: end, end: end)
        } else if mapped.end.line > last {
            mapped.end = LSPPosition(line: last, character: Int.max / 4)
        }
        return .scratch(mapped)
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// One row of Find References (#22).
public struct ReferenceItem: Sendable, Equatable, Identifiable {
    public var id: Int
    public var destination: NavigationDestination
    /// "This tab", or the file's path relative to the project.
    public var label: String
    /// 1-based line in the editor (the tab) or in the file.
    public var line: Int
    /// The line's text, trimmed (empty when it can't be read).
    public var snippet: String
    /// The reference's columns within `snippet` (UTF-16), for emphasis.
    public var highlight: Range<Int>?

    public var isInTab: Bool {
        if case .scratch = destination { return true }
        return false
    }
}

public enum ReferenceList {
    /// At most this many references are listed.
    public static let limit = 500

    /// Rows for `locations`: the tab's own first, then project files, then the rest (vendor,
    /// other files, in-memory documents), each by path and line. References on hidden lines
    /// are left out, and duplicates are listed once. `lineText` returns a file's 0-based line.
    public static func make(_ locations: [LSPLocation], resolver: NavigationResolver, editorText: String,
                            lineText: (NavigationFile, Int) -> String?) -> [ReferenceItem] {
        var seen = Set<LSPLocation>()
        let editorLines = editorText.components(separatedBy: "\n")
        var rows: [(rank: Int, path: String, item: ReferenceItem)] = []
        for location in locations where seen.insert(location).inserted {
            let destination = resolver.destination(for: location)
            let rank: Int
            let label: String
            let line: Int
            var text: String?
            var column = 0
            var width = 0
            switch destination {
            case .hiddenLine, .unavailable:
                continue
            case .scratch(let range):
                rank = 0
                label = "This tab"
                line = range.start.line + 1
                text = editorLines.indices.contains(range.start.line) ? editorLines[range.start.line] : nil
                column = range.start.character
                width = range.end.line == range.start.line ? range.end.character - range.start.character : 0
            case .projectFile(let file), .peek(let file):
                rank = file.origin == .project ? 1 : 2
                label = file.displayPath
                line = file.line
                text = lineText(file, file.range.start.line)
                column = file.range.start.character
                width = file.range.end.line == file.range.start.line ? file.range.end.character - file.range.start.character : 0
            }
            var snippet = (text ?? "").replacingOccurrences(of: "\r", with: "")
            var highlight: Range<Int>?
            let leading = snippet.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
            snippet = String(snippet.trimmingCharacters(in: .whitespaces))
            let length = snippet.utf16.count
            let start = column - leading
            if width > 0, start >= 0, start + width <= length { highlight = start..<(start + width) }
            if length > 200 {
                snippet = String(snippet.prefix(200)) + "…"
                if let range = highlight, range.upperBound > 200 { highlight = nil }
            }
            rows.append((rank, label, ReferenceItem(id: 0, destination: destination, label: label, line: line, snippet: snippet, highlight: highlight)))
            if rows.count >= limit { break }
        }
        let sorted = rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if l.rank != r.rank { return l.rank < r.rank }
            if l.path != r.path { return l.path.localizedStandardCompare(r.path) == .orderedAscending }
            if l.item.line != r.item.line { return l.item.line < r.item.line }
            return lhs.offset < rhs.offset
        }
        return sorted.enumerated().map { index, row in
            var item = row.element.item
            item.id = index
            return item
        }
    }
}
