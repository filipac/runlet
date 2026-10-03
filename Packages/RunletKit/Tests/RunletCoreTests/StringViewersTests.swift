import Foundation
import Testing
@testable import RunletCore

struct StringViewersTests {
    func viewers(_ text: String) -> StringViewers? { StringViewers(node: ValueNode(id: 1, type: .string, scalar: text)) }

    @Test func JSONTreeTypesAndPrettySource() throws {
        let source = #"{"name":"Widget","flags":[true,null,3],"large":18446744073709551615,"precise":1.234567890123456789}"#
        let value = try #require(viewers(source))
        let tree = try #require(value.jsonTree)
        #expect(tree.entries?.map(\.key) == ["name", "flags", "large", "precise"])
        #expect(tree.entries?[1].value.entries?.map(\.value.type) == [.bool, .null, .int])
        let pretty = try #require(value.prettyJSON)
        #expect(pretty.contains("18446744073709551615"))
        #expect(tree.entries?[2].value.scalar == "18446744073709551615")
        #expect(tree.entries?[3].value.scalar == "1.234567890123456789")
        #expect(pretty.contains("1.234567890123456789"))
        #expect(pretty.contains("\n  \"name\": \"Widget\""))
        #expect(try MCPJSON.parse(pretty) == MCPJSON.parse(source))
        #expect(viewers("\u{FEFF} {\"a\":1}")?.jsonTree?.entries?.first?.value.scalar == "1")
        #expect(viewers("true")?.jsonTree?.scalar == "true")
        #expect(viewers(#""hello""#)?.jsonTree?.scalar == "hello")
        #expect(viewers("[{}, []]")?.prettyJSON == "[\n  {},\n  []\n]")
        #expect(viewers(#"{"x":"[,]\\\""}"#)?.jsonTree != nil)
    }

    @Test func boundedAndIncompleteStrings() throws {
        #expect(viewers(String(repeating: "x", count: 65_537)) == nil)
        #expect(viewers("{")?.jsonTree == nil)
        #expect(viewers(String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33))?.jsonTree == nil)
        #expect(viewers("[" + Array(repeating: "0", count: 2_049).joined(separator: ",") + "]")?.jsonTree == nil)
        let wide = try #require(viewers("[" + Array(repeating: "0", count: 250).joined(separator: ",") + "]")?.jsonTree)
        #expect(wide.entries?.count == 200)
        #expect(wide.truncation?.omitted == 50)
        var node = ValueNode(id: 1, type: .string, scalar: "<p>Partial</p>")
        node.truncation = .init(reason: "length", omitted: 12)
        #expect(StringViewers(node: node)?.html == nil)
        node.scalar = "{}"
        #expect(StringViewers(node: node)?.jsonTree == nil)
        #expect(viewers(String(repeating: "line\n", count: 11))?.isLong == true)
        #expect(viewers("short")?.isLong == false)
    }

    @Test func imageEncodingsAndHTML() throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        #expect(viewers(png.base64EncodedString())?.image?.kind == .png)
        #expect(viewers("data:image/png;base64," + png.base64EncodedString())?.image?.data == png)
        #expect(viewers(Data([255,216,255,224]).base64EncodedString())?.image?.kind == .jpeg)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>"
        #expect(viewers(Data(svg.utf8).base64EncodedString())?.image?.kind == .svg)
        #expect(viewers(svg)?.image?.kind == .svg)
        var binary = ValueNode(id: 1, type: .string, scalar: png.base64EncodedString())
        binary.encoding = "base64"
        #expect(StringViewers(node: binary)?.image?.kind == .png)
        binary.truncation = .init(reason: "length", omitted: 10)
        #expect(StringViewers(node: binary)?.image == nil)
        #expect(viewers("data:image/gif;base64," + png.base64EncodedString())?.image == nil)
        #expect(viewers("!" + png.base64EncodedString())?.image == nil)
        #expect(viewers("ordinary text")?.image == nil)
        #expect(viewers(" <DIV>Preview</DIV> ")?.html != nil)
        #expect(viewers("<not-html>")?.html == nil)
    }

    @Test func literalSearchUnicodeAndNoMatch() {
        #expect(StringSearch.matches(in: "😀 Foo foo FOO", query: "foo") == [NSRange(location: 3, length: 3), NSRange(location: 7, length: 3), NSRange(location: 11, length: 3)])
        #expect(StringSearch.matches(in: "a.b a*b", query: "a.b").count == 1)
        #expect(StringSearch.matches(in: "aaa", query: "aa").count == 1)
        #expect(StringSearch.matches(in: "anything", query: "").isEmpty)
        #expect(StringSearch.matches(in: "anything", query: "missing").isEmpty)
    }
}
