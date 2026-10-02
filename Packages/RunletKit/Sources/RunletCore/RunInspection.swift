import Foundation

/// What the run request asks of the run inspector (`request.inspector`).
public struct RunInspectorOptions: Sendable, Codable, Equatable {
    /// Record queries, mail, log messages, and driver sections (`Driver::inspect()`).
    public var enabled: Bool
    /// Ask drivers to intercept mail: messages are recorded but never sent.
    public var interceptMail: Bool
    /// Render HTML previews of returned or dumped mailables, views, and responses.
    public var previews: Bool

    public init(enabled: Bool = true, interceptMail: Bool = false, previews: Bool = true) {
        self.enabled = enabled
        self.interceptMail = interceptMail
        self.previews = previews
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        interceptMail = try c.decodeIfPresent(Bool.self, forKey: .interceptMail) ?? false
        previews = try c.decodeIfPresent(Bool.self, forKey: .previews) ?? true
    }
}

/// One run-inspector event (`inspector`, `record`, and `recordLimit` frames).
public enum InspectorEvent: Sendable, Equatable {
    /// After the driver's `inspect()`: the sections it shows and whether mail is intercepted.
    case ready(InspectorInfo)
    case record(InspectorRecord)
    /// Records left out because the run reached a limit (reported when the run finishes).
    case limit(RecordLimitInfo)
}

public struct InspectorInfo: Sendable, Codable, Equatable {
    /// Sections the driver shows even when they stay empty, in order.
    public var sections: [String]
    /// The run asked drivers to intercept mail.
    public var interceptMail: Bool
    /// A driver confirmed it intercepts mail in this run.
    public var interceptingMail: Bool
    public var driverName: String?

    public init(sections: [String], interceptMail: Bool = false, interceptingMail: Bool = false, driverName: String? = nil) {
        self.sections = sections
        self.interceptMail = interceptMail
        self.interceptingMail = interceptingMail
        self.driverName = driverName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
        interceptMail = try c.decodeIfPresent(Bool.self, forKey: .interceptMail) ?? false
        interceptingMail = try c.decodeIfPresent(Bool.self, forKey: .interceptingMail) ?? false
        driverName = try c.decodeIfPresent(String.self, forKey: .driverName)
    }

    /// Mail interception was asked for, but no driver can do it: mail is delivered normally.
    public var interceptionUnsupported: Bool { interceptMail && !interceptingMail }
}

public struct RecordLimitInfo: Sendable, Codable, Equatable {
    public var section: String
    public var omitted: Int
    /// `count` or `bytes` (the runner's limits), or `app` (Runlet's own backstop).
    public var reason: String

    public init(section: String, omitted: Int, reason: String) {
        self.section = section
        self.omitted = omitted
        self.reason = reason
    }
}

/// One thing a run did, reported by a driver through `Runlet\Inspector`.
public struct InspectorRecord: Sendable, Equatable, Identifiable, Decodable {
    public enum Content: Sendable, Equatable {
        case query(QueryRecord)
        case mail(MailRecord)
        case log(LogRecord)
        case html(HTMLRecord)
        /// `Inspector::record()`: any value, shown like a dump.
        case value(ValueNode)
        /// A record kind this version of Runlet does not know.
        case unknown(kind: String)
    }

    /// Order of the record within the run (1-based).
    public var index: Int
    public var section: String
    public var title: String?
    public var inSnippet: Bool?
    public var snippetLine: Int?
    public var file: String?
    public var line: Int?
    public var content: Content

    public var id: Int { index }

    public init(index: Int, section: String, title: String? = nil, inSnippet: Bool? = nil, snippetLine: Int? = nil, file: String? = nil, line: Int? = nil, content: Content) {
        self.index = index
        self.section = section
        self.title = title
        self.inSnippet = inSnippet
        self.snippetLine = snippetLine
        self.file = file
        self.line = line
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case index, section, kind, title, inSnippet, snippetLine, file, line, data
    }

    enum ValueKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        section = try c.decode(String.self, forKey: .section)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        inSnippet = try c.decodeIfPresent(Bool.self, forKey: .inSnippet)
        snippetLine = try c.decodeIfPresent(Int.self, forKey: .snippetLine)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "query": content = .query(try c.decode(QueryRecord.self, forKey: .data))
        case "mail": content = .mail(try c.decode(MailRecord.self, forKey: .data))
        case "log": content = .log(try c.decode(LogRecord.self, forKey: .data))
        case "html": content = .html(try c.decode(HTMLRecord.self, forKey: .data))
        case "value":
            let data = try c.nestedContainer(keyedBy: ValueKeys.self, forKey: .data)
            content = .value(try data.decode(ValueNode.self, forKey: .value))
        default: content = .unknown(kind: kind)
        }
    }

    public var query: QueryRecord? {
        if case .query(let query) = content { return query }
        return nil
    }

    public var mail: MailRecord? {
        if case .mail(let mail) = content { return mail }
        return nil
    }
}

public struct QueryRecord: Sendable, Codable, Equatable {
    public struct Binding: Sendable, Codable, Equatable, Hashable {
        /// null | bool | int | float | string | datetime | binary | resource | array | object
        public var type: String
        public var value: String?
        /// Set for named parameters (`:email`), without the colon.
        public var name: String?
        /// Byte length of a binary value.
        public var size: Int?
        /// Bytes of a long string value left out.
        public var omittedBytes: Int?

        public init(type: String, value: String? = nil, name: String? = nil, size: Int? = nil, omittedBytes: Int? = nil) {
            self.type = type
            self.value = value
            self.name = name
            self.size = size
            self.omittedBytes = omittedBytes
        }

        /// The value as an SQL literal for display (never for execution).
        public func sqlLiteral(driver: String? = nil) -> String {
            let more = omittedBytes.map { "…(+\($0) bytes)" } ?? ""
            switch type {
            case "null": return "NULL"
            case "bool":
                let on = value == "true"
                return driver == "pgsql" ? (on ? "true" : "false") : (on ? "1" : "0")
            case "int", "float": return value ?? "NULL"
            case "binary": return "<binary \(size ?? 0) bytes>"
            case "string", "datetime":
                return "'" + (value ?? "").replacingOccurrences(of: "'", with: "''") + more + "'"
            default: return "<\(type) \(value ?? "")>"
            }
        }

        /// The value as plain text for the bindings list.
        public var displayValue: String {
            switch type {
            case "null": "null"
            case "binary": "binary, \(size ?? 0) bytes"
            case "string", "datetime": "\"\(value ?? "")\"" + (omittedBytes.map { "… (+\($0) bytes)" } ?? "")
            default: value ?? type
            }
        }
    }

    public var sql: String
    public var bindings: [Binding]
    public var timeMs: Double?
    public var connection: String?
    /// mysql, pgsql, sqlite, sqlsrv, … when the database layer reported it.
    public var driver: String?
    /// The statement with its bindings substituted by the database layer, when it can.
    public var rawSql: String?
    public var omittedBindings: Int?
    public var omittedBytes: Int?

    public init(sql: String, bindings: [Binding] = [], timeMs: Double? = nil, connection: String? = nil, driver: String? = nil, rawSql: String? = nil, omittedBindings: Int? = nil, omittedBytes: Int? = nil) {
        self.sql = sql
        self.bindings = bindings
        self.timeMs = timeMs
        self.connection = connection
        self.driver = driver
        self.rawSql = rawSql
        self.omittedBindings = omittedBindings
        self.omittedBytes = omittedBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sql = try c.decode(String.self, forKey: .sql)
        bindings = try c.decodeIfPresent([Binding].self, forKey: .bindings) ?? []
        timeMs = try c.decodeIfPresent(Double.self, forKey: .timeMs)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        rawSql = try c.decodeIfPresent(String.self, forKey: .rawSql)
        omittedBindings = try c.decodeIfPresent(Int.self, forKey: .omittedBindings)
        omittedBytes = try c.decodeIfPresent(Int.self, forKey: .omittedBytes)
    }

    /// The statement with its bindings inlined for reading: the database layer's own
    /// rendering when it sent one, else Runlet's. For display and copying only.
    public var interpolatedSQL: String {
        rawSql ?? SQLText.interpolate(sql, bindings: bindings, driver: driver)
    }
}

public struct MailRecord: Sendable, Codable, Equatable {
    public struct Address: Sendable, Codable, Equatable, Hashable {
        public var address: String
        public var name: String?

        public init(address: String, name: String? = nil) {
            self.address = address
            self.name = name
        }

        /// `Ada <ada@example.com>`, or the bare address.
        public var display: String {
            guard let name, !name.isEmpty else { return address }
            return "\(name) <\(address)>"
        }
    }

    public struct Attachment: Sendable, Codable, Equatable, Hashable {
        public var filename: String?
        public var contentType: String?
        public var size: Int?
        public var inline: Bool?
    }

    public var subject: String?
    public var mailer: String?
    /// The mailable or notification class, when known.
    public var mailable: String?
    public var from: [Address]
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var replyTo: [Address]
    public var html: String?
    public var text: String?
    public var htmlOmittedBytes: Int?
    public var textOmittedBytes: Int?
    public var attachments: [Attachment]
    /// The driver stopped the message: it was recorded, not sent.
    public var intercepted: Bool
    /// Pushed to an asynchronous queue: a worker sends it later, interception or not.
    public var queued: Bool
    public var queueConnection: String?
    public var queue: String?

    public init(subject: String? = nil, to: [Address] = [], html: String? = nil, text: String? = nil, intercepted: Bool = false, queued: Bool = false) {
        self.subject = subject
        self.from = []
        self.to = to
        self.cc = []
        self.bcc = []
        self.replyTo = []
        self.html = html
        self.text = text
        self.attachments = []
        self.intercepted = intercepted
        self.queued = queued
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        mailer = try c.decodeIfPresent(String.self, forKey: .mailer)
        mailable = try c.decodeIfPresent(String.self, forKey: .mailable)
        from = try c.decodeIfPresent([Address].self, forKey: .from) ?? []
        to = try c.decodeIfPresent([Address].self, forKey: .to) ?? []
        cc = try c.decodeIfPresent([Address].self, forKey: .cc) ?? []
        bcc = try c.decodeIfPresent([Address].self, forKey: .bcc) ?? []
        replyTo = try c.decodeIfPresent([Address].self, forKey: .replyTo) ?? []
        html = try c.decodeIfPresent(String.self, forKey: .html)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        htmlOmittedBytes = try c.decodeIfPresent(Int.self, forKey: .htmlOmittedBytes)
        textOmittedBytes = try c.decodeIfPresent(Int.self, forKey: .textOmittedBytes)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        intercepted = try c.decodeIfPresent(Bool.self, forKey: .intercepted) ?? false
        queued = try c.decodeIfPresent(Bool.self, forKey: .queued) ?? false
        queueConnection = try c.decodeIfPresent(String.self, forKey: .queueConnection)
        queue = try c.decodeIfPresent(String.self, forKey: .queue)
    }

    /// One line: subject and recipients.
    public var summary: String {
        let subject = subject.map { "“\($0)”" } ?? mailable.map { ($0 as NSString).lastPathComponent } ?? "Message"
        let recipients = to.map(\.display).joined(separator: ", ")
        return recipients.isEmpty ? subject : "\(subject) to \(recipients)"
    }
}

public struct LogRecord: Sendable, Codable, Equatable {
    public var level: String
    public var message: String
    public var channel: String?
    public var context: ValueNode?

    public init(level: String, message: String, channel: String? = nil, context: ValueNode? = nil) {
        self.level = level
        self.message = message
        self.channel = channel
        self.context = context
    }
}

public struct HTMLRecord: Sendable, Codable, Equatable {
    public var html: String
    public var omittedBytes: Int?

    public init(html: String, omittedBytes: Int? = nil) {
        self.html = html
        self.omittedBytes = omittedBytes
    }
}

/// Rendered HTML of a returned or dumped object (`Driver::preview()`).
public struct HTMLPreview: Sendable, Codable, Equatable {
    /// mail | view | response | html
    public var kind: String?
    public var title: String?
    public var subject: String?
    public var html: String?
    public var text: String?
    public var htmlOmittedBytes: Int?
    public var textOmittedBytes: Int?
    /// Rendering failed; the message explains why.
    public var error: String?

    public init(kind: String? = nil, title: String? = nil, subject: String? = nil, html: String? = nil, text: String? = nil, error: String? = nil) {
        self.kind = kind
        self.title = title
        self.subject = subject
        self.html = html
        self.text = text
        self.error = error
    }
}

/// Everything the inspector reported for one run, grouped by section.
public struct RunInspection: Sendable, Equatable {
    public static let queries = "Queries"
    public static let mail = "Mail"
    public static let log = "Log"
    public static let html = "HTML"

    public private(set) var info: InspectorInfo?
    public private(set) var records: [InspectorRecord] = []
    public private(set) var limits: [RecordLimitInfo] = []
    private var bySection: [String: [InspectorRecord]] = [:]
    private var sectionOrder: [String] = []

    public init() {}

    public mutating func apply(_ event: InspectorEvent) {
        switch event {
        case .ready(let info):
            self.info = info
            for section in info.sections where !sectionOrder.contains(section) { sectionOrder.append(section) }
        case .record(let record):
            records.append(record)
            if bySection[record.section] == nil, !sectionOrder.contains(record.section) { sectionOrder.append(record.section) }
            bySection[record.section, default: []].append(record)
        case .limit(let limit):
            if let index = limits.firstIndex(where: { $0.section == limit.section }) {
                limits[index].omitted += limit.omitted
            } else {
                limits.append(limit)
            }
            if !sectionOrder.contains(limit.section) { sectionOrder.append(limit.section) }
        }
    }

    /// Sections to show: Queries, Mail, and Log first (when the driver records them or
    /// anything arrived), then the others in the order they first appeared.
    public var sections: [String] {
        let builtIn = [Self.queries, Self.mail, Self.log].filter { sectionOrder.contains($0) }
        return builtIn + sectionOrder.filter { !builtIn.contains($0) }
    }

    public var isEmpty: Bool { sectionOrder.isEmpty }

    public func records(in section: String) -> [InspectorRecord] {
        bySection[section] ?? []
    }

    public func omitted(in section: String) -> RecordLimitInfo? {
        limits.first { $0.section == section }
    }

    public var queries: [(index: Int, query: QueryRecord)] {
        records(in: Self.queries).compactMap { record in record.query.map { (record.index, $0) } }
    }

    public var mails: [MailRecord] {
        records(in: Self.mail).compactMap(\.mail)
    }

    public var interceptedMailCount: Int {
        mails.filter { $0.intercepted && !$0.queued }.count
    }

    /// Total time of the queries that reported one, in milliseconds.
    public var queryTimeMs: Double {
        queries.compactMap(\.query.timeMs).reduce(0, +)
    }
}
