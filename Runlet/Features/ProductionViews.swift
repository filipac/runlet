import AppKit
import RunletCore
import SwiftUI

extension TargetColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

extension TargetEnvironment {
    /// The badge colour: production is always red, staging orange.
    var tint: Color {
        switch self {
        case .development: .secondary
        case .staging: .orange
        case .production: .red
        }
    }
}

/// "PRODUCTION" / "STAGING" capsule for tab cards, tabs, the toolbar, and lists. Nothing for
/// development targets.
struct EnvironmentBadge: View {
    var environment: TargetEnvironment
    var compact = false

    var body: some View {
        if environment != .development {
            Text(compact && environment == .production ? "PROD" : environment.displayName.uppercased())
                .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
                .padding(.horizontal, compact ? 4 : 5)
                .padding(.vertical, 1.5)
                .foregroundStyle(.white)
                .background(Capsule().fill(environment.tint))
                .help(environment == .production ? "Production: every run asks first (⌘↩ confirms), and nothing loads or connects by itself." : "Staging")
                .accessibilityLabel(environment.displayName)
                .accessibilityIdentifier("environment-badge-\(environment.rawValue)")
        }
    }
}

/// #12: above a tab whose application reported an environment that disagrees with how its
/// target is marked. Mark as Production saves the marking (nothing runs); Dismiss hides this
/// kind of notice for the target. Nothing here changes a marking by itself.
struct AppEnvironmentBanner: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if let notice = model.environmentNotice(for: tab.target) {
            let offer = notice.kind == .reportsProduction
            HStack(spacing: 8) {
                Image(systemName: offer ? "exclamationmark.shield.fill" : "info.circle.fill")
                    .foregroundStyle(offer ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                Text(notice.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer()
                if offer {
                    Button("Mark as Production") { model.markAsProduction(tab.target) }
                        .help("Marks \(model.targetLabel(tab.target)) as production, as its settings would: a red badge and a confirmation before every run. Nothing runs now.")
                        .accessibilityIdentifier("environment-mark-production")
                }
                Button("Dismiss") { model.dismissEnvironmentNotice(notice.kind, for: tab.target) }
                    .help("Don't show this notice for this target again")
                    .accessibilityIdentifier("environment-notice-dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((offer ? Color.red : Color.secondary).opacity(0.1))
            .accessibilityIdentifier("environment-notice-\(notice.kind.rawValue)")
        }
    }
}

/// Environment and colour of a target, for project options and profile forms.
struct TargetEnvironmentFields: View {
    @Binding var environment: TargetEnvironment
    @Binding var color: TargetColor?

    var body: some View {
        Picker("Environment", selection: $environment) {
            ForEach(TargetEnvironment.allCases, id: \.self) { environment in
                Text(environment.displayName).tag(environment)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("target-environment")
        Picker("Colour", selection: $color) {
            Text("None").tag(TargetColor?.none)
            ForEach(TargetColor.allCases, id: \.self) { color in
                Label {
                    Text(color.displayName)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(color.color)
                }
                .tag(TargetColor?.some(color))
            }
        }
        .accessibilityIdentifier("target-color")
        Text(environment == .production
             ? "Production targets show a red badge, ask before every run (⌘↩ confirms; you can skip snippet confirmations for 10 minutes), ask before every project command, and never list commands or connect by themselves."
             : "The colour marks this target's tabs and status bar. Mark live systems as production to get a confirmation before each run.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bindings for targets whose environment is optional in storage (nil = development).
extension Binding where Value == TargetEnvironment? {
    var orDevelopment: Binding<TargetEnvironment> {
        Binding<TargetEnvironment>(
            get: { wrappedValue ?? .development },
            set: { wrappedValue = $0 == .development ? nil : $0 }
        )
    }
}

/// Asks before code runs on a production target. ⌘↩ confirms; ↩ and Esc cancel. Snippet runs
/// can skip the question for 10 minutes (in memory only).
struct ProductionConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    let confirmation: ProductionConfirmation
    @State private var grace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmation.title).font(.headline)
                    Text(confirmation.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Target").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(confirmation.targetName).fontWeight(.semibold)
                        EnvironmentBadge(environment: .production)
                    }
                }
                if !confirmation.destination.isEmpty {
                    GridRow {
                        Text(confirmation.runsOnThisMac ? "Runs in" : "Where").foregroundStyle(.secondary)
                        Text(confirmation.runsOnThisMac ? "this Mac, the project's local folder" : confirmation.destination)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.callout)
            if let warning = confirmation.sqlWarning {
                // SQL tabs (#35): detection is best-effort, so the sheet says so.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning).fontWeight(.semibold)
                        Text("Runlet's write detection is best-effort: read the statement before you run it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.35)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("production-sql-warning")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(previewCaption).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(confirmation.preview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .accessibilityIdentifier("production-preview")
            }
            if confirmation.allowsGrace {
                Toggle("Don't ask again for 10 minutes for this target (snippet runs only)", isOn: $grace)
                    .accessibilityIdentifier("production-grace")
            }
            HStack {
                Text("⌘↩ confirms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // ↩ alone cancels: the safe choice is the default.
                Button("Cancel") { model.cancelProduction() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("production-cancel")
                Button(confirmation.confirmTitle, role: .destructive) { model.confirmProduction(confirmation, grace: grace) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .tint(.red)
                    .accessibilityIdentifier("production-confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onExitCommand { model.cancelProduction() }
        .accessibilityIdentifier("production-confirmation")
    }

    private var previewCaption: String {
        let what = switch confirmation.action {
        case .run: confirmation.isSelection ? "Selection" : "Code"
        case .sql: "SQL statement"
        case .listCommands, .shell, .repl, .appInfo: "Action"
        case .command: "Command"
        }
        let lines = confirmation.lineCount
        if lines > ProductionGrace.previewLines {
            return "\(what) · first \(ProductionGrace.previewLines) of \(lines) lines"
        }
        return lines == 1 ? what : "\(what) · \(lines) lines"
    }
}
