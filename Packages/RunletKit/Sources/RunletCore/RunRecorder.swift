import Foundation

/// #5: one HTTP request of a run (the HTTP section). Credentials are redacted by the runner:
/// `Authorization`, cookie, and API-key headers, the URL's password, and secret-named query
/// parameters. Bodies are present only when the run kept them (Settings ▸ General ▸ Run
/// Inspector ▸ Include request and response bodies).
public struct HTTPRecord: Sendable, Codable, Equatable {
    public struct Header: Sendable, Codable, Equatable, Hashable {
        public var name: String
        public var value: String
        /// The runner replaced (part of) the value with `[redacted]`.
        public var redacted: Bool

        public init(name: String, value: String, redacted: Bool = false) {
            self.name = name
            self.value = value
            self.redacted = redacted
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            redacted = try c.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
        }
    }

    public var method: String
    public var url: String
    /// nil when no response came (`error` says why).
    public var status: Int?
    public var reason: String?
    public var durationMs: Double?
    /// `Laravel`, `WordPress`, or what a driver reported.
    public var client: String?
    /// A test double answered (`Http::fake()`, a `pre_http_request` callback), not the server.
    public var faked: Bool
    /// Why there's no response: the connection failed, or none was recorded.
    public var error: String?
    public var requestHeaders: [Header]
    public var responseHeaders: [Header]
    public var requestBody: String?
    public var responseBody: String?
    /// `json` (pretty-printed by the runner), `form`, `text`, `binary`, or `multipart`.
    public var requestBodyFormat: String?
    public var responseBodyFormat: String?
    public var requestBodySize: Int?
    public var responseBodySize: Int?
    public var requestBodyOmittedBytes: Int?
    public var responseBodyOmittedBytes: Int?

    public init(method: String, url: String, status: Int? = nil, reason: String? = nil, durationMs: Double? = nil, client: String? = nil, faked: Bool = false, error: String? = nil, requestHeaders: [Header] = [], responseHeaders: [Header] = []) {
        self.method = method
        self.url = url
        self.status = status
        self.reason = reason
        self.durationMs = durationMs
        self.client = client
        self.faked = faked
        self.error = error
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        faked = try c.decodeIfPresent(Bool.self, forKey: .faked) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        requestHeaders = try c.decodeIfPresent([Header].self, forKey: .requestHeaders) ?? []
        responseHeaders = try c.decodeIfPresent([Header].self, forKey: .responseHeaders) ?? []
        requestBody = try c.decodeIfPresent(String.self, forKey: .requestBody)
        responseBody = try c.decodeIfPresent(String.self, forKey: .responseBody)
        requestBodyFormat = try c.decodeIfPresent(String.self, forKey: .requestBodyFormat)
        responseBodyFormat = try c.decodeIfPresent(String.self, forKey: .responseBodyFormat)
        requestBodySize = try c.decodeIfPresent(Int.self, forKey: .requestBodySize)
        responseBodySize = try c.decodeIfPresent(Int.self, forKey: .responseBodySize)
        requestBodyOmittedBytes = try c.decodeIfPresent(Int.self, forKey: .requestBodyOmittedBytes)
        responseBodyOmittedBytes = try c.decodeIfPresent(Int.self, forKey: .responseBodyOmittedBytes)
    }

    /// The status's class, for its colour: success (2xx), redirect (3xx), client error (4xx),
    /// server error (5xx), informational (1xx), or failed (no response).
    public enum Outcome: String, Sendable {
        case informational, success, redirect, clientError, serverError, failed
    }

    public var outcome: Outcome {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500...: return .serverError
        default: return .informational
        }
    }

    /// No response, or a 4xx or 5xx status.
    public var isFailure: Bool {
        [.failed, .clientError, .serverError].contains(outcome)
    }

    /// The URL's host and path without the query, for a short row title.
    public var shortURL: String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return host + (components.port.map { ":\($0)" } ?? "") + components.path
    }

    /// `201 Created`, or what happened instead of a response.
    public var statusText: String {
        guard let status else { return "No response" }
        return reason.map { "\(status) \($0)" } ?? "\(status)"
    }

    /// Headers the runner redacted, in either direction.
    public var redactedHeaderCount: Int {
        (requestHeaders + responseHeaders).filter(\.redacted).count
    }

    /// One line, as the Markdown export lists it: `POST https://… → 201 Created · 12.30 ms`.
    public var summary: String {
        var text = "\(method) \(url) → \(error.map { "no response (\($0))" } ?? statusText)"
        if let durationMs { text += String(format: " · %.2f ms", durationMs) }
        if faked { text += " · faked" }
        return text
    }
}

/// #5: one job of a run (the Jobs section): pushed to a queue, or run during the run (the sync
/// queue runs jobs right away).
public struct JobRecord: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        /// Pushed to a queue: a worker runs it later.
        case queued
        /// Run during the run, and finished.
        case processed
        /// Run during the run, and failed (or the queue failed it).
        case failed
        /// A worker released it to try again after an exception.
        case released
        /// Still running when the run ended (`exit`, `dd()`).
        case unfinished
        /// Laravel started to push it, but the queue never confirmed it.
        case notQueued
        case unknown
    }

    public struct Exception: Sendable, Codable, Equatable {
        public var `class`: String
        public var message: String

        public init(class: String, message: String) {
            self.class = `class`
            self.message = message
        }
    }

    public var status: Status
    /// The job's class: `App\Jobs\SendInvoice`, or a wrapper such as `Illuminate\Mail\SendQueuedMailable`.
    public var `class`: String?
    /// What a wrapper runs: the mailable, notification, listener, broadcast event, or `Closure`.
    public var name: String?
    public var connection: String?
    public var queue: String?
    /// Seconds before a worker may run it.
    public var delay: Int?
    public var id: String?
    public var uuid: String?
    public var attempts: Int?
    public var durationMs: Double?
    public var exception: Exception?

    public init(status: Status, class: String? = nil, name: String? = nil, connection: String? = nil, queue: String? = nil, delay: Int? = nil, id: String? = nil, durationMs: Double? = nil, exception: Exception? = nil) {
        self.status = status
        self.class = `class`
        self.name = name
        self.connection = connection
        self.queue = queue
        self.delay = delay
        self.id = id
        self.durationMs = durationMs
        self.exception = exception
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .unknown
        `class` = try c.decodeIfPresent(String.self, forKey: .class)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        queue = try c.decodeIfPresent(String.self, forKey: .queue)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        exception = try c.decodeIfPresent(Exception.self, forKey: .exception)
    }

    /// What the row is titled by: the wrapped class or closure, else the job's class.
    public var title: String {
        name ?? `class` ?? "Job"
    }

    /// The wrapper's class, when the title is what it runs (`SendQueuedMailable`).
    public var wrapper: String? {
        guard let name, let `class`, name != `class` else { return nil }
        return `class`
    }

    public var statusLabel: String {
        switch status {
        case .queued: "QUEUED"
        case .processed: "PROCESSED"
        case .failed: "FAILED"
        case .released: "RELEASED"
        case .unfinished: "DIDN'T FINISH"
        case .notQueued: "NOT QUEUED"
        case .unknown: "JOB"
        }
    }

    /// Failed, released after an exception, didn't finish, or wasn't queued.
    public var isFailure: Bool {
        [.failed, .released, .unfinished, .notQueued].contains(status)
    }

    /// A class name without its namespace: `SendQueuedMailable`.
    public static func shortName(_ className: String) -> String {
        className.split(separator: "\\").last.map(String.init) ?? className
    }

    /// One line, as the Markdown export lists it.
    public var summary: String {
        var parts = ["\(statusLabel): \(title)"]
        if let wrapper { parts.append("via \(Self.shortName(wrapper))") }
        if let connection { parts.append(connection + (queue.flatMap { $0 == connection ? nil : "/\($0)" } ?? "")) }
        if let durationMs { parts.append(String(format: "%.2f ms", durationMs)) }
        if let exception { parts.append("\(exception.class): \(exception.message)") }
        return parts.joined(separator: " · ")
    }
}

/// #5: one dispatched event of a run (the Events section), with a short summary of its payload.
public struct EventRecord: Sendable, Codable, Equatable {
    public var name: String
    public var payload: ValueNode?

    public init(name: String, payload: ValueNode? = nil) {
        self.name = name
        self.payload = payload
    }
}

extension RunInspection {
    /// #5: the Events section's events whose name contains `filter` (all of them when it's empty).
    public func events(matching filter: String) -> [(record: InspectorRecord, event: EventRecord)] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return records(in: Self.events).compactMap { record in
            guard let event = record.event else { return nil }
            guard needle.isEmpty || event.name.lowercased().contains(needle) else { return nil }
            return (record, event)
        }
    }

    /// #5: the HTTP section's requests whose method, URL, or status contains `filter`.
    public func httpRequests(matching filter: String) -> [(record: InspectorRecord, http: HTTPRecord)] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return records(in: Self.http).compactMap { record in
            guard let http = record.http else { return nil }
            guard needle.isEmpty || "\(http.method) \(http.url) \(http.status.map(String.init) ?? "")".lowercased().contains(needle) else { return nil }
            return (record, http)
        }
    }
}
