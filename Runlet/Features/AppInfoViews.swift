import RunletCore
import SwiftUI

/// The framework chip's App Info popover (#19). Clicking `label` opens it: it shows the
/// target's cached App Info, or loads it (booting the application) when nothing is cached.
/// Production targets confirm first, and the popover opens once confirmed.
struct AppInfoButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    /// Which Show App Info requests it answers (`AppInfoRequest.anchor`): the status bar's
    /// "status", a tab card's "card".
    var anchor: String
    var arrowEdge: Edge = .top
    /// Pads the label inside its hover highlight (off for capsules that have their own).
    var inset = true
    @ViewBuilder var label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button { open(refresh: false) } label: { label() }
            .buttonStyle(ChipButtonStyle(inset: inset))
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                AppInfoPopover(tab: tab) { open(refresh: true) }
                    .environment(model)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appInfoRequested)) { note in
                guard (note.object as? UUID) == tab.id else { return }
                if note.userInfo?["close"] as? Bool == true {
                    isPresented = false
                } else if (note.userInfo?["anchor"] as? String ?? "status") == anchor {
                    open(refresh: false)
                }
            }
    }

    private func open(refresh: Bool) {
        // On production a confirmation sheet asks first: close the popover meanwhile, and show
        // it again once confirmed.
        if refresh, model.isProduction(tab.target) { isPresented = false }
        model.openAppInfo(for: tab, refresh: refresh) { isPresented = true }
    }
}

/// A plain button that tints on hover and press, for chips and status bar items.
struct ChipButtonStyle: ButtonStyle {
    var inset = true

    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(configuration: configuration, inset: inset)
    }

    private struct HoverHighlight: View {
        let configuration: Configuration
        let inset: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, inset ? 3 : 0)
                .padding(.vertical, inset ? 1 : 0)
                .background(RoundedRectangle(cornerRadius: inset ? 4 : 8).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// App Info for one tab's target: its sections of key/value rows, how old they are, Refresh,
/// and errors. Values copy with a click (secret-looking ones are hidden and can't be).
struct AppInfoPopover: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    var refresh: () -> Void
    @State private var copied: String?

    var body: some View {
        let state = model.appInfoState(for: tab.target)
        VStack(alignment: .leading, spacing: 0) {
            header(state)
            Divider()
            content(state)
        }
        .frame(width: 440)
        .frame(maxHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-info-popover")
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ state: AppInfoState) -> some View {
        let report = state.report
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("App Info").font(.headline)
                    EnvironmentBadge(environment: model.library.environment(for: tab.target), compact: true)
                }
                ForEach(subtitle(report), id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if state.isLoading {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.cancelAppInfo(for: tab.target) }
                            .controlSize(.small)
                            .accessibilityIdentifier("app-info-stop")
                    } else {
                        Button {
                            refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Read the App Info again (boots the application)")
                        .accessibilityIdentifier("app-info-refresh")
                    }
                }
                age(state)
            }
        }
        .padding(12)
    }

    /// The driver ("Laravel 13.34.0", "AcmeApiDriver Acme Lease API"), then the target (with the
    /// project driver's file): "Laravel Sandbox 13.34.0", ".runlet/AcmeApiDriver.php · acme-api".
    private func subtitle(_ report: AppInfoReport?) -> [String] {
        var lines: [String] = []
        if let report, let name = report.driverName {
            lines.append(TabCardText.frameworkChip(name: name, version: report.frameworkVersion))
        }
        lines.append(([report?.driverFile].compactMap { $0 } + [model.targetLabel(tab.target)]).joined(separator: " · "))
        return lines
    }

    @ViewBuilder
    private func age(_ state: AppInfoState) -> some View {
        let date: Date? = switch state {
        case .loaded(let report): report.loadedAt
        case .failed(_, let at, _): at
        case .loading(let since, _): since
        case .idle: nil
        }
        if let date {
            TimelineView(.periodic(from: date, by: 5)) { context in
                Text(state.isLoading ? "Booting… \(Int(context.date.timeIntervalSince(date))) s" : "Loaded \(AppInfoPolicy.age(of: date, now: context.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("app-info-age")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ state: AppInfoState) -> some View {
        switch state {
        case .idle:
            placeholder
        case .loading(_, nil):
            VStack(spacing: 10) {
                ProgressView()
                Text("Booting \(model.targetLabel(tab.target)) to read its environment, caches, and drivers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        case .loading(_, let previous?):
            report(previous).opacity(0.55)
        case .loaded(let report):
            self.report(report)
        case .failed(let message, _, _):
            failure(title: "App Info could not load", message: message)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Text("App Info boots the application to read its environment, caches, and drivers. Nothing runs until you ask.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Load App Info", action: refresh)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func report(_ report: AppInfoReport) -> some View {
        if !report.hasSections, let error = report.errors.first {
            failure(title: error.stage == .bootstrap ? "The application could not boot" : "App Info could not load", message: errorText(report.errors, in: report))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !report.errors.isEmpty {
                        banner(errorText(report.errors, in: report), symbol: "xmark.octagon.fill", tint: .red)
                    }
                    if let driverError = report.driverError {
                        banner(driverError, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    ForEach(report.sections) { section in
                        sectionView(section, report: report)
                    }
                    footer(report)
                }
                .padding(12)
            }
            // A popover takes its content's ideal size: give the list one that fits its rows.
            .frame(height: Self.listHeight(report))
        }
    }

    /// About how tall the sections are, between 160 and 520 points (the list scrolls beyond).
    static func listHeight(_ report: AppInfoReport) -> CGFloat {
        let rows = report.sections.reduce(0) { $0 + $1.rows.count + ($1.omittedRows > 0 ? 1 : 0) }
        let extras = report.notes.count + report.notices.prefix(5).count + (report.redactedCount > 0 ? 1 : 0) + (report.omittedSections > 0 ? 1 : 0)
        let banners = (report.errors.isEmpty ? 0 : 1) + (report.driverError == nil ? 0 : 1)
        let height = 28 + CGFloat(report.sections.count) * 32 + CGFloat(rows) * 20 + CGFloat(extras) * 17 + CGFloat(banners) * 48
        return min(520, max(160, height))
    }

    private func sectionView(_ section: AppInfoSection, report: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(section.title).font(.subheadline.weight(.semibold))
                if section.origin == .driver {
                    Text("from \(report.driverFile ?? section.source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(section.rows) { row in
                    GridRow {
                        Text(row.key)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(width: 140, alignment: .leading)
                            .help(row.key)
                        rowValue(row, in: section)
                    }
                    .font(.callout)
                }
            }
            if section.omittedRows > 0 {
                Text("\(section.omittedRows) more \(section.omittedRows == 1 ? "row" : "rows") left out")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-info-section-\(section.title)")
    }

    @ViewBuilder
    private func rowValue(_ row: AppInfoRow, in section: AppInfoSection) -> some View {
        let id = section.id + "/" + row.id
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if row.redacted {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text(row.value.displayText)
                .textSelection(.enabled)
                .foregroundStyle(row.value == .none ? .secondary : .primary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.redacted ? "Hidden: it looks like a secret. Runlet never shows or copies it." : row.value.displayText)
            if !row.redacted {
                Button {
                    Pasteboard.copy(row.value.copyText)
                    copied = id
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        if copied == id { copied = nil }
                    }
                } label: {
                    Image(systemName: copied == id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied == id ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy the value")
                .accessibilityLabel("Copy \(row.key)")
            }
        }
        .contextMenu {
            if !row.redacted {
                Button("Copy Value") { Pasteboard.copy(row.value.copyText) }
            }
            Button("Copy Row") { Pasteboard.copy("\(row.key): \(row.redacted ? AppInfoRedaction.mask : row.value.displayText)") }
        }
    }

    private func footer(_ report: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.redactedCount > 0 {
                Label("\(report.redactedCount) \(report.redactedCount == 1 ? "value that looks" : "values that look") like a secret \(report.redactedCount == 1 ? "is" : "are") hidden.", systemImage: "lock")
            }
            if report.omittedSections > 0 {
                Label("\(report.omittedSections) more \(report.omittedSections == 1 ? "section" : "sections") left out.", systemImage: "ellipsis")
            }
            ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
            }
            ForEach(Array(report.notices.prefix(5).enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "exclamationmark.circle")
            }
            HStack {
                Spacer()
                Button("Copy All") { Pasteboard.copy(Self.text(of: report)) }
                    .controlSize(.small)
                    .accessibilityIdentifier("app-info-copy-all")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func failure(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Try Again", action: refresh)
                    .accessibilityIdentifier("app-info-try-again")
            }
        }
        .padding(12)
        .accessibilityIdentifier("app-info-error")
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.1)))
    }

    /// The errors, each with the file and line it came from (relative to the project, or with
    /// the home folder as ~).
    private func errorText(_ errors: [RunErrorInfo], in report: AppInfoReport? = nil) -> String {
        errors.map { error in
            var text = error.message
            if let file = error.file {
                let root = report?.workingDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
                let shown = root.flatMap { file.hasPrefix($0) ? String(file.dropFirst($0.count)) : nil } ?? (file as NSString).abbreviatingWithTildeInPath
                text += "\n\(shown)" + (error.line.map { ":\($0)" } ?? "")
            }
            return text
        }.joined(separator: "\n\n")
    }

    /// The report as plain text: sections, then "key: value" lines (hidden values stay hidden).
    static func text(of report: AppInfoReport) -> String {
        report.sections.map { section in
            ([section.title] + section.rows.map { "  \($0.key): \($0.redacted ? AppInfoRedaction.mask : $0.value.displayText)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
