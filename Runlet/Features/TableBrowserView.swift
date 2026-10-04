import AppKit
import RunletCore
import SwiftUI

/// Browse Table (#151) in a result window: the table's page from the server, its filter rules
/// and sort (both read on the server), editing with pending changes marked in the grid, Review
/// Changes, and paging. See `TableBrowser`.
struct TableBrowserView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        VStack(spacing: 0) {
            TableBrowserHeader(browser: browser)
            TableBrowserFilterBar(browser: browser)
            Divider()
            TableBrowserEditBar(browser: browser)
            Divider()
            grid
            Divider()
            TableBrowserFooter(browser: browser)
        }
        .frame(minWidth: 640, minHeight: 360)
        .sheet(item: $browser.cellEdit) { _ in
            TableCellEditor(browser: browser)
        }
        .sheet(isPresented: $browser.isReviewing) {
            TableReviewSheet(browser: browser)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("table-browser")
    }

    private var grid: some View {
        let columns = browser.columns
        let sortColumn = browser.sort.flatMap { sort in columns.firstIndex { $0.name == sort.column } }
        return ValueTableGrid(table: browser.display, rows: Array(browser.display.rows.indices), sortColumn: sortColumn, ascending: browser.sort?.ascending ?? true,
                              onFilter: { filter in browser.filters.append(filter) },
                              onSort: { column, ascending in
                                  guard !browser.hasChanges else {
                                      browser.report = TableBrowser.ApplyReport(succeeded: false, message: "Apply or discard your changes first: sorting reads the page again.")
                                      return
                                  }
                                  browser.setSort(column.flatMap { columns.indices.contains($0) ? SQLTableBrowse.Sort(column: columns[$0].name, ascending: ascending) : nil })
                                  model.loadTablePage(browser, offset: 0)
                              },
                              marks: browser.marks,
                              onDoubleClick: { row, column in edit(row: row, column: column) },
                              editMenu: { row, column, selected in menu(row: row, column: column, selected: selected) },
                              onSelection: { browser.selectedRows = $0 })
            .accessibilityIdentifier("table-browser-grid")
    }

    private func edit(row: Int, column: Int) {
        if let problem = browser.beginEditing(row: row, column: column) {
            browser.report = TableBrowser.ApplyReport(succeeded: false, message: problem)
        }
    }

    /// The context menu's editing items, first.
    private func menu(row: Int, column: Int?, selected: [Int]) -> [ValueTableGridMenuItem] {
        guard browser.canEdit else { return [] }
        var items: [ValueTableGridMenuItem] = []
        if let column {
            let problem = browser.cellProblem(row: row, column: column)
            let name = browser.columns.indices.contains(column) ? browser.columns[column].name : "value"
            items.append(ValueTableGridMenuItem(title: "Edit \(name)…", enabled: problem == nil) { edit(row: row, column: column) })
            let nullable = browser.columns.indices.contains(column) && browser.columns[column].nullable != false
            items.append(ValueTableGridMenuItem(title: "Set \(name) to NULL", enabled: problem == nil && nullable) { browser.set(row: row, column: column, to: .null) })
            if browser.marks.changed.contains(.init(row: row, column: column)) || (browser.newRow(row) != nil && browser.display.rows[row][column].text != "DEFAULT") {
                items.append(ValueTableGridMenuItem(title: browser.newRow(row) != nil ? "Use the Default for \(name)" : "Revert \(name)") { browser.revert(row: row, column: column) })
            }
        }
        let rows = selected.contains(row) ? selected : [row]
        if rows.count == 1, browser.marks.deleted.contains(row) {
            items.append(ValueTableGridMenuItem(title: "Restore Row") { browser.restore(row: row) })
        } else {
            items.append(ValueTableGridMenuItem(title: rows.count == 1 ? "Delete Row" : "Delete \(rows.count) Rows") { browser.delete(rows: rows) })
        }
        return items
    }
}

/// The table, its connection's marks, whether it can be edited, rows per page, and Reload.
private struct TableBrowserHeader: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: browser.table.isView ? "eye" : "tablecells").foregroundStyle(browser.table.isView ? .purple : .teal)
            Text(browser.table.name)
                .font(.system(.headline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if browser.isProduction {
                EnvironmentBadge(environment: .production)
            }
            if browser.connection.savedConnection?.readOnly == true {
                ReadOnlyBadge()
            }
            Text(browser.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Picker("Rows per page", selection: $browser.pageSize) {
                ForEach(SQLTableBrowse.pageSizes, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(browser.isBusy)
            .onChange(of: browser.pageSize) { _, _ in
                if !browser.hasChanges { model.loadTablePage(browser, offset: 0) }
            }
            .help("Rows per page: each page is read on the server")
            .accessibilityIdentifier("table-browser-page-size")
            Button {
                model.loadTablePage(browser, offset: browser.pageOffset)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(browser.isBusy || browser.hasChanges)
            .help(browser.hasChanges ? "Apply or discard your changes first" : "Read this page again\(browser.isProduction ? " (production asks first)" : "")")
            .accessibilityIdentifier("table-browser-reload")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 4)
    }
}

/// Filter rules read on the server: Apply Filters reads the first page with them.
private struct TableBrowserFilterBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        let columns = browser.columns
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(columns.indices, id: \.self) { column in
                        Button(columns[column].name) { browser.filters.append(ValueTableFilter(column: column, op: .equals)) }
                    }
                } label: {
                    Label("Add Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .accessibilityIdentifier("table-browser-add-filter")
                if !browser.filters.isEmpty || !browser.appliedFilters.isEmpty {
                    Button("Apply Filters") { model.loadTablePage(browser, offset: 0) }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .disabled(!browser.filtersChanged || browser.isBusy || browser.hasChanges)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Reads the first page with these rules, as a WHERE with bound values (⌘↩)")
                        .accessibilityIdentifier("table-browser-apply-filters")
                    Button("Clear") {
                        browser.filters = []
                        if !browser.appliedFilters.isEmpty { model.loadTablePage(browser, offset: 0) }
                    }
                    .disabled(browser.isBusy || browser.hasChanges)
                }
                if let sort = browser.sort {
                    Text("Sorted by \(sort.column) \(sort.ascending ? "↑" : "↓") on the server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach($browser.filters) { $filter in
                HStack(spacing: 6) {
                    Text(filter.id == browser.filters.first?.id ? "Where" : "and")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Picker("Column", selection: $filter.column) {
                        ForEach(columns.indices, id: \.self) { column in
                            Text(columns[column].name).tag(column)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Operator", selection: $filter.op) {
                        ForEach(ValueTableFilter.Operator.allCases) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if !filter.op.isUnary {
                        TextField("Value", text: $filter.value)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit { model.loadTablePage(browser, offset: 0) }
                    }
                    if columns.indices.contains(filter.column) {
                        Text(SQLTableBrowse.ColumnKind(type: columns[filter.column].type, dialect: browser.dialect).displayName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        browser.filters.removeAll { $0.id == filter.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                    Spacer()
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("table-browser-filter-rule")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Add Row, Delete Rows, what is pending, Discard, and Review Changes; or why rows are read-only.
private struct TableBrowserEditBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        HStack(spacing: 8) {
            if let note = browser.editNote {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Read-only. " + note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("table-browser-read-only")
                Spacer()
            } else {
                Button {
                    browser.addRow()
                } label: {
                    Label("Add Row", systemImage: "plus")
                }
                .disabled(browser.page == nil || browser.isBusy)
                .help("Adds a row at the end; columns you don't fill take their default")
                .accessibilityIdentifier("table-browser-add-row")
                Button {
                    browser.delete(rows: browser.selectedRows)
                } label: {
                    Label(browser.selectedRows.count > 1 ? "Delete \(browser.selectedRows.count) Rows" : "Delete Row", systemImage: "minus")
                }
                .disabled(browser.selectedRows.isEmpty || browser.isBusy)
                .help("Marks the selected rows for deletion; nothing is deleted until you apply")
                .accessibilityIdentifier("table-browser-delete-rows")
                Text(browser.hasChanges ? browser.changes.summary + " · nothing is sent until you apply" : "Double-click a cell to edit it. Nothing is sent until you review and apply your changes.")
                    .font(.caption)
                    .foregroundStyle(browser.hasChanges ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .accessibilityIdentifier("table-browser-pending")
                Spacer()
                if browser.hasChanges {
                    Button("Discard") { browser.discardChanges() }
                        .disabled(browser.isBusy)
                        .accessibilityIdentifier("table-browser-discard")
                }
                Button(browser.hasChanges ? "Review Changes (\(browser.changes.count))…" : "Review Changes…") { browser.isReviewing = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!browser.hasChanges || browser.isBusy)
                    .help("Shows the exact statements and their values before anything runs")
                    .accessibilityIdentifier("table-browser-review")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(browser.hasChanges ? Color.orange.opacity(0.07) : Color.clear)
    }
}

/// Rows shown, what is running or what the last action did, and paging.
private struct TableBrowserFooter: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        HStack(spacing: 10) {
            Text(browser.rowsText.isEmpty ? " " : "\(browser.rowsText) · \(browser.columns.count) column\(browser.columns.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("table-browser-rows")
            status
            Spacer()
            Button {
                model.loadTablePage(browser, offset: max(0, browser.pageOffset - browser.pageSize))
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!browser.hasPrevious || browser.isBusy || browser.hasChanges)
            .accessibilityIdentifier("table-browser-previous")
            Button {
                model.loadTablePage(browser, offset: browser.pageOffset + (browser.page?.rows.count ?? browser.pageSize))
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!browser.hasMore || browser.isBusy || browser.hasChanges)
            .accessibilityIdentifier("table-browser-next")
            Button("Copy CSV") { Pasteboard.copy(browser.display.csv(rows: Array(browser.display.rows.indices))) }
                .help("Copies the rows shown, as CSV")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var status: some View {
        switch browser.phase {
        case .loading(let rows):
            ProgressView().controlSize(.mini)
            Text(waiting ? "Confirm in the main window to read \(rows)" : "Reading \(rows)…").font(.caption).foregroundStyle(.secondary)
            Button("Stop") { model.stopTableBrowser(browser) }
                .accessibilityIdentifier("table-browser-stop")
        case .applying(let count):
            ProgressView().controlSize(.mini)
            Text("Applying \(count == 1 ? "1 change" : "\(count) changes") in one transaction…").font(.caption).foregroundStyle(.secondary)
            Button("Stop") { model.stopTableBrowser(browser) }
                .accessibilityIdentifier("table-browser-stop")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(message)
                .accessibilityIdentifier("table-browser-error")
        case .idle:
            if let report = browser.report {
                Label(report.message, systemImage: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(report.succeeded ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(report.message)
                    .accessibilityIdentifier("table-browser-report")
            } else if model.productionGuard.pending?.sqlTable != nil {
                Text("Production: confirm in the main window").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var waiting: Bool { model.productionGuard.pending?.sqlTable != nil }
}

/// Edit Value: one cell, typed by its column, with NULL explicit (and, for a new row, the
/// column's default).
private struct TableCellEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var browser: TableBrowser

    var body: some View {
        if let edit = browser.cellEdit, browser.columns.indices.contains(edit.column) {
            let column = browser.columns[edit.column]
            let isNew = browser.newRow(edit.row) != nil
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit \(column.name)").font(.headline)
                    Text(rowLabel(edit.row) + " · " + [SQLSchemaExplorer.details(of: column), SQLTableBrowse.ColumnKind(type: column.type, dialect: browser.dialect).displayName + " value"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: Binding(get: { browser.cellEdit?.text ?? "" }, set: { browser.cellEdit?.text = $0; browser.cellEdit?.problem = nil }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 180)
                    .disabled(edit.isNull || edit.useDefault)
                    .opacity(edit.isNull || edit.useDefault ? 0.45 : 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("table-cell-text")
                HStack(spacing: 16) {
                    Toggle("NULL", isOn: Binding(get: { browser.cellEdit?.isNull ?? false }, set: { browser.cellEdit?.isNull = $0; if $0 { browser.cellEdit?.useDefault = false }; browser.cellEdit?.problem = nil }))
                        .disabled(column.nullable == false)
                        .help(column.nullable == false ? "\(column.name) is NOT NULL" : "Sets the value to NULL (not the text “NULL”)")
                        .accessibilityIdentifier("table-cell-null")
                    if isNew {
                        Toggle("Default", isOn: Binding(get: { browser.cellEdit?.useDefault ?? false }, set: { browser.cellEdit?.useDefault = $0; if $0 { browser.cellEdit?.isNull = false } }))
                            .help("Leaves the column out of the INSERT, so the database gives it its default")
                            .accessibilityIdentifier("table-cell-default")
                    }
                    Spacer()
                    if let original = browser.original(row: edit.row, column: edit.column) {
                        Text("Read: \(original.text.count > 60 ? String(original.text.prefix(60)) + "…" : original.text)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let problem = edit.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("table-cell-problem")
                }
                HStack {
                    Text("Nothing is sent until you review and apply your changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { browser.cellEdit = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") { browser.commitEdit() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("table-cell-set")
                }
            }
            .padding(18)
            .frame(width: 460)
            .accessibilityIdentifier("table-cell-editor")
        }
    }

    private func rowLabel(_ row: Int) -> String {
        if let new = browser.newRow(row) { return "new row \(new + 1)" }
        let keys = browser.columns.indices.filter { browser.columns[$0].primaryKey == true }.compactMap { column -> String? in
            browser.original(row: row, column: column).map { "\(browser.columns[column].name) = \($0.text)" }
        }
        return "row \(browser.pageOffset + row + 1)" + (keys.isEmpty ? "" : " (\(keys.joined(separator: ", ")))")
    }
}

/// Review Changes: the exact statements Apply runs, with their bound values, before anything runs.
private struct TableReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: TableBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Review Changes · \(browser.table.name)").font(.headline)
                    if browser.isProduction { EnvironmentBadge(environment: .production) }
                }
                Text("These statements run in order on \(model.tableConnectionLabel(browser)), in one transaction. Each must affect exactly one row; otherwise Runlet rolls everything back and nothing changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch browser.statements {
            case .failure(let problem):
                Label(problem.description, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("table-review-problem")
            case .success(let statements):
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(statements.enumerated()), id: \.offset) { index, statement in
                            StatementRow(index: index + 1, statement: statement)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 380)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
                .accessibilityIdentifier("table-review-statements")
                Text(notes(statements))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if case .success(let statements) = browser.statements {
                    Button("Copy SQL") { Pasteboard.copy(SQLTableEdits.historyCode(statements, table: browser.table.name)) }
                        .help("Copies the statements, each with its values as -- @param lines")
                }
                Spacer()
                Button("Cancel") { browser.isReviewing = false }
                    .keyboardShortcut(.cancelAction)
                Button(browser.isProduction ? "Apply on Production…" : "Apply") { model.applyTableChanges(browser) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(browser.isProduction ? .red : .orange)
                    .disabled({ if case .success = browser.statements { return false } else { return true } }())
                    .accessibilityIdentifier("table-review-apply")
            }
        }
        .padding(20)
        .frame(width: 640)
        .accessibilityIdentifier("table-review")
    }

    private func notes(_ statements: [SQLTableEdits.Statement]) -> String {
        var notes = ["Values are bound, never written into the SQL. An UPDATE also matches the original values of the columns it changes (where they compare exactly), so a row someone else changed since the page was read isn't found, and nothing is applied."]
        if statements.contains(where: { $0.verifySQL != nil }) {
            notes.append("MySQL and MariaDB count only rows an UPDATE changed: when one reports none, Runlet counts the rows of the same WHERE to tell an unchanged row from a missing one.")
        }
        if browser.isProduction { notes.append("This connection is production: Apply asks once more, listing every statement.") }
        return notes.joined(separator: " ")
    }

    private struct StatementRow: View {
        let index: Int
        let statement: SQLTableEdits.Statement

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(statement.kind.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(color))
                        Text(statement.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(statement.sql)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let values = statement.valuesLine {
                        Text(values)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("table-review-statement")
        }

        private var color: Color {
            switch statement.kind {
            case .update: .orange
            case .insert: .green
            case .delete: .red
            }
        }
    }
}
