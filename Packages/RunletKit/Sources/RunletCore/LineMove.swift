import Foundation

/// Move Line Up/Down and Duplicate Line Up/Down (#234) as a text transform, in UTF-16 units
/// (NSString's, so offsets are the editor's).
///
/// The lines are those the selection touches: the caret's line, or every line from the
/// selection's start to its end, leaving out a last line the selection only reaches at its
/// start (a selection of whole lines ends there). Lines end at `\r\n`, `\n`, or `\r`; text that
/// ends with one has an empty last line, as the editor shows. Indentation is never changed.
///
/// A move swaps the lines with the line above or below; nothing happens at the first or last
/// line. The selection stays on the moved text. The lines that make room are the only text
/// replaced: the moved lines' characters stay where they are in the text storage and only
/// shift, so what the editor keeps on them (folds, inlay hints, inline values) moves along.
/// A duplicate inserts a copy of the lines above or below them and keeps the selection on the
/// original text, which ends up on top (Duplicate Line Up) or below (Duplicate Line Down).
///
/// `keepingTogether` lists line spans that move as one line, such as folded blocks: lines that
/// touch one take all of it along, and lines moving past one skip it as a whole.
///
/// The editor's hidden lines (the `<?php` tag and `@var` declarations PHPantom sees,
/// `ScratchDocumentMapping`) are not in the editor's text, so nothing moves into or out of them.
public enum LineMove {
    public enum Direction: Sendable { case up, down }

    /// One replacement, in UTF-16 units of the text as the edits before it left it.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String

        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    public struct Result: Equatable, Sendable {
        /// Applied in order.
        public var edits: [Edit]
        /// The selection afterwards, on the moved text (or the duplicated original).
        public var selection: NSRange
        /// A move's other lines (the ones the moved lines swapped with), as a range of the text
        /// before the move, and how far their characters moved: the editor's state on them (a
        /// fold) can be put back at `location + displacedShift`.
        public var displaced: NSRange?
        public var displacedShift: Int

        public init(edits: [Edit], selection: NSRange, displaced: NSRange? = nil, displacedShift: Int = 0) {
            self.edits = edits
            self.selection = selection
            self.displaced = displaced
            self.displacedShift = displacedShift
        }
    }

    /// Moves the selection's lines one line up or down; nil at the first or last line.
    public static func move(_ direction: Direction, in text: String, selection: NSRange, keepingTogether spans: [ClosedRange<Int>] = []) -> Result? {
        let string = text as NSString
        let lines = Self.lines(in: string)
        let (first, last) = touchedLines(lines, selection: selection, spans: spans)
        let blockStart = lines[first].start
        let blockEnd = lines[last].end
        let blockLength = blockEnd - blockStart
        switch direction {
        case .up:
            guard first > 0 else { return nil }
            let neighborFirst = spans.first { $0.contains(first - 1) }.map { max(0, $0.lowerBound) } ?? first - 1
            let neighborStart = lines[neighborFirst].start
            let neighborLength = blockStart - neighborStart
            var insert = string.substring(with: NSRange(location: neighborStart, length: neighborLength))
            var shift = blockLength
            if !lines[last].hasTerminator {
                // The last line moves up: it takes the line ending the other lines lose.
                let terminator = lines[first - 1].terminator(in: string)
                let terminatorLength = terminator.utf16.count
                insert = terminator + string.substring(with: NSRange(location: neighborStart, length: neighborLength - terminatorLength))
                shift += terminatorLength
            }
            let edits = [
                Edit(range: NSRange(location: neighborStart, length: neighborLength), replacement: ""),
                Edit(range: NSRange(location: neighborStart + blockLength, length: 0), replacement: insert),
            ]
            let moved = NSRange(location: neighborStart, length: blockLength)
            return Result(edits: edits, selection: shifted(selection, by: -neighborLength, within: moved),
                          displaced: NSRange(location: neighborStart, length: neighborLength), displacedShift: shift)
        case .down:
            guard last < lines.count - 1 else { return nil }
            let neighborLast = spans.first { $0.contains(last + 1) }.map { min(lines.count - 1, $0.upperBound) } ?? last + 1
            let neighborEnd = lines[neighborLast].end
            let neighbor = string.substring(with: NSRange(location: blockEnd, length: neighborEnd - blockEnd))
            if lines[neighborLast].hasTerminator {
                let edits = [
                    Edit(range: NSRange(location: blockEnd, length: neighborEnd - blockEnd), replacement: ""),
                    Edit(range: NSRange(location: blockStart, length: 0), replacement: neighbor),
                ]
                let shift = neighborEnd - blockEnd
                return Result(edits: edits, selection: shifted(selection, by: shift, within: NSRange(location: blockStart + shift, length: blockLength)),
                              displaced: NSRange(location: blockEnd, length: neighborEnd - blockEnd), displacedShift: -blockLength)
            }
            // The other lines end the text: the moved lines' line ending goes with them.
            let terminator = lines[last].terminator(in: string)
            let terminatorLength = terminator.utf16.count
            let edits = [
                Edit(range: NSRange(location: blockEnd - terminatorLength, length: neighborEnd - blockEnd + terminatorLength), replacement: ""),
                Edit(range: NSRange(location: blockStart, length: 0), replacement: neighbor + terminator),
            ]
            let shift = neighborEnd - blockEnd + terminatorLength
            return Result(edits: edits, selection: shifted(selection, by: shift, within: NSRange(location: blockStart + shift, length: blockLength - terminatorLength)),
                          displaced: NSRange(location: blockEnd, length: neighborEnd - blockEnd), displacedShift: -blockLength)
        }
    }

    /// Copies the selection's lines above (`.up`) or below (`.down`) them.
    public static func duplicate(_ direction: Direction, in text: String, selection: NSRange, keepingTogether spans: [ClosedRange<Int>] = []) -> Result {
        let string = text as NSString
        let lines = Self.lines(in: string)
        let (first, last) = touchedLines(lines, selection: selection, spans: spans)
        let blockStart = lines[first].start
        let block = string.substring(with: NSRange(location: blockStart, length: lines[last].end - blockStart))
        // The last line has no line ending: the copy needs the text's own.
        let terminator = lines[last].hasTerminator ? "" : preferredTerminator(lines, in: string)
        switch direction {
        case .up:
            // The copy goes below, so the original (with the selection) is the upper one.
            let edit = Edit(range: NSRange(location: lines[last].end, length: 0), replacement: terminator + block)
            return Result(edits: [edit], selection: selection)
        case .down:
            let copy = block + terminator
            let edit = Edit(range: NSRange(location: blockStart, length: 0), replacement: copy)
            let length = copy.utf16.count
            return Result(edits: [edit], selection: NSRange(location: selection.location + length, length: selection.length))
        }
    }

    /// `text` after `edits`, applied in order (for tests and previews).
    public static func apply(_ edits: [Edit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    /// The line spans that character ranges cover (folded blocks, for `keepingTogether`): from
    /// the line of each range's start to the line of its end.
    public static func lineSpans(covering ranges: [NSRange], in text: String) -> [ClosedRange<Int>] {
        let lines = Self.lines(in: text as NSString)
        return ranges.map { range in
            let start = lineIndex(of: range.location, in: lines)
            return start...max(start, lineIndex(of: NSMaxRange(range), in: lines))
        }
    }

    // MARK: Lines

    struct Line: Equatable {
        var start: Int
        var contentEnd: Int
        var end: Int

        var hasTerminator: Bool { end > contentEnd }

        func terminator(in string: NSString) -> String {
            hasTerminator ? string.substring(with: NSRange(location: contentEnd, length: end - contentEnd)) : "\n"
        }
    }

    /// Every line, with its line ending; text ending in a line ending has an empty last line.
    static func lines(in string: NSString) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var index = 0
        let length = string.length
        while index < length {
            let unit = string.character(at: index)
            if unit == 0x0A || unit == 0x0D {
                let end = unit == 0x0D && index + 1 < length && string.character(at: index + 1) == 0x0A ? index + 2 : index + 1
                lines.append(Line(start: start, contentEnd: index, end: end))
                start = end
                index = end
            } else {
                index += 1
            }
        }
        lines.append(Line(start: start, contentEnd: length, end: length))
        return lines
    }

    /// The line an offset is on (an offset at a line's end, before its line ending, is on it).
    static func lineIndex(of offset: Int, in lines: [Line]) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The first and last line the selection touches, widened to whole spans.
    static func touchedLines(_ lines: [Line], selection: NSRange, spans: [ClosedRange<Int>]) -> (Int, Int) {
        var first = lineIndex(of: selection.location, in: lines)
        var last = lineIndex(of: NSMaxRange(selection), in: lines)
        if selection.length > 0, last > first, lines[last].start == NSMaxRange(selection) { last -= 1 }
        var widened = true
        while widened {
            widened = false
            for span in spans where span.lowerBound <= last && span.upperBound >= first {
                let lower = max(0, min(first, span.lowerBound))
                let upper = min(lines.count - 1, max(last, span.upperBound))
                if lower != first || upper != last {
                    (first, last) = (lower, upper)
                    widened = true
                }
            }
        }
        return (first, last)
    }

    /// The line ending a new line gets: the text's first, or `\n`.
    static func preferredTerminator(_ lines: [Line], in string: NSString) -> String {
        lines.first(where: \.hasTerminator)?.terminator(in: string) ?? "\n"
    }

    /// `selection` moved by `offset`, kept inside `bounds` (the moved text's new place).
    static func shifted(_ selection: NSRange, by offset: Int, within bounds: NSRange) -> NSRange {
        let start = min(max(selection.location + offset, bounds.location), NSMaxRange(bounds))
        let end = min(max(NSMaxRange(selection) + offset, start), NSMaxRange(bounds))
        return NSRange(location: start, length: end - start)
    }
}
