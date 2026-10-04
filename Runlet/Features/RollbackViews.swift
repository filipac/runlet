import RunletCore
import SwiftUI

/// Rollback ("dry run") mode (#13): the toolbar toggle of a PHP tab, the bar above its editor
/// while it is on, the output's cards, and the badge the production confirmation shows.

/// The toolbar's Dry Run toggle (PHP tabs). Turning it on runs nothing.
struct DryRunToolbarButton: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        Button {
            model.setRollback(!tab.rollback, for: tab)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.rollback ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward.circle")
                Text(tab.rollback ? "DRY RUN" : "Dry Run")
                    .fontWeight(tab.rollback ? .semibold : .regular)
            }
            .foregroundStyle(tab.rollback ? Color.orange : Color.secondary)
        }
        .help(tab.rollback
            ? "Dry Run is on: runs of this tab roll back their database changes. Click to turn it off."
            : "Dry Run: run this tab in a database transaction that Runlet always rolls back, and see how many statements it undid. " + RollbackReport.limits)
        .accessibilityLabel(tab.rollback ? "Dry Run on: database changes are rolled back" : "Turn on Dry Run")
        .accessibilityIdentifier("dry-run-toggle")
    }
}

/// Above a PHP tab's editor while Dry Run is on: what it does, and what it doesn't cover.
struct DryRunBar: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if tab.rollback, tab.language == .php {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange)
                Text("Dry run: database changes are rolled back").fontWeight(.semibold)
                Text("Mail, queues, HTTP calls, files, and caches aren't; MySQL and MariaDB commit schema changes at once, and locks are held until the run ends.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(RollbackReport.limits)
                Spacer(minLength: 0)
                Button("Turn Off") { model.setRollback(false, for: tab) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("dry-run-off")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dry-run-bar")
        }
    }
}

/// "DRY RUN" capsule (the production confirmation).
struct DryRunBadge: View {
    var body: some View {
        Text("DRY RUN")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.orange))
            .help("A dry run: Runlet rolls back the database changes on the application's connections after the run")
            .accessibilityLabel("Dry run")
    }
}

/// A dry run's warning as it happened, or its outcome after the output.
struct RollbackCard: View {
    let report: RollbackReport
    let line: Int?
    let tab: TabModel

    var body: some View {
        switch report.state {
        case .warning:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(report.warning?.message ?? report.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let line {
                    Button("line \(line)") { tab.editor.goTo(line: line) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("output-rollback-warning")
        case .begun:
            EmptyView()
        case .finished, .stopped:
            let tint: Color = report.state == .stopped || report.hasProblems ? .orange : .green
            Card(title: report.state == .stopped ? "Dry run stopped" : "Dry run", subtitle: report.title, tint: tint, copyText: report.plainText) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(report.details.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if report.state == .finished, !(report.warnings ?? []).isEmpty {
                        ForEach(Array((report.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let omitted = report.omittedWarnings, omitted > 0 {
                            Text("\(omitted) more warning\(omitted == 1 ? "" : "s") in the Run Log.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(report.state == .stopped ? "Mail, queued jobs on other connections, HTTP calls, and files aren't covered by a dry run." : "Mail, queued jobs on other connections, HTTP calls, files, and caches aren't rolled back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("output-rollback")
        }
    }
}
