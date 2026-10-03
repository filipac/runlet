import Foundation
import Testing
@testable import RunletCore

/// Magic comments (#10): decoding the runner's `probes`/`inline` events, folding hits per
/// editor line (×N, last value, the hover list, final counts), mapping Run Selection lines,
/// the drawn summary, and following lines through edits.
struct InlineValuesTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func hit(_ probe: Int, line: Int, hit: Int, int value: Int? = nil, kind: String = "value", sampled: Bool? = nil, final: Bool? = nil) -> InlineEvent {
        .hit(InlineHit(probe: probe, line: line, kind: kind, hit: hit, t: Double(hit), value: value.map { ValueNode(id: 1, type: .int, scalar: String($0)) }, sampled: sampled, final: final))
    }

    @Test func decodesEvents() throws {
        let probes = try decode(InlineProbesInfo.self, #"""
        {"probes": [{"id": 1, "line": 2, "kind": "value", "comment": "//?"}, {"id": 2, "line": 5, "kind": "time", "comment": "/*?.*/"}],
         "rejected": [{"line": 7, "comment": "/*?*/", "reason": "It is where a value is assigned or declared, not read."}]}
        """#)
        #expect(probes.probes.map(\.id) == [1, 2] && probes.probes[1].kind == "time")
        #expect(probes.rejected.first?.line == 7)

        let value = try decode(InlineHit.self, #"{"probe": 1, "line": 2, "kind": "value", "hit": 3, "t": 1.25, "value": {"id": 1, "type": "string", "scalar": "a", "length": 1}}"#)
        #expect(value.hit == 3 && value.t == 1.25 && value.value?.displayString == "a" && value.final == nil)
        let time = try decode(InlineHit.self, #"{"probe": 2, "line": 5, "kind": "time", "hit": 1, "t": 9.5, "ms": 4.125}"#)
        #expect(time.ms == 4.125 && time.value == nil)
        let failure = try decode(InlineHit.self, #"{"probe": 3, "line": 6, "kind": "value", "hit": 1, "t": 1, "error": {"className": "Error", "message": "Call to undefined method A::nope()"}}"#)
        #expect(failure.error?.message == "Call to undefined method A::nope()")
        let final = try decode(InlineHit.self, #"{"probe": 1, "line": 2, "kind": "value", "hit": 250, "final": true}"#)
        #expect(final.final == true && final.t == nil)
    }

    @Test func foldsHitsPerLine() {
        var values = InlineValues()
        values.apply(.probes(InlineProbesInfo(probes: [
            InlineProbe(id: 1, line: 2, kind: "value", comment: "//?"),
            InlineProbe(id: 2, line: 2, kind: "value", comment: "/*?->count()*/"),
            InlineProbe(id: 3, line: 4, kind: "reached", comment: "//?"),
            InlineProbe(id: 4, line: 9, kind: "value", comment: "//?"),
        ], rejected: [InlineRejection(line: 6, comment: "/*?*/", reason: "Not here.", label: "assigned here")])), editorLine: { $0 })
        for n in 1...3 {
            values.apply(hit(1, line: 2, hit: n, int: n * 10), editorLine: { $0 })
            values.apply(hit(3, line: 4, hit: n, kind: "reached"), editorLine: { $0 })
        }
        values.apply(hit(2, line: 2, hit: 1, int: 7), editorLine: { $0 })

        let line2 = values.probes(onLine: 2)
        #expect(line2.map(\.id) == [1, 2])
        #expect(line2[0].hits == 3 && line2[0].last?.value?.scalar == "30" && line2[0].recent.map(\.number) == [1, 2, 3])
        #expect(values.summary(onLine: 2)?.plainText == "×3 30  ·  7")
        #expect(values.summary(onLine: 4)?.plainText == "×3 ✓")
        // A probe that never ran draws nothing; a rejected comment draws why.
        #expect(values.summary(onLine: 9) == nil)
        #expect(values.summary(onLine: 6)?.plainText == "⚠︎ not shown: assigned here")
        #expect(values.summary(onLine: 6)?.parts.first?.style == .warning)
        #expect(values.hits(onLine: 4) == 3 && values.hits(onLine: 9) == 0)
        #expect(values.lines == [2, 4, 6, 9])
    }

    @Test func capsTheHoverListAndKeepsFinalCounts() {
        var values = InlineValues()
        for n in 1...100 { values.apply(hit(1, line: 3, hit: n, int: n), editorLine: { $0 }) }
        // After 100 hits the runner samples values and sends the final count when it finishes.
        for n in stride(from: 150, through: 5000, by: 50) { values.apply(hit(1, line: 3, hit: n, int: n, sampled: true), editorLine: { $0 }) }
        values.apply(hit(1, line: 3, hit: 5003, final: true), editorLine: { $0 })
        let probe = values.probes(onLine: 3)[0]
        #expect(probe.hits == 5003 && probe.isFinal)
        #expect(probe.last?.number == 5000 && probe.last?.value?.scalar == "5000")
        #expect(probe.recent.count <= InlineValues.maxRecent + 20)
        #expect(probe.recent.first?.number == 1 && probe.recent.last?.number == 5000)
        #expect(values.summary(onLine: 3)?.plainText == "×5003 5000")
    }

    @Test func timesErrorsAndCompactValues() {
        var values = InlineValues()
        values.apply(.hit(InlineHit(probe: 1, line: 1, kind: "time", hit: 1, t: 3, ms: 1234.5)), editorLine: { $0 })
        values.apply(.hit(InlineHit(probe: 2, line: 2, kind: "time", hit: 1, t: 3, ms: 0.4567)), editorLine: { $0 })
        values.apply(.hit(InlineHit(probe: 3, line: 3, kind: "value", hit: 1, error: .init(className: "BadMethodCallException", message: "Method nope does not exist."))), editorLine: { $0 })
        #expect(values.summary(onLine: 1)?.plainText == "⏱ 1.23 s")
        #expect(values.summary(onLine: 2)?.plainText == "⏱ 0.46 ms")
        #expect(values.summary(onLine: 3)?.plainText == "⚠︎ BadMethodCallException: Method nope does not exist.")
        #expect(values.summary(onLine: 3)?.parts.first?.style == .error)

        let list = ValueNode(id: 1, type: .array, entries: [0, 1, 2].map { .init(key: String($0), keyType: "int", value: ValueNode(id: $0 + 2, type: .int, scalar: String($0 + 1))) })
        #expect(list.compactSummary() == "[1, 2, 3]")
        var map = ValueNode(id: 1, type: .array, entries: [.init(key: "id", keyType: "string", value: ValueNode(id: 2, type: .int, scalar: "7"))])
        map.count = 5
        #expect(map.compactSummary() == "[\"id\" => 7, …] (5)")
        var user = ValueNode(id: 1, type: .object, className: "App\\Models\\User")
        user.count = 31
        #expect(user.compactSummary() == "User {31}")
        #expect(ValueNode(id: 1, type: .string, scalar: "a\nb").compactSummary() == "\"a\\nb\"")
        // Eloquent models show their attributes, collections their items.
        func attribute(_ key: String, _ node: ValueNode) -> ValueNode.Entry { .init(key: key, keyType: "string", value: node) }
        let attributes = ValueNode(id: 2, type: .array, entries: [attribute("id", ValueNode(id: 3, type: .int, scalar: "1")), attribute("name", ValueNode(id: 4, type: .string, scalar: "Ada"))])
        let model = ValueNode(id: 1, type: .object, className: "App\\Models\\User", entries: [.init(key: "attributes", keyType: "property", visibility: "protected", value: attributes)])
        #expect(model.compactSummary() == "User {id: 1, name: \"Ada\"}")
        var items = ValueNode(id: 5, type: .array, entries: [.init(key: "0", keyType: "int", value: model)])
        items.count = 1
        let collection = ValueNode(id: 6, type: .object, className: "Illuminate\\Database\\Eloquent\\Collection", entries: [.init(key: "items", keyType: "property", visibility: "protected", value: items)])
        #expect(collection.compactSummary() == "Collection(1) [User {id: 1, name: \"Ada\"}]")
    }

    @Test func runSelectionLinesMapToTheEditor() throws {
        // The selection started on editor line 12; the runner reports lines of the selected code.
        let target = TargetSnapshot(kind: .local, label: "t", targetId: "t", workingDirectory: "/tmp", phpExecutable: "php")
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "$a = 1; //?\n$b = 2; //?",
                                 selection: SourceSelection(startLine: 12, startColumn: 5, utf16Range: NSRangeCodable(location: 300, length: 22)))
        var values = InlineValues()
        values.apply(.probes(InlineProbesInfo(probes: [InlineProbe(id: 1, line: 1, kind: "value", comment: "//?"), InlineProbe(id: 2, line: 2, kind: "value", comment: "//?")], rejected: [InlineRejection(line: 2, comment: "/*?*/", reason: "r")])), editorLine: request.editorLine(forSnippetLine:))
        values.apply(hit(1, line: 1, hit: 1, int: 1), editorLine: request.editorLine(forSnippetLine:))
        values.apply(hit(2, line: 2, hit: 1, int: 2), editorLine: request.editorLine(forSnippetLine:))
        #expect(values.summary(onLine: 12)?.plainText == "1")
        #expect(values.summary(onLine: 13)?.plainText == "2  ·  ⚠︎ r")
        #expect(values.lines == [12, 13])
        values.removeLine(12)
        #expect(values.summary(onLine: 12) == nil && values.lines == [13])
    }

    @Test func settingsAndRequestsKeepTheMagicCommentOptions() throws {
        // Older settings and requests (without the keys) read as on.
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.magicComments)
        var changed = AppSettings()
        changed.magicComments = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(!decoded.magicComments)

        let target = TargetSnapshot(kind: .local, label: "t", targetId: "t", workingDirectory: "/tmp", phpExecutable: "php")
        let off = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "1", magicComments: false)
        #expect(try JSONDecoder().decode(RunRequest.self, from: JSONEncoder().encode(off)).magicComments == false)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        json["magicComments"] = nil
        #expect(try JSONDecoder().decode(RunRequest.self, from: JSONSerialization.data(withJSONObject: json)).magicComments == true)
    }

    @Test func tracksLinesThroughEdits() {
        let original = "a = 1; //?\nb = 2;\nc = 3; //?\n" as NSString
        var tracker = InlineLineTracker(text: original, lineNumbers: [1, 3])
        #expect(tracker.range(ofLine: 1) == NSRange(location: 0, length: 10))
        #expect(tracker.range(ofLine: 3) == NSRange(location: 18, length: 10))

        func apply(_ range: NSRange, _ replacement: String, to text: inout NSString) -> [Int] {
            let next = text.replacingCharacters(in: range, with: replacement) as NSString
            text = next
            return tracker.edit(range: range, replacementLength: (replacement as NSString).length, newText: next)
        }
        var text = original
        // Typing on an unrelated line moves the lines below it and keeps both.
        #expect(apply(NSRange(location: 11, length: 0), "xx", to: &text) == [])
        #expect(tracker.range(ofLine: 1) == NSRange(location: 0, length: 10))
        #expect(tracker.range(ofLine: 3) == NSRange(location: 20, length: 10))
        // A new line above a tracked line moves it down.
        #expect(apply(NSRange(location: 0, length: 0), "\n", to: &text) == [])
        #expect(tracker.range(ofLine: 1) == NSRange(location: 1, length: 10))
        #expect(text.substring(with: tracker.range(ofLine: 1)!) == "a = 1; //?")
        // A line break typed at the end of a tracked line keeps it.
        #expect(apply(NSRange(location: 11, length: 0), "\n", to: &text) == [])
        #expect(tracker.range(ofLine: 1) == NSRange(location: 1, length: 10))
        #expect(text.substring(with: tracker.range(ofLine: 3)!) == "c = 3; //?")
        // Editing a tracked line drops it (its values are stale).
        let line3 = tracker.range(ofLine: 3)!
        #expect(apply(NSRange(location: line3.location + 4, length: 1), "9", to: &text) == [3])
        #expect(tracker.range(ofLine: 3) == nil)
        // Typing right after a tracked line's text (before its line break) changes it too.
        #expect(apply(NSRange(location: NSMaxRange(tracker.range(ofLine: 1)!), length: 0), ";", to: &text) == [1])
        #expect(tracker.isEmpty)

        // Replacing everything (an external reload, Undo of a paste) drops every line.
        var all = InlineLineTracker(text: original, lineNumbers: [1, 3])
        #expect(all.edit(range: NSRange(location: 0, length: original.length), replacementLength: 3, newText: "new") == [1, 3])
        // A run follows the editor lines its magic comments came from, and only lines whose text
        // holds the code that ran.
        let editor = "a = 1; //?\nb = 2; //?\nc = 3;\n" as NSString
        let whole = InlineLineTracker.forRun(code: editor as String, selection: nil, editorText: editor)
        #expect(Set(whole.lines.keys) == [1, 2])
        let selected = InlineLineTracker.forRun(code: "2; //?\nc", selection: SourceSelection(startLine: 2, startColumn: 5, utf16Range: NSRangeCodable(location: 15, length: 8)), editorText: editor)
        #expect(Set(selected.lines.keys) == [2])
        let elsewhere = InlineLineTracker.forRun(code: "x(); //?\ny(); //?", selection: nil, editorText: editor)
        #expect(elsewhere.isEmpty)
        // A last line without a line break is tracked too.
        let tail = InlineLineTracker(text: "x\ny //?" as NSString, lineNumbers: [2])
        #expect(tail.range(ofLine: 2) == NSRange(location: 2, length: 5))
    }
}
