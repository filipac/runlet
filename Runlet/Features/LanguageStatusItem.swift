import RunletLanguage
import SwiftUI

/// The status bar's PHPantom item (#336): ready, limited, failed, or indexing with its
/// percentage ("Indexing… 42%", the server's message in the tooltip). A click opens
/// `LanguageStatusPopover`.
///
/// It reads the tab's language state and activity itself, and the status bar doesn't, so the
/// progress reports PHPantom sends about ten times a second while it indexes redraw only this
/// item, never the status bar or the window.
struct LanguageStatusItem: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        @Bindable var tab = tab
        let summary = LanguageStatusSummary(state: tab.languageState, activity: tab.languageActivity, limitations: tab.languageNotes)
        Button {
            tab.languagePopoverShown.toggle()
        } label: {
            Label(summary.title, systemImage: summary.symbol)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(summary.isFailure ? Color.red : Color.secondary)
        }
        .buttonStyle(ChipButtonStyle())
        .help(summary.help)
        .accessibilityLabel(summary.title)
        .accessibilityValue(summary.help)
        .accessibilityIdentifier("language-status")
        .popover(isPresented: $tab.languagePopoverShown, arrowEdge: .top) {
            LanguageStatusPopover(tab: tab)
                .environment(model)
        }
    }
}

/// What PHPantom is doing for the tab's project (#336): its state, the indexed folder, the
/// current or last progress message, which files it watches, the limitations, and Reindex
/// Project.
struct LanguageStatusPopover: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        let state = tab.languageState
        let activity = tab.languageActivity
        let summary = LanguageStatusSummary(state: state, activity: activity, limitations: tab.languageNotes)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary.symbol)
                    .font(.title2)
                    .foregroundStyle(summary.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PHPantom").font(.headline)
                    Text(LanguageStatusSummary.stateLine(state: state, activity: activity))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("language-popover-state")
                }
            }
            if let progress = activity.progress, let percentage = progress.percentage {
                ProgressView(value: Double(percentage), total: 100)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("language-popover-progress")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Folder") {
                    if let folder = model.languageFolderDescription(for: tab) {
                        Text(folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(folder)
                    } else {
                        Text("None: built-in PHP only").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("language-popover-folder")
                if let message = progressMessage(activity) {
                    row(activity.progress == nil ? "Last update" : "Now") {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("language-popover-message")
                }
                row("Changes on disk") {
                    Text(watching(state: state, activity: activity))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("language-popover-watching")
            }
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tab.languageNotes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("language-popover-limitations")
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Indexes the project from scratch. Nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reindex Project") { model.reindexProject(for: tab) }
                    .disabled(reindexDisabledReason(state) != nil)
                    .help(reindexDisabledReason(state) ?? reindexHelp)
                    .accessibilityIdentifier("language-popover-reindex")
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("language-popover")
        .onExitCommand { tab.languagePopoverShown = false }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The operation in progress, or the last one: "Scanning vendor packages (1200/2900 files)",
    /// "Indexed 41 classes".
    private func progressMessage(_ activity: LanguageServerActivity) -> String? {
        if let progress = activity.progress { return progress.message ?? progress.title }
        return activity.lastProgress.flatMap { $0.message ?? $0.title }
    }

    private func watching(state: LanguageServerState, activity: LanguageServerActivity) -> String {
        if activity.isWatchingFiles { return "Sent to PHPantom: " + LanguageStatusSummary.watchedFiles(activity.watchedPatterns) }
        guard model.languageFolderDescription(for: tab) != nil else { return "Not watched: there's no local folder" }
        return state.isReady ? "Watched once indexing ends" : "Not watched while PHPantom is off"
    }

    private func reindexDisabledReason(_ state: LanguageServerState) -> String? {
        switch state {
        case .starting, .restarting: "PHPantom is starting"
        default: model.reindexProjectDisabledReason(for: tab)
        }
    }

    /// "Index the project again (⌥⌘I)", with the shortcut when one is set.
    private var reindexHelp: String {
        let help = "Index the project again"
        return model.shortcut(for: "library.reindexProject").map { "\(help) (\($0.displayString))" } ?? help
    }
}
