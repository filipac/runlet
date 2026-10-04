import Foundation
@testable import RunletCore
import Testing

/// MongoDB project and personal snippets (#207): the `//` metadata block, inputs filled as JSON
/// values, and `.mongodb` files that round-trip.
struct MongoSnippetsTests {
    static let file = """
    // @title Paid orders of
    //   a customer
    // @description The newest first
    // @connection Documents (saved)
    // @input string $customer "Customer" = "c-1001"
    // @input int $limit "How many" = 20

    {
      "collection": "orders",
      "operation": "find",
      "filter": { "customer": { "$input": "customer" }, "status": "paid", "note": "{\\"$input\\": \\"customer\\"}" },
      "sort": { "placed_at": -1, "_id": 1 },
      "limit": {"$input":"limit"}
    }
    """

    @Test func headerAndBodySplit() throws {
        let (header, body) = DatabaseSnippetHeader.split(Substring("\n\n" + Self.file), marker: "//")
        let parsed = try #require(header)
        #expect(parsed.title == "Paid orders of a customer")
        #expect(parsed.description == "The newest first")
        #expect(parsed.connection == "Documents (saved)")
        #expect(parsed.inputs == [#"string $customer "Customer" = "c-1001""#, #"int $limit "How many" = 20"#])
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\n  \"collection\": \"orders\""))
        // `@label` is the same as `@title`; a comment block without tags isn't metadata.
        #expect(DatabaseSnippetHeader.split("// @label Orders\n{}", marker: "//").header?.title == "Orders")
        let plain = DatabaseSnippetHeader.split("// just a note\n{}", marker: "//")
        #expect(plain.header == nil && plain.body == "// just a note\n{}")
        // #205: the same keys after `#` for .redis files.
        let redis = DatabaseSnippetHeader.split("# @title Session\n# @connection cache\n# @input string $user \"User\"\nGET session:{user}\n", marker: "#")
        #expect(redis.header?.title == "Session" && redis.header?.connection == "cache" && redis.header?.inputs.count == 1)
        #expect(redis.body == "GET session:{user}\n")
        #expect(DatabaseSnippetHeader.marker(for: .mongodb) == "//" && DatabaseSnippetHeader.marker(for: .redis) == "#" && DatabaseSnippetHeader.marker(for: .sql) == nil)
    }

    @Test func inputsFillPlaceholdersAsJSONValues() throws {
        let (inputs, body, _) = MongoSnippets.parse(Self.file)
        #expect(inputs.inputs.map(\.name) == ["customer", "limit"] && inputs.problems.isEmpty)
        #expect(!body.contains("@title"))
        let filled = MongoSnippets.substitute(body, values: ["customer": .string(#"o"Brien\ "} {"$where": "1""#), "limit": .int(5)])
        // The value is one JSON string, however it's written: nothing it contains becomes JSON.
        #expect(filled.contains(#""customer": "o\"Brien\\ \"} {\"$where\": \"1\"""#), "\(filled)")
        #expect(filled.contains(#""limit": 5"#))
        // A placeholder written inside a string is text, and stays.
        #expect(filled.contains(#""note": "{\"$input\": \"customer\"}""#))
        // Key order and layout stay as written.
        #expect(filled.contains(#""sort": { "placed_at": -1, "_id": 1 }"#))
        let query = try MongoQuery(filled)
        #expect(query.operation == "find" && query.collection == "orders" && query.effect == .read)
        // Values of every kind; a placeholder without a value stays.
        #expect(MongoSnippets.substitute(#"[{"$input":"a"},{"$input":"b"},{"$input":"c"},{"$input":"d"},{"$input":"missing"}]"#,
                                         values: ["a": .bool(true), "b": .float(2.5), "c": .float(3), "d": .string("x/y")])
                == #"[true,2.5,3.0,"x/y",{"$input":"missing"}]"#)
        #expect(MongoSnippets.jsonLiteral(.float(.nan)) == "null")
    }

    @Test func projectFilesLoadAndRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p207-snippets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.file.utf8).write(to: folder.appendingPathComponent("paid-orders.mongodb"))
        let loaded = try #require(ProjectSnippets.load(projectRoot: root).first)
        #expect(loaded.language == .mongodb && loaded.label == "Paid orders of a customer" && loaded.description == "The newest first")
        #expect(loaded.connection == .saved(name: "Documents"))
        #expect(loaded.inputs.inputs.map(\.name) == ["customer", "limit"])
        #expect(loaded.code.hasPrefix("{") && !loaded.code.contains("@input"))
        // A personal copy keeps the inputs as `// @input` lines.
        #expect(loaded.personalCode.hasPrefix("// @input string $customer \"Customer\" = \"c-1001\"\n// @input int $limit \"How many\" = 20\n\n{"))
        let personal = Snippet(label: loaded.label, code: loaded.personalCode, language: .mongodb, connection: loaded.connection)
        #expect(personal.inputs.inputs.map(\.name) == ["customer", "limit"] && personal.openingCode == loaded.code)

        // Saving a MongoDB tab writes `// @title`, `// @description`, `// @connection`, and the query.
        #expect(ProjectSnippets.fileName(forLabel: "Paid orders!", language: .mongodb) == "paid-orders.mongodb")
        let url = try ProjectSnippets.save(label: "Open orders", description: "Not yet paid", code: #"{"collection":"orders","operation":"find","filter":{"status":"open"}}"#,
                                           projectRoot: root, language: .mongodb, connection: .named("mongodb"))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "// @title Open orders\n// @description Not yet paid\n// @connection mongodb\n\n{\"collection\":\"orders\",\"operation\":\"find\",\"filter\":{\"status\":\"open\"}}\n", "\(written)")
        let reread = ProjectSnippets.parse(written, fileURL: url)
        #expect(reread.label == "Open orders" && reread.description == "Not yet paid" && reread.connection == .named("mongodb") && reread.language == .mongodb)
        #expect(try MongoQuery(reread.code).collection == "orders")
        // A tab whose text already has inputs keeps them.
        let withInputs = ProjectSnippets.fileContents(label: "By status", description: nil, code: "// @input string $status \"Status\"\n\n{\"collection\":\"orders\",\"operation\":\"find\",\"filter\":{\"status\":{\"$input\":\"status\"}}}", language: .mongodb)
        #expect(withInputs.hasPrefix("// @title By status\n// @input string $status \"Status\"\n\n{"))
        #expect(throws: ProjectSnippets.SaveError.self) { try ProjectSnippets.save(label: "x", description: nil, code: "{}", projectRoot: root, fileName: "x.php", language: .mongodb) }
    }
}
