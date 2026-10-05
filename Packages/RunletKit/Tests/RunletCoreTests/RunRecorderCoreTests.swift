import Foundation
import Testing
@testable import RunletCore

/// #5: decoding the HTTP, Jobs, and Events records, and what the sections derive from them.
struct RunRecorderCoreTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func decodesHTTPRecords() throws {
        let record = try decode(InspectorRecord.self, #"""
        {"index": 3, "section": "HTTP", "kind": "http", "inSnippet": true, "snippetLine": 6,
         "data": {"method": "POST", "url": "https://api.example.com/v1/orders?api_key=[redacted]&page=2", "status": 201, "reason": "Created",
                  "durationMs": 12.5, "client": "Laravel", "faked": true,
                  "requestHeaders": [{"name": "Authorization", "value": "Bearer [redacted]", "redacted": true}, {"name": "Accept", "value": "application/json"}],
                  "responseHeaders": [{"name": "Set-Cookie", "value": "session=[redacted]; path=/", "redacted": true}],
                  "requestBodySize": 42, "responseBody": "{\n    \"id\": 7\n}", "responseBodyFormat": "json", "responseBodyOmittedBytes": 10}}
        """#)
        #expect(record.snippetLine == 6)
        let http = try #require(record.http)
        #expect(http.method == "POST" && http.status == 201 && http.faked && http.client == "Laravel")
        #expect(http.statusText == "201 Created" && http.outcome == .success && !http.isFailure)
        #expect(http.shortURL == "api.example.com/v1/orders")
        #expect(http.requestHeaders.first == HTTPRecord.Header(name: "Authorization", value: "Bearer [redacted]", redacted: true))
        #expect(http.requestHeaders.last?.redacted == false)
        #expect(http.redactedHeaderCount == 2)
        #expect(http.requestBody == nil && http.requestBodySize == 42)
        #expect(http.responseBodyFormat == "json" && http.responseBodyOmittedBytes == 10)
        #expect(http.summary == "POST https://api.example.com/v1/orders?api_key=[redacted]&page=2 → 201 Created · 12.50 ms · faked")

        let failed = try #require(try decode(InspectorRecord.self, #"""
        {"index": 4, "section": "HTTP", "kind": "http", "data": {"method": "GET", "url": "http://127.0.0.1:9/", "error": "cURL error 7: Failed to connect"}}
        """#).http)
        #expect(failed.status == nil && failed.outcome == .failed && failed.isFailure && failed.statusText == "No response")
        #expect(failed.requestHeaders.isEmpty && failed.responseHeaders.isEmpty && !failed.faked)
        #expect(failed.shortURL == "127.0.0.1:9/")

        let statuses: [(Int, HTTPRecord.Outcome)] = [(101, .informational), (204, .success), (302, .redirect), (404, .clientError), (503, .serverError)]
        for (status, outcome) in statuses {
            #expect(HTTPRecord(method: "GET", url: "/", status: status).outcome == outcome)
        }
    }

    @Test func decodesJobRecords() throws {
        let queued = try #require(try decode(InspectorRecord.self, #"""
        {"index": 1, "section": "Jobs", "kind": "job",
         "data": {"status": "queued", "class": "Illuminate\\Mail\\SendQueuedMailable", "name": "App\\Mail\\Welcome", "connection": "redis", "queue": "mail", "delay": 60, "id": "17", "uuid": "a-b"}}
        """#).job)
        #expect(queued.status == .queued && queued.title == "App\\Mail\\Welcome" && queued.wrapper == "Illuminate\\Mail\\SendQueuedMailable")
        #expect(queued.delay == 60 && queued.id == "17" && queued.uuid == "a-b" && !queued.isFailure)
        #expect(queued.summary == "QUEUED: App\\Mail\\Welcome · via SendQueuedMailable · redis/mail")

        let failed = try #require(try decode(InspectorRecord.self, #"""
        {"index": 2, "section": "Jobs", "kind": "job",
         "data": {"status": "failed", "class": "App\\Jobs\\ChargeCard", "connection": "sync", "durationMs": 3.2, "attempts": 1,
                  "exception": {"class": "RuntimeException", "message": "Card declined"}}}
        """#).job)
        #expect(failed.isFailure && failed.statusLabel == "FAILED" && failed.wrapper == nil && failed.title == "App\\Jobs\\ChargeCard")
        #expect(failed.exception == JobRecord.Exception(class: "RuntimeException", message: "Card declined"))
        #expect(failed.summary == "FAILED: App\\Jobs\\ChargeCard · sync · 3.20 ms · RuntimeException: Card declined")

        // A status a later runner reports doesn't break decoding.
        let future = try #require(try decode(InspectorRecord.self, #"{"index": 3, "section": "Jobs", "kind": "job", "data": {"status": "batched"}}"#).job)
        #expect(future.status == .unknown && future.title == "Job")
        for status in [JobRecord.Status.released, .unfinished, .notQueued] {
            #expect(JobRecord(status: status).isFailure)
        }
    }

    @Test func decodesEventRecordsAndFilters() throws {
        var inspection = RunInspection()
        for (index, json) in [
            #"{"name": "OrderShipped", "payload": {"id": 1, "type": "object", "className": "OrderShipped", "count": 0, "entries": []}}"#,
            #"{"name": "cart.updated"}"#,
        ].enumerated() {
            let record = try decode(InspectorRecord.self, #"{"index": \#(index + 1), "section": "Events", "kind": "event", "data": \#(json)}"#)
            inspection.apply(.record(record))
        }
        #expect(inspection.events(matching: "").map(\.event.name) == ["OrderShipped", "cart.updated"])
        #expect(inspection.events(matching: " SHIPPED ").map(\.event.name) == ["OrderShipped"])
        #expect(inspection.events(matching: "cart").first?.event.payload == nil)
        #expect(inspection.events(matching: "").first?.event.payload?.className == "OrderShipped")
    }

    @Test func sectionsCountsAndLimits() throws {
        var inspection = RunInspection()
        inspection.apply(.ready(InspectorInfo(sections: ["Events", "Queries"])))
        let http = #"{"index": 1, "section": "HTTP", "kind": "http", "data": {"method": "GET", "url": "https://api.example.com/a", "status": 500}}"#
        let ok = #"{"index": 2, "section": "HTTP", "kind": "http", "data": {"method": "GET", "url": "https://api.example.com/b", "status": 200}}"#
        let job = #"{"index": 3, "section": "Jobs", "kind": "job", "data": {"status": "unfinished", "class": "App\\Jobs\\Sync"}}"#
        let custom = #"{"index": 4, "section": "Cache", "kind": "value", "title": "hit", "data": {"value": {"id": 1, "type": "int", "scalar": "1"}}}"#
        for json in [custom, http, ok, job] {
            inspection.apply(.record(try decode(InspectorRecord.self, json)))
        }
        // Built-in sections first, in their own order; then the others as they came.
        #expect(inspection.sections == ["Queries", "HTTP", "Jobs", "Events", "Cache"])
        #expect(inspection.httpRequests.count == 2 && inspection.failedHTTPCount == 1)
        #expect(inspection.jobs.count == 1 && inspection.failedJobCount == 1)
        #expect(inspection.httpRequests(matching: "/b").map(\.http.status) == [200])
        #expect(inspection.httpRequests(matching: "500").map(\.http.status) == [500])

        let limit = try decode(RecordLimitInfo.self, #"{"section": "HTTP", "omitted": 4, "reason": "sectionCount", "limit": 200}"#)
        #expect(limit == RecordLimitInfo(section: "HTTP", omitted: 4, reason: "sectionCount", limit: 200))
        #expect(try decode(RecordLimitInfo.self, #"{"section": "Log", "omitted": 1, "reason": "count"}"#).limit == nil)
    }

    @Test func inspectorOptionsDefaultsAndOlderRequests() throws {
        let defaults = RunInspectorOptions()
        #expect(defaults.http && !defaults.httpBodies && defaults.jobs && !defaults.events)
        // Options saved before #5 decode with the same defaults.
        let older = try decode(RunInspectorOptions.self, #"{"enabled": true, "interceptMail": false, "previews": true}"#)
        #expect(older == defaults)
        let round = try decode(RunInspectorOptions.self, String(decoding: try JSONEncoder().encode(RunInspectorOptions(http: false, httpBodies: true, jobs: false, events: true)), as: UTF8.self))
        #expect(!round.http && round.httpBodies && !round.jobs && round.events)
    }
}
