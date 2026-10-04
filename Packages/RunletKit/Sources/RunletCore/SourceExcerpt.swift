import Foundation

/// A few lines of source around one line (#8): error cards and stack frames show them, with the
/// line itself marked. Read from the tab's own code or from a file on this Mac.
public struct SourceExcerpt: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// 1-based, as editors number lines (for the tab's code: the editor's line).
        public var number: Int
        public var text: String
        /// The line was longer than `SourceExcerptLimits.maxLineLength`; `text` ends with "…".
        public var isTruncated: Bool

        public init(number: Int, text: String, isTruncated: Bool = false) {
            self.number = number
            self.text = text
            self.isTruncated = isTruncated
        }
    }

    public var lines: [Line]
    /// The line the excerpt is about; always one of `lines`.
    public var focusLine: Int

    public init(lines: [Line], focusLine: Int) {
        self.lines = lines
        self.focusLine = focusLine
    }

    /// The same lines with tabs as four spaces and the indentation every non-blank line shares
    /// removed, so code deep inside a class fits a narrow output pane.
    public func dedented() -> SourceExcerpt {
        let expanded = lines.map { line -> Line in
            var copy = line
            copy.text = line.text.replacingOccurrences(of: "\t", with: "    ")
            return copy
        }
        let indents = expanded.compactMap { line -> Int? in
            let leading = line.text.prefix { $0 == " " }.count
            return leading == line.text.count ? nil : leading
        }
        guard let common = indents.min(), common > 0 else { return SourceExcerpt(lines: expanded, focusLine: focusLine) }
        return SourceExcerpt(lines: expanded.map { line in
            var copy = line
            copy.text = String(line.text.dropFirst(min(common, line.text.prefix { $0 == " " }.count)))
            return copy
        }, focusLine: focusLine)
    }
}

/// Bounds for reading an excerpt: only the lines needed are kept, and a file is read only up to
/// the excerpt's last line, never past `maxBytes`.
public struct SourceExcerptLimits: Sendable, Equatable {
    /// Lines shown before and after the focus line (2: five lines in all).
    public var radius: Int = 2
    /// Bytes of a file read at most. A line further in is not shown.
    public var maxBytes: Int = 8 * 1024 * 1024
    /// Characters kept of each line.
    public var maxLineLength: Int = 300

    public init(radius: Int = 2, maxBytes: Int = 8 * 1024 * 1024, maxLineLength: Int = 300) {
        self.radius = radius
        self.maxBytes = maxBytes
        self.maxLineLength = maxLineLength
    }
}

/// Why there is no excerpt. Never shown as an error: the output says "Source not available here".
public enum SourceExcerptFailure: Error, Sendable, Equatable {
    /// No line was asked for (0 or less).
    case noLine
    case missing
    /// A folder, socket, or other special file.
    case notAFile
    case unreadable(String)
    /// The line is further into the file than Runlet reads (`maxBytes`).
    case tooLarge
    /// The file is shorter than the line: it changed since, or it's a different copy.
    case pastEnd(lineCount: Int)
    case binary

    public var message: String {
        switch self {
        case .noLine: "No line number was reported."
        case .missing: "The file doesn't exist on this Mac."
        case .notAFile: "This isn't a regular file."
        case .unreadable(let reason): "The file can't be read: \(reason)"
        case .tooLarge: "The line is too far into a large file to show here."
        case .pastEnd(let count): "The file here has only \(count) line\(count == 1 ? "" : "s"); it may have changed since the run."
        case .binary: "The file isn't text."
        }
    }
}

/// Reads excerpts from files (streamed in chunks, stopping after the last line needed) and from
/// text such as the tab's code. Blocking: call it off the main thread (`SourceExcerptStore`).
public enum SourceExcerptReader {
    /// Lines around `line` (1-based) of the file at `path`.
    public static func read(path: String, line: Int, limits: SourceExcerptLimits = SourceExcerptLimits()) -> Result<SourceExcerpt, SourceExcerptFailure> {
        guard line > 0 else { return .failure(.noLine) }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            return .failure(FileManager.default.fileExists(atPath: path) ? .unreadable(error.localizedDescription) : .missing)
        }
        // A FIFO or device would block or never end; only regular files are read.
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .failure(.notAFile) }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        defer { try? handle.close() }
        var scanner = LineWindowScanner(focus: line, limits: limits)
        var read = 0
        while !scanner.isDone {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(64 * 1024, max(1, limits.maxBytes - read)))
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
            guard let chunk, !chunk.isEmpty else { break }
            read += chunk.count
            chunk.withUnsafeBytes { scanner.feed($0) }
            if scanner.isBinary { return .failure(.binary) }
            if read >= limits.maxBytes && !scanner.isDone {
                // Lines after the focus line are optional; the focus line itself isn't.
                if scanner.currentLine <= line { return .failure(.tooLarge) }
                scanner.stop()
            }
        }
        return scanner.finish()
    }

    /// Lines around `line` (1-based) of `text`, numbered from `firstLineNumber`.
    public static func excerpt(text: String, line: Int, firstLineNumber: Int = 1, limits: SourceExcerptLimits = SourceExcerptLimits()) -> Result<SourceExcerpt, SourceExcerptFailure> {
        guard line > 0 else { return .failure(.noLine) }
        var scanner = LineWindowScanner(focus: line, limits: limits)
        var copy = text
        copy.withUTF8 { scanner.feed(UnsafeRawBufferPointer($0)) }
        if scanner.isBinary { return .failure(.binary) }
        return scanner.finish().map { excerpt in
            let shift = firstLineNumber - 1
            guard shift != 0 else { return excerpt }
            return SourceExcerpt(lines: excerpt.lines.map { Line(number: $0.number + shift, text: $0.text, isTruncated: $0.isTruncated) }, focusLine: excerpt.focusLine + shift)
        }
    }

    /// Lines around a line of the code `request` ran, numbered as the editor numbers them. The
    /// runner never moves lines (a tagless snippet's `<?php ` and `declare(strict_types=1);` go
    /// on its first line), so line N of the code is the editor's line N, or the selection's
    /// N-th line for Run Selection.
    public static func snippet(_ request: RunRequest, snippetLine: Int, limits: SourceExcerptLimits = SourceExcerptLimits()) -> Result<SourceExcerpt, SourceExcerptFailure> {
        excerpt(text: request.code, line: snippetLine, firstLineNumber: request.editorLine(forSnippetLine: 1), limits: limits)
    }

    private typealias Line = SourceExcerpt.Line
}

/// Collects the lines `focus - radius ... focus + radius` from UTF-8 bytes fed in chunks.
/// Lines end at "\n"; a "\r" before it (CRLF) is dropped. Bytes outside the window are only
/// counted, and each kept line keeps at most four bytes per allowed character.
struct LineWindowScanner {
    let focus: Int
    let first: Int
    let last: Int
    let limits: SourceExcerptLimits
    private(set) var currentLine = 1
    private var current: [UInt8] = []
    private var overflowed = false
    /// The line being read has bytes (inside the window or not).
    private var lineHasBytes = false
    private var lines: [SourceExcerpt.Line] = []
    private(set) var isDone = false
    private(set) var isBinary = false

    init(focus: Int, limits: SourceExcerptLimits) {
        self.focus = focus
        self.limits = limits
        first = max(1, focus - max(0, limits.radius))
        last = focus + max(0, limits.radius)
    }

    private var maxLineBytes: Int { max(1, limits.maxLineLength) * 4 }

    mutating func feed(_ buffer: UnsafeRawBufferPointer) {
        for byte in buffer {
            if isDone { return }
            if byte == 0x0A {
                if currentLine >= first { endLine() }
                currentLine += 1
                lineHasBytes = false
                if currentLine > last { isDone = true }
                continue
            }
            lineHasBytes = true
            if currentLine >= first {
                if byte == 0 {
                    isBinary = true
                    isDone = true
                    return
                }
                if current.count < maxLineBytes { current.append(byte) } else { overflowed = true }
            }
        }
    }

    /// Ends the window early (the read limit came after the focus line); the line being read is left out.
    mutating func stop() {
        current.removeAll()
        overflowed = false
        isDone = true
    }

    private mutating func endLine() {
        if current.last == 0x0D && !overflowed { current.removeLast() }
        lines.append(Self.decode(current, number: currentLine, overflowed: overflowed, maxLength: limits.maxLineLength))
        current.removeAll(keepingCapacity: true)
        overflowed = false
    }

    /// The excerpt, once the bytes are all fed (or the window is complete).
    mutating func finish() -> Result<SourceExcerpt, SourceExcerptFailure> {
        if !isDone {
            // The last line has no newline. An empty one after a final newline isn't a line.
            if currentLine >= first, !current.isEmpty || overflowed { endLine() }
            let lineCount = lineHasBytes ? currentLine : currentLine - 1
            if focus > lineCount { return .failure(.pastEnd(lineCount: max(0, lineCount))) }
        }
        return .success(SourceExcerpt(lines: lines, focusLine: focus))
    }

    static func decode(_ bytes: [UInt8], number: Int, overflowed: Bool, maxLength: Int) -> SourceExcerpt.Line {
        var bytes = bytes
        if overflowed { trimIncompleteUTF8(&bytes) }
        // Not UTF-8: Latin-1 maps every byte to a character.
        var text = String(validating: bytes, as: UTF8.self) ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        if overflowed && text.last == "\r" { text.removeLast() }
        var truncated = overflowed
        if text.count > maxLength {
            text = String(text.prefix(maxLength))
            truncated = true
        }
        if truncated { text += "…" }
        return SourceExcerpt.Line(number: number, text: text, isTruncated: truncated)
    }

    /// Drops a multi-byte UTF-8 sequence cut off at the end of `bytes`.
    static func trimIncompleteUTF8(_ bytes: inout [UInt8]) {
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuation < 3 {
            index -= 1
            continuation += 1
        }
        guard index >= 0 else { return }
        let lead = bytes[index]
        let expected: Int
        switch lead {
        case 0x00..<0x80: expected = 0
        case 0xC0..<0xE0: expected = 1
        case 0xE0..<0xF0: expected = 2
        case 0xF0..<0xF8: expected = 3
        default: return
        }
        if continuation < expected { bytes.removeSubrange(index...) }
    }
}
