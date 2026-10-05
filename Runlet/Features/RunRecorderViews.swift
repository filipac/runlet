import AppKit
import RunletCore
import SwiftUI

// #5: the run inspector's HTTP, Jobs, and Events sections, a Telescope-like view of one run.
// The runner redacts credentials before anything reaches the app; these views only show what
// arrived. Records of other kinds in these sections (a project driver's own values) show as
// ordinary records.

/// A small coloured capsule: a method, a status, FAKED.
struct RecorderBadge: View {
    let text: String
    let tint: Color
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(help ?? "")
    }
}

/// The summary line and filter field above a recorder section's list.
private struct RecorderHeader: View {
    let summary: String
    var filter: Binding<String>?
    var identifier: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(summary).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier(identifier)
                Spacer()
                if let filter {
                    TextField("Filter", text: filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 180)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
        }
    }
}

/// A chevron that expands one record of the tab's current run (kept by the tab, so a DEBUG
/// step and a switch between sections keep it).
private struct RecordDisclosure: View {
    let index: Int
    let tab: TabModel
    var help = "Show the details"

    var body: some View {
        let expanded = tab.expandedRecords.contains(index)
        Button {
            if expanded { tab.expandedRecords.remove(index) } else { tab.expandedRecords.insert(index) }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(expanded ? "Collapse" : help)
    }
}

private func milliseconds(_ value: Double) -> String {
    value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.2f ms", value)
}

private func bytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

// MARK: - HTTP

struct HTTPSectionView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @State private var filter = ""

    var body: some View {
        let inspection = tab.inspection
        let records = inspection.records(in: RunInspection.http)
        let requests = inspection.httpRequests(matching: filter)
        VStack(alignment: .leading, spacing: 0) {
            RecorderHeader(summary: summary(inspection.httpRequests), filter: $filter, identifier: "http-summary")
            if records.isEmpty {
                ContentUnavailableView("No HTTP requests", systemImage: "network", description: Text("This run made no requests through the HTTP clients Runlet watches."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(requests, id: \.record.index) { entry in
                            HTTPRowView(record: entry.record, http: entry.http, tab: tab, bodiesOn: model.settings.recordHTTPBodies)
                        }
                        ForEach(records.filter { $0.http == nil }) { record in
                            RecordRowView(record: record, tab: tab)
                        }
                        OmittedRecordsNote(limit: inspection.omitted(in: RunInspection.http), noun: "requests")
                    }
                    .padding(10)
                }
                .accessibilityIdentifier("http-list")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugRecorderFilter)) { note in
            if let text = note.object as? String { filter = text }
        }
    }

    private func summary(_ requests: [HTTPRecord]) -> String {
        guard !requests.isEmpty else { return "No requests" }
        var parts = ["\(requests.count) request\(requests.count == 1 ? "" : "s")"]
        let total = requests.compactMap(\.durationMs).reduce(0, +)
        if total > 0 { parts.append(milliseconds(total)) }
        let failed = requests.filter(\.isFailure).count
        if failed > 0 { parts.append("\(failed) failed") }
        let faked = requests.filter(\.faked).count
        if faked > 0 { parts.append("\(faked) faked") }
        return parts.joined(separator: " · ")
    }
}

struct HTTPRowView: View {
    let record: InspectorRecord
    let http: HTTPRecord
    let tab: TabModel
    let bodiesOn: Bool

    var body: some View {
        let expanded = tab.expandedRecords.contains(record.index)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RecordDisclosure(index: record.index, tab: tab, help: "Show the headers" + (bodiesOn ? " and bodies" : ""))
                RecorderBadge(text: http.method, tint: Self.methodColor(http.method))
                RecorderBadge(text: http.status.map(String.init) ?? "FAILED", tint: Self.statusColor(http.outcome), help: http.error ?? http.statusText)
                Text(http.url)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(http.url)
                if http.faked {
                    RecorderBadge(text: "FAKED", tint: .purple, help: "A test double answered (Http::fake(), or a pre_http_request filter): the request never reached the network.")
                }
                Spacer(minLength: 4)
                if let duration = http.durationMs {
                    Text(milliseconds(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                RecordLocationView(record: record, tab: tab).font(.caption)
                Menu {
                    copyItems
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy this request")
            }
            .font(.caption)
            if let error = http.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(expanded ? nil : 2)
            }
            if expanded {
                details
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
        .contextMenu { copyItems }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("http-row")
    }

    @ViewBuilder
    private var copyItems: some View {
        Button("Copy URL") { Pasteboard.copy(http.url) }
        if let body = http.requestBody { Button("Copy Request Body") { Pasteboard.copy(body) } }
        if let body = http.responseBody { Button("Copy Response Body") { Pasteboard.copy(body) } }
        Button("Copy Summary") { Pasteboard.copy(http.summary) }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(http.url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(http.statusText).fontWeight(.semibold)
                if let client = http.client { Text(client == "WordPress" ? "WordPress HTTP API" : "\(client) HTTP client").foregroundStyle(.secondary) }
                if http.redactedHeaderCount > 0 {
                    Label("Credentials redacted", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Runlet replaced credentials with [redacted] before recording: authorization, cookie, and API-key headers, and secrets in the URL.")
                }
            }
            .font(.caption)
            headerList("Request Headers", http.requestHeaders)
            bodyView("Request Body", text: http.requestBody, format: http.requestBodyFormat, size: http.requestBodySize, omitted: http.requestBodyOmittedBytes)
            if http.status != nil {
                headerList("Response Headers", http.responseHeaders)
                bodyView("Response Body", text: http.responseBody, format: http.responseBodyFormat, size: http.responseBodySize, omitted: http.responseBodyOmittedBytes)
            }
        }
        .padding(.leading, 16)
        .accessibilityIdentifier("http-details")
    }

    @ViewBuilder
    private func headerList(_ title: String, _ headers: [HTTPRecord.Header]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if headers.isEmpty {
                Text("None recorded").font(.caption).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 1) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        GridRow {
                            Text(header.name).foregroundStyle(.blue)
                            HStack(spacing: 4) {
                                Text(header.value).foregroundStyle(header.redacted ? Color.secondary : Color.primary).textSelection(.enabled)
                                if header.redacted {
                                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary).help("Redacted by Runlet")
                                }
                            }
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private func bodyView(_ title: String, text: String?, format: String?, size: Int?, omitted: Int?) -> some View {
        let empty = (size ?? 0) == 0 && text == nil
        if !empty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let size { Text(bytes(size)).font(.caption).foregroundStyle(.tertiary) }
                }
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.06)))
                    if let omitted, omitted > 0 {
                        Label("\(bytes(omitted)) more not recorded", systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                    }
                } else if format == "binary" || format == "multipart" {
                    Text(format == "binary" ? "Binary: not shown." : "Multipart form data: not shown.").font(.caption).foregroundStyle(.tertiary)
                } else if !bodiesOn {
                    Text("Not recorded. Turn on Include request and response bodies in Settings ▸ General ▸ Run Inspector.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("Not recorded: Runlet couldn't read it without consuming it (a streamed body).").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func methodColor(_ method: String) -> Color {
        switch method {
        case "GET", "HEAD": .blue
        case "POST": .green
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: .secondary
        }
    }

    static func statusColor(_ outcome: HTTPRecord.Outcome) -> Color {
        switch outcome {
        case .success: .green
        case .redirect, .informational: .blue
        case .clientError: .orange
        case .serverError, .failed: .red
        }
    }
}

// MARK: - Jobs

struct JobsSectionView: View {
    let tab: TabModel

    var body: some View {
        let inspection = tab.inspection
        let records = inspection.records(in: RunInspection.jobs)
        VStack(alignment: .leading, spacing: 0) {
            RecorderHeader(summary: summary(inspection.jobs), identifier: "jobs-summary")
            if records.isEmpty {
                ContentUnavailableView("No jobs", systemImage: "tray.2", description: Text("This run queued or ran no jobs."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if inspection.jobs.contains(where: { $0.status == .queued }) {
                            Label("Queued jobs run later, in a queue worker, outside this run.", systemImage: "tray.and.arrow.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(records) { record in
                            if let job = record.job {
                                JobRowView(record: record, job: job, tab: tab)
                            } else {
                                RecordRowView(record: record, tab: tab)
                            }
                        }
                        OmittedRecordsNote(limit: inspection.omitted(in: RunInspection.jobs), noun: "jobs")
                    }
                    .padding(10)
                }
                .accessibilityIdentifier("jobs-list")
            }
        }
    }

    private func summary(_ jobs: [JobRecord]) -> String {
        guard !jobs.isEmpty else { return "No jobs" }
        var parts = ["\(jobs.count) job\(jobs.count == 1 ? "" : "s")"]
        let counts: [(JobRecord.Status, String)] = [(.processed, "ran"), (.queued, "queued"), (.failed, "failed"), (.released, "released"), (.unfinished, "didn't finish"), (.notQueued, "not queued")]
        for (status, label) in counts {
            let count = jobs.filter { $0.status == status }.count
            if count > 0 { parts.append("\(count) \(label)") }
        }
        return parts.joined(separator: " · ")
    }
}

struct JobRowView: View {
    let record: InspectorRecord
    let job: JobRecord
    let tab: TabModel

    var body: some View {
        let expanded = tab.expandedRecords.contains(record.index)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RecordDisclosure(index: record.index, tab: tab, help: "Show the job's class, IDs, and attempts")
                RecorderBadge(text: job.statusLabel, tint: tint, help: help)
                Text(job.title)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let wrapper = job.wrapper {
                    Text("via \(JobRecord.shortName(wrapper))").font(.caption).foregroundStyle(.secondary).help(wrapper)
                }
                if let place {
                    Text(place)
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                        .help("Connection and queue")
                }
                if let delay = job.delay, delay > 0 {
                    Text("in \(delay) s").font(.caption).foregroundStyle(.secondary).help("Delayed: a worker may run it \(delay) seconds after it was queued.")
                }
                Spacer(minLength: 4)
                if let duration = job.durationMs {
                    Text(milliseconds(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                RecordLocationView(record: record, tab: tab).font(.caption)
            }
            .font(.caption)
            if let exception = job.exception {
                Text("\(exception.class): \(exception.message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 2)
            }
            if expanded {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                    row("Class", job.class)
                    row("Runs", job.wrapper == nil ? nil : job.name)
                    row("Connection", job.connection)
                    row("Queue", job.queue)
                    row("Job ID", job.id)
                    row("UUID", job.uuid)
                    row("Attempts", job.attempts.map(String.init))
                }
                .font(.caption)
                .padding(.leading, 16)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.06)))
        .contextMenu {
            Button("Copy Class") { Pasteboard.copy(job.class ?? job.title) }
            Button("Copy Summary") { Pasteboard.copy(job.summary) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("job-row")
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private var place: String? {
        guard let connection = job.connection else { return job.queue }
        // The sync queue names its queue after the connection: "sync", not "sync · sync".
        guard let queue = job.queue, queue != connection else { return connection }
        return "\(connection) · \(queue)"
    }

    private var tint: Color {
        switch job.status {
        case .processed: .green
        case .queued: .blue
        case .failed, .notQueued: .red
        case .released, .unfinished: .orange
        case .unknown: .secondary
        }
    }

    private var help: String {
        switch job.status {
        case .queued: "Pushed to the queue: a worker runs it later, outside this run."
        case .processed: "Ran during the run and finished."
        case .failed: "Ran during the run and failed."
        case .released: "Released after an exception, to be tried again."
        case .unfinished: "Still running when the run ended."
        case .notQueued: "Laravel started to queue it, but the queue never confirmed it: pushing it probably failed."
        case .unknown: "A job."
        }
    }
}

// MARK: - Events

struct EventsSectionView: View {
    let tab: TabModel
    @State private var filter = ""

    var body: some View {
        let inspection = tab.inspection
        let records = inspection.records(in: RunInspection.events)
        let events = inspection.events(matching: filter)
        let total = records.filter { $0.event != nil }.count
        VStack(alignment: .leading, spacing: 0) {
            RecorderHeader(summary: total == 0 ? "No events" : (filter.isEmpty ? "\(total) event\(total == 1 ? "" : "s")" : "\(events.count) of \(total) events"), filter: $filter, identifier: "events-summary")
            if records.isEmpty {
                ContentUnavailableView("No events", systemImage: "bolt.horizontal", description: Text("This run dispatched no events besides the ones other sections show (queries, mail, logs, HTTP, jobs) and the framework's own."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(events, id: \.record.index) { entry in
                            EventRowView(record: entry.record, event: entry.event, tab: tab)
                        }
                        ForEach(records.filter { $0.event == nil }) { record in
                            RecordRowView(record: record, tab: tab)
                        }
                        OmittedRecordsNote(limit: inspection.omitted(in: RunInspection.events), noun: "events")
                    }
                    .padding(10)
                }
                .accessibilityIdentifier("events-list")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugRecorderFilter)) { note in
            if let text = note.object as? String { filter = text }
        }
    }
}

struct EventRowView: View {
    let record: InspectorRecord
    let event: EventRecord
    let tab: TabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                Text(event.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                RecordLocationView(record: record, tab: tab).font(.caption)
            }
            if let payload = event.payload {
                if payload.isExpandable {
                    ValueTreeView(node: payload, label: "payload", expansion: tab.expandedRecords.contains(record.index) ? .firstLevel : .collapsed)
                        .padding(.leading, 15)
                } else {
                    Text(payload.plainText()).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 15)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
        .contextMenu {
            Button("Copy Event Name") { Pasteboard.copy(event.name) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-row")
    }
}

extension Notification.Name {
    /// DEBUG step `recorder-filter:<text>` (InspectorDebugSteps): the HTTP and Events filters.
    static let debugRecorderFilter = Notification.Name("RunletDebugRecorderFilter")
}
