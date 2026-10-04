#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for Export Query to CSV and Import CSV (#152), for screenshots and
/// scripted checks with scratch data (see `DebugSteps`): `csv-export` (Export Query to CSV… for
/// the current tab, as the Run menu does) · `csv-export-option:delimiter=comma|semicolon|tab`,
/// `header=on|off`, `null=empty|backslashN` · `csv-export-run:<path>` (Export… in the sheet,
/// writing `<path>` instead of asking in the save panel; production asks first) ·
/// `csv-export-stop` and `csv-export-close` (Stop, and Done or Cancel) ·
/// `csv-import:<table>|<path>` (Import CSV… on a table of the Database pane's schema, reading
/// `<path>` instead of asking in the open panel) · `csv-import-option:delimiter=<,|;|tab|pipe>`,
/// `header=on|off`, `null=on|off`, `map:<table column>=<CSV column name, or none>` ·
/// `csv-import-run`, `csv-import-stop`, and `csv-import-close` · `csv-state` (prints both
/// sheets' state). `csv-wait[:<seconds>]` and `csv-wait:rows=<n>` (in `RunletApp`) hold the steps
/// until the export or import (or a schema that is loading) ends, or until the export wrote n rows.
@MainActor
enum SQLCSVDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "csv-export":
            guard let tab = model.selectedTab else { return true }
            model.exportQueryToCSV(tab)
            log("csv-export: \(model.sqlCSV.export.map { "sheet for \($0.statement.prefix(60))" } ?? "no sheet (\(model.alert?.message ?? "-"))")")
        case "csv-export-option":
            guard let job = model.sqlCSV.export else { return true }
            let (key, value) = pair(argument)
            switch key {
            case "delimiter": job.options.delimiter = SQLCSVExportOptions.Delimiter(rawValue: value) ?? job.options.delimiter
            case "header": job.options.header = value != "off"
            case "null": job.options.null = SQLCSVExportOptions.NullStyle(rawValue: value) ?? job.options.null
            default: log("csv-export-option: \(argument)?")
            }
        case "csv-export-run":
            guard let job = model.sqlCSV.export else { return true }
            model.sqlCSV.debugDestination = URL(fileURLWithPath: argument)
            model.chooseCSVExportFile(job)
        case "csv-export-stop":
            model.stopCSVExport()
        case "csv-export-close":
            model.closeCSVExport()
        case "csv-import":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let tab = model.selectedTab else { return true }
            let choice = model.explorerConnection(for: tab)
            guard let ref = choice.ref, let schema = model.sqlSchemaState(target: tab.target, connection: ref)?.schema, let table = schema.table(named: parts[0]) else {
                log("csv-import: no schema with \(parts[0]); load it first")
                return true
            }
            model.openCSVImport(URL(fileURLWithPath: parts[1]), into: table, schema: schema, from: tab)
            log("csv-import: \(model.sqlCSV.importJob.map { "\($0.plan.rowCount) rows, mapping \($0.plan.mapping)" } ?? "no sheet (\(model.alert?.message ?? "-"))")")
        case "csv-import-option":
            guard let job = model.sqlCSV.importJob else { return true }
            let (key, value) = pair(argument)
            switch key {
            case "delimiter": job.setDelimiter(value == "tab" ? "\t" : value == "pipe" ? "|" : Character(value.isEmpty ? "," : value))
            case "header": job.setHeader(value != "off")
            case "null": job.plan.emptyIsNull = value != "off"
            case let map where map.hasPrefix("map;"):
                // `map;<column>=<CSV column>` (`;` because `:` splits the step).
                let column = String(map.dropFirst(4))
                if let index = job.plan.tableColumns.firstIndex(where: { $0.name == column }) {
                    job.plan.mapping[index] = job.plan.csvColumns.firstIndex(of: value)
                }
            default: log("csv-import-option: \(argument)?")
            }
        case "csv-import-run":
            guard let job = model.sqlCSV.importJob else { return true }
            model.startCSVImport(job)
        case "csv-import-stop":
            model.stopCSVImport()
        case "csv-import-close":
            model.closeCSVImport()
        case "csv-state":
            log(state(model))
        default:
            return false
        }
        return true
    }

    /// Whether `csv-wait` should keep waiting.
    static func busy(_ model: AppModel, rows: Int?) -> Bool {
        if let rows, let job = model.sqlCSV.export { return job.isRunning && job.rows < rows }
        // A schema that is loading counts too (`sql-schema:load` before `csv-import`).
        return model.sqlCSV.export?.isRunning == true || model.sqlCSV.importJob?.isRunning == true || model.sqlSchemas.states.values.contains(where: \.isLoading)
    }

    static var waited: Double = 0

    static func state(_ model: AppModel) -> String {
        let export = model.sqlCSV.export.map { "export \($0.phase) \($0.progressText) to \($0.destination?.lastPathComponent ?? "-")" } ?? "no export"
        let importing = model.sqlCSV.importJob.map { "import \($0.phase) \($0.inserted)/\($0.plan.rowCount) rows into \($0.plan.table), failed line \($0.failedLine.map(String.init) ?? "-")" } ?? "no import"
        return "csv-state: \(export); \(importing)"
    }

    private static func pair(_ argument: String) -> (String, String) {
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
