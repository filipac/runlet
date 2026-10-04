import Foundation
import Testing
@testable import RunletCore

/// Move Line Up/Down and Duplicate Line Up/Down (#234). Texts mark the selection: `‸` is a
/// caret, `«…»` a selection.
struct LineMoveTests {
    private func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let string = NSMutableString(string: marked)
        let caret = string.range(of: "‸")
        if caret.location != NSNotFound {
            string.deleteCharacters(in: caret)
            return (string as String, NSRange(location: caret.location, length: 0))
        }
        let open = string.range(of: "«")
        string.deleteCharacters(in: open)
        let close = string.range(of: "»")
        string.deleteCharacters(in: close)
        return (string as String, NSRange(location: open.location, length: close.location - open.location))
    }

    private func render(_ text: String, _ selection: NSRange) -> String {
        let string = NSMutableString(string: text)
        if selection.length == 0 {
            string.insert("‸", at: selection.location)
        } else {
            string.insert("»", at: NSMaxRange(selection))
            string.insert("«", at: selection.location)
        }
        return string as String
    }

    private func move(_ direction: LineMove.Direction, _ marked: String, spans: [ClosedRange<Int>] = []) -> String? {
        let (text, selection) = parse(marked)
        return LineMove.move(direction, in: text, selection: selection, keepingTogether: spans).map { render(LineMove.apply($0.edits, to: text), $0.selection) }
    }

    private func duplicate(_ direction: LineMove.Direction, _ marked: String, spans: [ClosedRange<Int>] = []) -> String {
        let (text, selection) = parse(marked)
        let result = LineMove.duplicate(direction, in: text, selection: selection, keepingTogether: spans)
        return render(LineMove.apply(result.edits, to: text), result.selection)
    }

    @Test func singleLineMovesWithTheCaret() {
        #expect(move(.up, "a\nb‸c\nd") == "b‸c\na\nd")
        #expect(move(.down, "a\nb‸c\nd") == "a\nd\nb‸c")
        // Repeated presses keep moving.
        #expect(move(.down, "b‸c\na\nd").flatMap { move(.down, $0) } == "a\nd\nb‸c")
        #expect(move(.down, "a\nd\nb‸c") == nil)
    }

    @Test func selectedLinesMoveTogetherWithTheSelection() {
        #expect(move(.up, "a\n«b\nc»\nd") == "«b\nc»\na\nd")
        #expect(move(.down, "a\n«b\nc»\nd") == "a\nd\n«b\nc»")
        // A partial-line selection moves every line it touches.
        #expect(move(.up, "a\nb«b\ncc»c\nd") == "b«b\ncc»c\na\nd")
        #expect(move(.down, "a\nb«b\ncc»c\nd") == "a\nd\nb«b\ncc»c")
    }

    @Test func aSelectionEndingAtALineStartLeavesThatLine() {
        #expect(move(.up, "a\n«b\n»c\nd") == "«b\n»a\nc\nd")
        #expect(move(.down, "a\n«b\n»c\nd") == "a\nc\n«b\n»d")
        // A caret at a line's start is on that line.
        #expect(move(.up, "a\n‸b") == "‸b\na")
    }

    @Test func firstAndLastLinesStay() {
        #expect(move(.up, "a‸\nb") == nil)
        #expect(move(.down, "a\nb‸") == nil)
        #expect(move(.up, "only‸") == nil)
        #expect(move(.down, "only‸") == nil)
        #expect(move(.up, "‸") == nil)
        #expect(move(.down, "«a\nb»") == nil)
    }

    @Test func theLastLineWithoutALineEndingSwapsEndings() {
        #expect(move(.up, "a\nb‸") == "b‸\na")
        #expect(move(.down, "a‸\nb") == "b\na‸")
        #expect(move(.up, "x\na\n«b\nc»") == "x\n«b\nc»\na")
        #expect(move(.down, "«a\nb»\nc") == "c\n«a\nb»")
        // The whole first line selected with its line ending: only it moves, and the selection
        // stays on its text.
        #expect(move(.down, "«a\n»b") == "b\n«a»")
    }

    @Test func carriageReturnLineFeedsStayIntact() {
        #expect(move(.up, "a\r\nb‸\r\nc") == "b‸\r\na\r\nc")
        #expect(move(.down, "a‸\r\nb\r\nc") == "b\r\na‸\r\nc")
        #expect(move(.up, "a\r\nb‸") == "b‸\r\na")
        #expect(move(.down, "a‸\r\nb") == "b\r\na‸")
        #expect(move(.up, "a\r\n«b\r\nc»") == "«b\r\nc»\r\na")
        // Old Mac line endings are line endings too.
        #expect(move(.up, "a\rb‸") == "b‸\ra")
    }

    @Test func emptyLinesMoveAndAreMovedOver() {
        #expect(move(.up, "a\n‸\nb") == "‸\na\nb")
        #expect(move(.down, "a\n‸\nb") == "a\nb\n‸")
        #expect(move(.down, "a\n\nb‸") == nil)
        #expect(move(.up, "a\n\nb‸") == "a\nb‸\n")
        // Text ending in a line ending has an empty last line, as the editor shows.
        #expect(move(.down, "a‸\nb\n") == "b\na‸\n")
        #expect(move(.down, "b\na‸\n") == "b\n\na‸")
        #expect(move(.up, "b\n\na‸") == "b\na‸\n")
    }

    @Test func offsetsAreUTF16() {
        #expect(move(.up, "ä😀\nb‸") == "b‸\nä😀")
        #expect(move(.down, "ä😀‸\nb") == "b\nä😀‸")
        #expect(move(.up, "a\n«😀»") == "«😀»\na")
    }

    @Test func movingUpThenDownRestoresTheText() {
        let samples = ["a\nb‸\nc", "a\r\nb‸\r\nc", "a\n«b\nc»", "a\r\nb\r\nc‸", "x\n\n«y\n\n»z\n", "a\nb\n‸"]
        for sample in samples {
            guard let up = move(.up, sample) else { Issue.record("\(sample) didn't move"); continue }
            #expect(move(.down, up) == sample)
        }
    }

    @Test func indentationIsKept() {
        #expect(move(.up, "if (true) {\n    $a = 1;\n‸}") == "if (true) {\n‸}\n    $a = 1;")
        #expect(move(.down, "\t$x‸;\n$y;") == "$y;\n\t$x‸;")
    }

    @Test func movesReplaceOnlyTheOtherLines() {
        // The moved lines' characters stay put in the text storage (their folds, hints, and
        // inline values move with them): the edits remove and re-insert the other lines.
        let text = "one\ntwo\nthree\n"
        let up = LineMove.move(.up, in: text, selection: NSRange(location: 5, length: 0))!
        #expect(up.edits == [LineMove.Edit(range: NSRange(location: 0, length: 4), replacement: ""),
                             LineMove.Edit(range: NSRange(location: 4, length: 0), replacement: "one\n")])
        #expect(up.displaced == NSRange(location: 0, length: 4))
        #expect(up.displacedShift == 4)
        let down = LineMove.move(.down, in: text, selection: NSRange(location: 5, length: 0))!
        #expect(down.edits == [LineMove.Edit(range: NSRange(location: 8, length: 6), replacement: ""),
                               LineMove.Edit(range: NSRange(location: 4, length: 0), replacement: "three\n")])
        #expect(down.displaced == NSRange(location: 8, length: 6))
        #expect(down.displacedShift == -4)
        #expect(down.selection == NSRange(location: 11, length: 0))
    }

    @Test func foldedBlocksMoveAndAreMovedOverWhole() {
        // Lines 0–2 are a folded block.
        let block = "f {\n  x\n}"
        #expect(move(.up, block + "\na‸", spans: [0...2]) == "a‸\n" + block)
        #expect(move(.down, "a‸\n" + block, spans: [1...3]) == block + "\na‸")
        // The caret on the block's first line (or its last) moves all of it.
        #expect(move(.up, "a\nf‸ {\n  x\n}\nb", spans: [1...3]) == "f‸ {\n  x\n}\na\nb")
        #expect(move(.down, "a\nf {\n  x\n}‸\nb", spans: [1...3]) == "a\nb\nf {\n  x\n}‸")
        #expect(move(.up, "f‸ {\n  x\n}\nb", spans: [0...2]) == nil)
        // The block a line moves over keeps its characters' order, shifted as a whole.
        let text = block + "\na"
        let result = LineMove.move(.up, in: text, selection: NSRange(location: 11, length: 0), keepingTogether: [0...2])!
        #expect(result.displaced == NSRange(location: 0, length: 10))
        let fold = NSRange(location: 3, length: 5) // "\n  x\n", as `FoldingPlacement` hides it
        let moved = NSRange(location: fold.location + result.displacedShift, length: fold.length)
        #expect((LineMove.apply(result.edits, to: text) as NSString).substring(with: moved) == (text as NSString).substring(with: fold))
        #expect(LineMove.lineSpans(covering: [fold], in: text) == [0...2])
    }

    @Test func duplicatesKeepTheSelectionOnTheOriginal() {
        #expect(duplicate(.up, "a\nb‸\nc") == "a\nb‸\nb\nc")
        #expect(duplicate(.down, "a\nb‸\nc") == "a\nb\nb‸\nc")
        #expect(duplicate(.up, "«a\nb»\nc") == "«a\nb»\na\nb\nc")
        #expect(duplicate(.down, "«a\nb»\nc") == "a\nb\n«a\nb»\nc")
        #expect(duplicate(.down, "a\n«b\n»c") == "a\nb\n«b\n»c")
    }

    @Test func duplicatesOfTheLastLineGetTheTextsLineEnding() {
        #expect(duplicate(.up, "a\nb‸") == "a\nb‸\nb")
        #expect(duplicate(.down, "a\nb‸") == "a\nb\nb‸")
        #expect(duplicate(.down, "a\r\nb‸") == "a\r\nb\r\nb‸")
        #expect(duplicate(.up, "only‸") == "only‸\nonly")
        #expect(duplicate(.down, "‸") == "\n‸")
        #expect(duplicate(.down, "f {\n  x\n}‸", spans: [0...2]) == "f {\n  x\n}\nf {\n  x\n}‸")
    }
}
