#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for the run inspector's HTTP, Jobs, and Events sections (#5), for
/// screenshots and scripted checks with scratch data (see `DebugSteps`):
/// `recorder:http|bodies|jobs|events=on|off` (Settings ▸ General ▸ Run Inspector's switches) ·
/// `recorder-expand:<section>:<n>` opens the details of the nth record (from 1) of a section of
/// the current tab, as its chevron does (`recorder-expand:HTTP:redacted` opens the first request
/// with a redacted header) · `recorder-filter:<text>` types into the open section's filter ·
/// `recorder-state` prints the sections, their counts, and one line per request, job, and event.
@MainActor
enum RecorderDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "recorder":
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            let on = parts[1] != "off"
            switch parts[0] {
            case "http": model.settings.recordHTTP = on
            case "bodies": model.settings.recordHTTPBodies = on
            case "jobs": model.settings.recordJobs = on
            case "events": model.settings.recordEvents = on
            default: break
            }
        case "recorder-expand":
            guard let tab = model.selectedTab else { return true }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            let records = tab.inspection.records(in: parts[0])
            let record: InspectorRecord? = if parts[1] == "redacted" {
                records.first { ($0.http?.redactedHeaderCount ?? 0) > 0 }
            } else {
                Int(parts[1]).flatMap { records.indices.contains($0 - 1) ? records[$0 - 1] : nil }
            }
            if let record { tab.expandedRecords.insert(record.index) }
            log("recorder-expand \(argument): \(record.map { "#\($0.index)" } ?? "no such record")")
        case "recorder-filter":
            NotificationCenter.default.post(name: .debugRecorderFilter, object: argument)
        case "recorder-state":
            log("recorder-state: \(state(model))")
        default:
            return false
        }
        return true
    }

    private static func state(_ model: AppModel) -> String {
        guard let tab = model.selectedTab else { return "no tab" }
        let inspection = tab.inspection
        let sections = inspection.sections.map { "\($0)=\(inspection.records(in: $0).count)" }.joined(separator: " ")
        let http = inspection.httpRequests.map { "[\($0.summary) redacted=\($0.redactedHeaderCount)]" }.joined(separator: " ")
        let jobs = inspection.jobs.map { "[\($0.summary)]" }.joined(separator: " ")
        let events = inspection.events(matching: "").map(\.event.name).joined(separator: ", ")
        let settings = model.settings
        return "settings http=\(settings.recordHTTP) bodies=\(settings.recordHTTPBodies) jobs=\(settings.recordJobs) events=\(settings.recordEvents) · section=\(tab.visibleOutputSection ?? "Output") · sections: \(sections) · http: \(http) · jobs: \(jobs) · events: \(events)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
