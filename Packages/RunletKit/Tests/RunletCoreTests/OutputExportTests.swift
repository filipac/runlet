import Foundation
import Testing
@testable import RunletCore

struct OutputExportTests {
    func node(_ json: String) throws -> ValueNode {
        try JSONDecoder().decode(ValueNode.self, from: Data(json.utf8))
    }

    /// Two Eloquent models in a collection: rows are their attributes.
    var models: String {
        func model(_ id: Int, _ name: String, _ price: String) -> String {
            #"{"id":3,"type":"object","className":"App\\Models\\Widget","entries":[{"key":"attributes","keyType":"property","visibility":"protected","value":{"id":5,"type":"array","entries":[{"key":"id","keyType":"string","value":{"id":6,"type":"int","scalar":"\#(id)"}},{"key":"name","keyType":"string","value":{"id":7,"type":"string","scalar":"\#(name)"}},{"key":"price","keyType":"string","value":\#(price)},{"key":"tags","keyType":"string","value":{"id":9,"type":"array","entries":[{"key":"0","keyType":"int","value":{"id":10,"type":"string","scalar":"new"}}]}}]}}]}"#
        }
        return #"{"id":1,"type":"object","className":"Illuminate\\Database\\Eloquent\\Collection","entries":[{"key":"items","keyType":"property","visibility":"protected","value":{"id":2,"type":"array","entries":[{"key":"0","keyType":"int","value":"# + model(1, #"O'Hara \"x\""#, #"{"id":8,"type":"float","scalar":"2.5"}"#) + #"},{"key":"1","keyType":"int","value":"# + model(2, "Gear", #"{"id":8,"type":"null"}"#) + "}]}}]}"
    }

    @Test func tableRowsCopyAsJSONAndPHPWithKeysAndTypes() throws {
        let table = try #require(ValueTable.make(from: try node(models)))
        #expect(table.rowFields.count == 2)
        let row = table.rowFields[0]
        #expect(ValueExport.json(fields: row) == """
        {
          "id": 1,
          "name": "O'Hara \\"x\\"",
          "price": 2.5,
          "tags": [
            "new"
          ]
        }
        """)
        #expect(ValueExport.json(fields: table.rowFields[1], pretty: false) == #"{"id":2,"name":"Gear","price":null,"tags":["new"]}"#)
        #expect(ValueExport.php(fields: row) == """
        [
            'id' => 1,
            'name' => 'O\\'Hara "x"',
            'price' => 2.5,
            'tags' => [
                'new',
            ],
        ]
        """)
    }

    @Test func valuesExportWithoutCallingAnything() throws {
        let object = try node(#"{"id":1,"type":"object","className":"App\\Money","entries":[{"key":"cents","keyType":"property","visibility":"private","value":{"id":2,"type":"int","scalar":"150"}}]}"#)
        #expect(ValueExport.php(object) == "/* App\\Money */ [\n    'cents' => 150,\n]")
        #expect(ValueExport.json(object, pretty: false) == #"{"cents":150}"#)
        let map = try node(#"{"id":1,"type":"array","entries":[{"key":"5","keyType":"int","value":{"id":2,"type":"bool","scalar":"true"}},{"key":"a\\b","keyType":"string","value":{"id":3,"type":"enum","className":"App\\Status","scalar":"Active","backingValue":"active"}}]}"#)
        #expect(ValueExport.php(map) == "[\n    5 => true,\n    'a\\\\b' => \\App\\Status::Active,\n]")
        #expect(ValueExport.json(map, pretty: false) == #"{"5":true,"a\\b":"active"}"#)
        #expect(ValueExport.json(try node(#"{"id":1,"type":"float","scalar":"NAN"}"#)) == "\"NAN\"")
        #expect(ValueExport.php(try node(#"{"id":1,"type":"closure","summary":"/app/x.php:3"}"#)) == "null /* Closure (/app/x.php:3) */")
    }

    @Test func markdownFencesAndTables() throws {
        #expect(MarkdownText.fence("echo `x`;\n", language: "php") == "```php\necho `x`;\n```")
        #expect(MarkdownText.fence("a ``` b") == "````\na ``` b\n````")
        let table = try #require(ValueTable.make(from: try node(models)))
        let markdown = MarkdownText.table(table)
        #expect(markdown.hasPrefix("| # | id | name | price | tags |\n| --- | --- | --- | --- | --- |\n| 0 | 1 | O'Hara \"x\" | 2.5 |"))
        #expect(MarkdownText.table(table, maxRows: 1).hasSuffix("_1 more rows not shown._"))
        #expect(MarkdownText.value(try node(#"{"id":1,"type":"int","scalar":"42"}"#)) == "```\n42\n```")
        #expect(MarkdownText.inline("a|b *c*\nd") == "a\\|b \\*c\\* d")
    }

    @Test func linksNeedTheirScheme() {
        let text = "See https://laravel.com/docs?x=1, mailto:ada@example.com, and example.com or ftp://files.example."
        let links = OutputLinks.links(in: text)
        #expect(links.map(\.url.absoluteString) == ["https://laravel.com/docs?x=1", "mailto:ada@example.com"])
        #expect((text as NSString).substring(with: links[0].range) == "https://laravel.com/docs?x=1")
        #expect(OutputLinks.links(in: String(repeating: "x", count: OutputLinks.maxScannedLength + 1) + " https://a.b").isEmpty)
    }
}
