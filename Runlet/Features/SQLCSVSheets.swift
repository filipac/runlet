import AppKit
import RunletCore
import SwiftUI

/// Export Query to CSV's and Import CSV's sheets (#152) on the window that asked. A production
/// confirmation for them shows inside the sheet (a window shows one sheet at a time).
struct SQLCSVSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let windowId: UUID

    func body(content: Content) -> some View {
        content
            .sheet(item: exportJob) { job in
                SQLCSVConfirmingSheet(windowId: job.windowId) { SQLCSVExportSheet(job: job) }
            }
            .sheet(item: importJob) { job in
                SQLCSVConfirmingSheet(windowId: job.windowId) { SQLCSVImportSheet(job: job) }
            }
    }

    private var exportJob: Binding<SQLCSVExportJob?> {
        Binding(
            get: {
                guard let job = model.sqlCSV.export, job.windowId == nil || job.windowId == windowId else { return nil }
                return job
            },
            set: { value in
                if value == nil, let job = model.sqlCSV.export, job.windowId == nil || job.windowId == windowId, !job.isRunning { model.closeCSVExport() }
            }
        )
    }

    private var importJob: Binding<SQLCSVImportJob?> {
        Binding(
            get: {
                guard let job = model.sqlCSV.importJob, job.windowId == nil || job.windowId == windowId else { return nil }
                return job
            },
            set: { value in
                if value == nil, let job = model.sqlCSV.importJob, job.windowId == nil || job.windowId == windowId, !job.isRunning { model.closeCSVImport() }
            }
        )
    }
}

/// The sheet's content, or the production confirmation in its place while one is pending.
private struct SQLCSVConfirmingSheet<Content: View>: View {
    @Environment(AppModel.self) private var model
    let windowId: UUID?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let pending = model.productionGuard.pending, pending.windowId == nil || pending.windowId == windowId {
            ProductionConfirmationSheet(confirmation: pending)
        } else {
            content()
        }
    }
}

// MARK: - Export

struct SQLCSVExportSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var job: SQLCSVExportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(CodePreview.lines(job.statement, limit: 6))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .textSelection(.enabled)
                .accessibilityIdentifier("csv-export-statement")
            switch job.phase {
            case .options:
                options
            case .running:
                progress
            case .finished:
                finished
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("csv-export-error")
            case .stopped(let message):
                Label(message, systemImage: "stop.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("csv-export-stopped")
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 620)
        .onExitCommand { if !job.isRunning { model.closeCSVExport() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("csv-export-sheet")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text("Export Query to CSV").font(.headline)
                Text("Every row of the statement, written to a file on this Mac as it arrives. No row limit: Runlet holds a thousand rows at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On \(job.run.connectionLabel) · \(model.targetLabel(job.target))" + (job.run.values.isEmpty ? "" : " · \(job.run.values.count) bound value\(job.run.values.count == 1 ? "" : "s")"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var options: some View {
        Form {
            Picker("Delimiter", selection: $job.options.delimiter) {
                ForEach(SQLCSVExportOptions.Delimiter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("csv-export-delimiter")
            Toggle("Header row with the column names", isOn: $job.options.header)
                .accessibilityIdentifier("csv-export-header")
            Picker("NULL as", selection: $job.options.null) {
                ForEach(SQLCSVExportOptions.NullStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("csv-export-null")
            Text("Values are written as the result shows them; binary values as hex (0x…), and text that looks like NULL is quoted. RFC 4180 quoting, UTF-8, CRLF line ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 210)
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting to \(job.destination?.lastPathComponent ?? "the file")…").font(.callout.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(job.progressText + (job.elapsed.map { " · " + Self.duration($0) } ?? ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("csv-export-progress")
                }
            }
            Spacer()
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Exported \(job.progressText) to \(job.destination?.lastPathComponent ?? "the file")" + (job.elapsed.map { " in " + Self.duration($0) } ?? "") + ".", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.teal)
                .accessibilityIdentifier("csv-export-done")
            if let path = job.destination?.deletingLastPathComponent().lastPathComponent {
                Text("In the folder “\(path)”. The rows went only to the file: not to the output, Run History, or the Run Log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if job.phase == .finished {
                Button("Show in Finder") { model.revealCSVExport() }
                    .accessibilityIdentifier("csv-export-reveal")
            }
            Spacer()
            switch job.phase {
            case .options:
                Button("Cancel") { model.closeCSVExport() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { model.chooseCSVExportFile(job) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("csv-export-choose")
            case .running:
                Button("Stop") { model.stopCSVExport() }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("csv-export-stop")
            default:
                Button("Done") { model.closeCSVExport() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("csv-export-close")
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}

// MARK: - Import

struct SQLCSVImportSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var job: SQLCSVImportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if job.phase == .mapping || isEditable {
                settings
                HStack(alignment: .top, spacing: 16) {
                    mapping.frame(width: 300)
                    preview.frame(maxWidth: .infinity)
                }
                statement
            }
            switch job.phase {
            case .running:
                progress
            case .finished:
                Label("Imported \(job.inserted.formatted()) row\(job.inserted == 1 ? "" : "s") into \(job.plan.table) in one transaction" + (job.elapsed.map { " (\(SQLCSVExportSheet.duration($0)))" } ?? "") + ".", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.teal)
                    .accessibilityIdentifier("csv-import-done")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("csv-import-error")
            case .stopped(let message):
                Label(message, systemImage: "stop.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("csv-import-stopped")
            case .mapping:
                if let problem = job.plan.problem {
                    Label(problem, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("csv-import-problem")
                }
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 780)
        .onExitCommand { if !job.isRunning { model.closeCSVImport() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("csv-import-sheet")
    }

    /// After a failure or Stop the mapping can change and Import runs again.
    private var isEditable: Bool {
        switch job.phase {
        case .failed, .stopped: true
        default: false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text("Import CSV into \(job.plan.table)").font(.headline)
                Text("\(job.fileName) · \(job.plan.rowCount.formatted()) row\(job.plan.rowCount == 1 ? "" : "s") · \(job.plan.csvColumns.count) column\(job.plan.csvColumns.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("csv-import-file")
                Text("Into \(job.connection.label) · \(model.targetLabel(job.target)). Every row is inserted with bound values in one transaction, rolled back at the first error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settings: some View {
        HStack(spacing: 16) {
            Picker("Delimiter", selection: Binding(get: { String(job.plan.delimiter) }, set: { job.setDelimiter(Character($0)) })) {
                Text("Comma").tag(",")
                Text("Semicolon").tag(";")
                Text("Tab").tag("\t")
                Text("Pipe").tag("|")
            }
            .fixedSize()
            .accessibilityIdentifier("csv-import-delimiter")
            Toggle("First row is a header", isOn: Binding(get: { job.plan.hasHeader }, set: { job.setHeader($0) }))
                .accessibilityIdentifier("csv-import-header")
            Toggle("Empty fields are NULL", isOn: $job.plan.emptyIsNull)
                .accessibilityIdentifier("csv-import-empty-null")
            Spacer()
        }
        .controlSize(.small)
        .disabled(job.isRunning)
    }

    private var mapping: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Columns").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(Array(job.plan.tableColumns.enumerated()), id: \.offset) { index, column in
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(column.name).font(.system(.callout, design: .monospaced)).lineLimit(1)
                                Text(SQLSchemaExplorer.details(of: column)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Picker("", selection: Binding(get: { job.plan.mapping[index] ?? -1 }, set: { job.plan.mapping[index] = $0 < 0 ? nil : $0 })) {
                                Text("Don't import").tag(-1)
                                ForEach(Array(job.plan.csvColumns.enumerated()), id: \.offset) { csvIndex, name in
                                    Text(name).tag(csvIndex)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 140)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
        .disabled(job.isRunning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("csv-import-mapping")
    }

    private var preview: some View {
        let columns = job.plan.importedColumns
        let rows = job.plan.preview()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Preview: the first \(rows.count) row\(rows.count == 1 ? "" : "s") as they are bound").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, entry in
                            Text(entry.column.name).font(.caption.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                Text(value.map { $0.isEmpty ? "''" : $0 } ?? "NULL")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(value == nil ? .secondary : .primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("csv-import-preview")
    }

    private var statement: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Statement").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(statementText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .accessibilityIdentifier("csv-import-statement")
        }
    }

    /// The INSERT, and row 1's bound values.
    private var statementText: String {
        guard !job.plan.importedColumns.isEmpty else { return "-- Choose at least one column." }
        let first = job.plan.preview(rows: 1).first.map { values in
            "\n-- Row 1 binds: " + values.map { $0.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }.joined(separator: ", ")
        } ?? ""
        return job.plan.insertStatement + ";" + first + "\n-- Runlet sends up to \(max(1, min(500, 999 / max(1, job.plan.importedColumns.count)))) rows per INSERT, all in one transaction."
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(job.inserted), total: Double(max(1, job.plan.rowCount)))
            Text("Inserted \(job.inserted.formatted()) of \(job.plan.rowCount.formatted()) rows (not committed yet)…")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("csv-import-progress")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            switch job.phase {
            case .running:
                Button("Stop") { model.stopCSVImport() }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("csv-import-stop")
            case .finished:
                Button("Done") { model.closeCSVImport() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("csv-import-close")
            default:
                Button("Cancel") { model.closeCSVImport() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(job.plan.rowCount.formatted()) Row\(job.plan.rowCount == 1 ? "" : "s")") { model.startCSVImport(job) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.plan.problem != nil)
                    .accessibilityIdentifier("csv-import-run")
            }
        }
    }
}
