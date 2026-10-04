import Foundation
import Testing
@testable import RunletCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

struct InspectorDecodingTests {
    @Test func decodesEachRecordKind() throws {
        let query = try decode(InspectorRecord.self, #"""
        {"index": 1, "section": "Queries", "kind": "query", "inSnippet": true, "snippetLine": 4,
         "data": {"sql": "select * from users where id = ? and email = ?", "bindings": [{"type": "int", "value": "7"}, {"type": "string", "value": "a@b.c"}],
                  "timeMs": 0.42, "connection": "mysql", "driver": "mysql", "omittedBindings": 2}}
        """#)
        #expect(query.index == 1 && query.section == "Queries" && query.snippetLine == 4)
        let record = try #require(query.query)
        #expect(record.timeMs == 0.42 && record.connection == "mysql" && record.omittedBindings == 2)
        #expect(record.interpolatedSQL == "select * from users where id = 7 and email = 'a@b.c'")

        let mail = try decode(InspectorRecord.self, #"""
        {"index": 2, "section": "Mail", "kind": "mail", "file": "/app/routes.php", "line": 9,
         "data": {"subject": "Hi", "to": [{"address": "ada@example.com", "name": "Ada"}], "html": "<p>x</p>", "intercepted": true,
                  "attachments": [{"filename": "a.pdf", "contentType": "application/pdf", "size": 12}]}}
        """#)
        let message = try #require(mail.mail)
        #expect(message.intercepted && !message.queued)
        #expect(message.to.first?.display == "Ada <ada@example.com>")
        #expect(message.cc.isEmpty && message.from.isEmpty)
        #expect(message.attachments.first?.filename == "a.pdf")
        #expect(message.summary == "“Hi” to Ada <ada@example.com>")
        #expect(mail.file == "/app/routes.php" && mail.line == 9)
        #expect(message.caller == nil && message.error == nil && !message.failed)

        // WordPress (#192): who sent it, and why sending failed.
        let failed = try #require(try decode(InspectorRecord.self, #"""
        {"index": 7, "section": "Mail", "kind": "mail", "data": {"subject": "Receipt", "mailer": "wp_mail", "caller": "plugin acme-shop (src/Mailer.php:42)",
                  "error": "SMTP connect() failed.", "intercepted": false}}
        """#).mail)
        #expect(failed.caller == "plugin acme-shop (src/Mailer.php:42)" && failed.error == "SMTP connect() failed." && failed.failed)

        let log = try decode(InspectorRecord.self, #"{"index": 3, "section": "Log", "kind": "log", "data": {"level": "error", "message": "Boom", "context": {"id": 1, "type": "array", "count": 0, "entries": []}}}"#)
        guard case .log(let entry) = log.content else { Issue.record("log"); return }
        #expect(entry.level == "error" && entry.context?.type == .array)

        let value = try decode(InspectorRecord.self, #"{"index": 4, "section": "Cache", "kind": "value", "title": "hit users", "data": {"value": {"id": 1, "type": "int", "scalar": "3"}}}"#)
        #expect(value.title == "hit users")
        #expect(value.content == .value(ValueNode(id: 1, type: .int, scalar: "3")))

        let html = try decode(InspectorRecord.self, #"{"index": 5, "section": "HTML", "kind": "html", "title": "Page", "data": {"html": "<b>x</b>", "omittedBytes": 10}}"#)
        #expect(html.content == .html(HTMLRecord(html: "<b>x</b>", omittedBytes: 10)))

        let future = try decode(InspectorRecord.self, #"{"index": 6, "section": "HTTP", "kind": "request", "data": {"url": "https://example.com"}}"#)
        #expect(future.content == .unknown(kind: "request"))
    }

    @Test func decodesInfoPreviewsAndTolerantOptions() throws {
        let info = try decode(InspectorInfo.self, #"{"sections": ["Queries", "Mail"], "interceptMail": true, "interceptingMail": false, "driverName": "Symfony"}"#)
        #expect(info.interceptionUnsupported && info.interceptMailReason == nil)
        #expect(try decode(InspectorInfo.self, "{}").sections.isEmpty)
        let reason = try decode(InspectorInfo.self, #"{"sections": ["Mail"], "interceptMail": true, "interceptingMail": false, "driverName": "WordPress", "interceptMailReason": "A plugin (acme-smtp) replaces wp_mail(); Runlet can't stop its mail."}"#)
        #expect(reason.interceptionUnsupported && reason.interceptMailReason?.contains("acme-smtp") == true)

        let result = try decode(ResultInfo.self, #"{"hasValue": true, "value": {"id": 1, "type": "object", "className": "App\\Mail\\Welcome"}, "preview": {"kind": "mail", "subject": "Welcome", "html": "<h1>Hi</h1>"}}"#)
        #expect(result.preview?.subject == "Welcome" && result.preview?.html == "<h1>Hi</h1>")
        #expect(try decode(ResultInfo.self, #"{"hasValue": false}"#).preview == nil)

        // Requests saved before the inspector existed decode with its defaults.
        let options = try decode(RunInspectorOptions.self, #"{"interceptMail": true}"#)
        #expect(options == RunInspectorOptions(enabled: true, interceptMail: true, previews: true))
    }

    @Test func inspectionGroupsSectionsAndMergesLimits() {
        var inspection = RunInspection()
        #expect(inspection.isEmpty)
        inspection.apply(.ready(InspectorInfo(sections: ["Log", "Queries", "Cache"], interceptMail: true, interceptingMail: true)))
        inspection.apply(.record(InspectorRecord(index: 1, section: "Cache", content: .value(ValueNode(id: 1, type: .null)))))
        inspection.apply(.record(InspectorRecord(index: 2, section: "Queries", content: .query(QueryRecord(sql: "select 1", timeMs: 1.5)))))
        inspection.apply(.record(InspectorRecord(index: 3, section: "Queries", content: .query(QueryRecord(sql: "select 2", timeMs: 2)))))
        inspection.apply(.record(InspectorRecord(index: 4, section: "Mail", content: .mail(MailRecord(subject: "a", intercepted: true)))))
        inspection.apply(.record(InspectorRecord(index: 5, section: "Mail", content: .mail(MailRecord(subject: "b", intercepted: false, queued: true)))))
        inspection.apply(.limit(RecordLimitInfo(section: "Queries", omitted: 3, reason: "count")))
        inspection.apply(.limit(RecordLimitInfo(section: "Queries", omitted: 2, reason: "app")))
        #expect(inspection.sections == ["Queries", "Mail", "Log", "Cache"])
        #expect(inspection.records(in: "Queries").map(\.index) == [2, 3])
        #expect(inspection.queryTimeMs == 3.5)
        #expect(inspection.interceptedMailCount == 1)
        #expect(inspection.omitted(in: "Queries")?.omitted == 5)
        #expect(inspection.records(in: "Missing").isEmpty)
    }
}

struct InspectorSettingsTests {
    @Test func settingsDefaultsAndPerTargetMailInterception() throws {
        let settings = try decode(AppSettings.self, "{}")
        #expect(settings.runInspector && settings.renderPreviews && !settings.interceptMail)
        let decoded = try decode(AppSettings.self, #"{"runInspector": false, "interceptMail": true, "renderPreviews": false}"#)
        #expect(!decoded.runInspector && decoded.interceptMail && !decoded.renderPreviews)

        var project = LocalProject(name: "app", path: "/tmp/app")
        let profile = DockerProfile(name: "api", identity: ContainerIdentity(containerName: "api"), workingDirectory: "/var/www")
        project.interceptMail = true
        let library = TargetLibrary(localProjects: [project], dockerProfiles: [profile])
        #expect(library.interceptMail(for: .local(project.id), global: false))
        #expect(!library.interceptMail(for: .docker(profile.id), global: false))
        #expect(library.interceptMail(for: .docker(profile.id), global: true))
        #expect(library.interceptMail(for: .sandbox, global: true))
        var host = SSHProfile(name: "prod", host: "app-prod", remoteDirectory: "/srv/app")
        host.interceptMail = true
        let withHost = TargetLibrary(localProjects: [project], dockerProfiles: [profile], sshProfiles: [host])
        #expect(withHost.interceptMail(for: .ssh(host.id), global: false))
        let roundTrip = try JSONDecoder().decode(SSHProfile.self, from: JSONEncoder().encode(host))
        #expect(roundTrip.interceptMail == true)
        // Saved projects without the field keep following the global setting.
        let saved = try decode(LocalProject.self, #"{"id": "\#(UUID().uuidString)", "name": "x", "path": "/x", "revision": 1}"#)
        #expect(saved.interceptMail == nil)
    }
}

struct SQLTextTests {
    typealias Binding = QueryRecord.Binding

    @Test func inlinesPositionalBindingsOutsideQuotesAndComments() {
        let sql = #"select '?', "a?b", `c?` from t -- why?\n where a = ? and b = ? /* ? */ and c = ?? and d = ?"#
            .replacingOccurrences(of: #"\n"#, with: "\n")
        let bindings = [Binding(type: "string", value: "O'Hara"), Binding(type: "null"), Binding(type: "bool", value: "true")]
        #expect(SQLText.interpolate(sql, bindings: bindings) == "select '?', \"a?b\", `c?` from t -- why?\n where a = 'O''Hara' and b = NULL /* ? */ and c = ? and d = 1")
        #expect(SQLText.interpolate("where flag = ?", bindings: [Binding(type: "bool", value: "false")], driver: "pgsql") == "where flag = false")
        // Missing bindings leave the placeholder.
        #expect(SQLText.interpolate("a = ? and b = ?", bindings: [Binding(type: "int", value: "1")]) == "a = 1 and b = ?")
    }

    @Test func namedBindingsAndPostgresCasts() {
        let bindings = [Binding(type: "string", value: "x", name: "email"), Binding(type: "int", value: "2", name: "id")]
        #expect(SQLText.interpolate("select :id::text where email = :email and :missing", bindings: bindings) == "select 2::text where email = 'x' and :missing")
    }

    @Test func mysqlBackslashEscapesStayInsideStrings() {
        let sql = #"select 'it\'s ?' , ?"#
        #expect(SQLText.interpolate(sql, bindings: [Binding(type: "int", value: "5")], driver: "mysql") == #"select 'it\'s ?' , 5"#)
    }

    @Test func literalsForEveryType() {
        #expect(Binding(type: "binary", size: 16).sqlLiteral() == "<binary 16 bytes>")
        #expect(Binding(type: "datetime", value: "2026-10-02 10:00:00").sqlLiteral() == "'2026-10-02 10:00:00'")
        #expect(Binding(type: "string", value: "abc", omittedBytes: 100).sqlLiteral() == "'abc…(+100 bytes)'")
        #expect(Binding(type: "float", value: "1.5").sqlLiteral() == "1.5")
        #expect(Binding(type: "object", value: "App\\Money").sqlLiteral() == "<object App\\Money>")
        #expect(Binding(type: "string", value: "a").displayValue == "\"a\"")
    }

    @Test func fingerprintsGroupSimilarStatements() {
        #expect(SQLText.fingerprint("SELECT * FROM posts WHERE id = 12") == SQLText.fingerprint("select *  from posts where id = 7"))
        #expect(SQLText.fingerprint("select * from t where id in (1, 2, 3) and name = 'x'") == "select * from t where id in (?) and name = ?")
        #expect(SQLText.fingerprint("select * from t1") != SQLText.fingerprint("select * from t2"))
        #expect(SQLText.isSelect("  (SELECT 1)") && SQLText.isSelect("with x as (select 1) select * from x") && !SQLText.isSelect("update t set a = 1"))
    }
}

struct QueryAnalysisTests {
    func query(_ sql: String, _ id: String? = nil, ms: Double? = 1) -> QueryRecord {
        QueryRecord(sql: sql, bindings: id.map { [QueryRecord.Binding(type: "int", value: $0)] } ?? [], timeMs: ms)
    }

    @Test func flagsNPlusOneAndDuplicates() {
        let queries: [(index: Int, query: QueryRecord)] = [
            (1, query("select * from users")),
            (2, query("select * from posts where user_id = ?", "1", ms: 2)),
            (3, query("select * from posts where user_id = ?", "2")),
            (4, query("select * from posts where user_id = ?", "3")),
            (5, query("select * from settings where id = ?", "1", ms: nil)),
            (6, query("select * from settings where id = ?", "1", ms: 4)),
            (7, query("update users set seen = 1")),
        ]
        let analysis = QueryAnalysis(queries)
        #expect(analysis.count == 7)
        #expect(analysis.totalMs == 10)
        #expect(analysis.slowestIndex == 6)
        #expect(analysis.groups.map(\.count) == [1, 3, 2, 1])
        #expect(analysis.group(of: 3)?.hints == [.nPlusOne(count: 3)])
        #expect(analysis.group(of: 5)?.hints == [.duplicate(count: 2)])
        #expect(analysis.group(of: 1)?.hints == [])
        #expect(analysis.flaggedGroups.map(\.indices) == [[2, 3, 4], [5, 6]])
        #expect(QueryAnalysis.identicalCount(of: queries[4].query, in: queries) == 2)
        #expect(QueryAnalysis.Hint.nPlusOne(count: 3).label == "N+1? 3×")
    }

    @Test func repeatedWritesAreNotNPlusOne() {
        let queries: [(index: Int, query: QueryRecord)] = (1...4).map { ($0, query("insert into log values (?)", String($0))) }
        #expect(QueryAnalysis(queries).flaggedGroups.isEmpty)
    }

    @Test func wordpressStyleInlinedLiteralsStillGroup() {
        let queries: [(index: Int, query: QueryRecord)] = (1...3).map { ($0, QueryRecord(sql: "SELECT * FROM wp_postmeta WHERE post_id = \($0)")) }
        #expect(QueryAnalysis(queries).groups.first?.hints == [.nPlusOne(count: 3)])
    }
}
