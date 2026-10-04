import AppKit
import RunletCore
import UniformTypeIdentifiers

/// Run inspector settings per target, and exporting a tab's output.
extension AppModel {
    /// #4: opening Explain is an editing action. Only the normal Run action executes it.
    func explain(_ query: QueryRecord, from tab: TabModel, index: Int) {
        guard let target = tab.inspectionTarget, let window = window(containing: tab.id),
              let code = QueryExplain.code(for: query, style: explainStyle(for: query, in: tab)) else { return }
        newTab(target: target, code: code, title: "Explain #\(index)", in: window)
    }

    func explainStyle(for query: QueryRecord, in tab: TabModel) -> QueryExplain.ConnectionStyle {
        let driver = tab.inspection.info?.driverName
        switch query.databaseAPI {
        case "eloquent":
            return ["Laravel", "Laravel Zero", "Lumen"].contains(driver ?? "") ? .laravel : .eloquent
        case "doctrine" where driver == "Symfony": return .doctrine
        case "doctrine": return .doctrineManual
        case "wordpress": return .wordpress
        default: return .pdo
        }
    }

    /// Whether runs on `target` ask drivers to intercept mail: the project's, Docker
    /// profile's, or SSH profile's override, else Settings ▸ General ▸ Run Inspector.
    func interceptMail(for target: TargetRef) -> Bool {
        library.interceptMail(for: target, global: settings.interceptMail)
    }

    /// What a run on `target` asks of the run inspector. Mail interception needs the
    /// inspector (drivers intercept from their inspect() hook), so it keeps it on.
    func inspectorOptions(for target: TargetRef) -> RunInspectorOptions {
        let intercept = interceptMail(for: target)
        return RunInspectorOptions(enabled: settings.runInspector || intercept, interceptMail: intercept, previews: settings.renderPreviews)
    }

    /// Flips the global Intercept Mail setting (per-target overrides still win).
    func toggleMailInterception() {
        settings.interceptMail.toggle()
    }

    /// The output header's mail chip for `target` (#193): the effective mode, where it comes
    /// from, and the target's own Mail option.
    func mailInterception(for target: TargetRef) -> MailInterception {
        library.mailInterception(for: target, global: settings.interceptMail, runInspector: settings.runInspector)
    }

    /// The last run on `target` that asked to intercept mail: whether a driver confirmed it.
    /// nil before such a run in this session, so nothing is said about support then.
    func mailInterceptionReport(for target: TargetRef) -> InspectorInfo? {
        mailInterceptionReports[target.stableKey]
    }

    /// Sets the target's Mail option (nil: Default, following Settings) as its editor's Mail
    /// picker and Save do, so the editor shows the same value. Applies from the next run. The
    /// sandbox has no option of its own.
    func setInterceptMail(_ value: Bool?, for target: TargetRef) {
        switch target {
        case .sandbox:
            return
        case .local(let id):
            guard var project = library.localProject(id), project.interceptMail != value else { return }
            project.interceptMail = value
            saveProject(project)
        case .docker(let id):
            guard var profile = library.dockerProfile(id), profile.interceptMail != value else { return }
            profile.interceptMail = value
            saveDockerProfile(profile)
        case .ssh(let id):
            guard var profile = library.sshProfile(id), profile.interceptMail != value else { return }
            profile.interceptMail = value
            saveSSHProfile(profile)
        }
    }

    /// Settings ▸ General, where the Run Inspector section sets the default (the mail chip's link).
    func showGeneralSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SettingsTabSelection.select("General")
        }
    }

    /// Run ▸ Save Output As…: the tab's output as Markdown, plain text, or raw stdout/stderr.
    func saveOutput(of tab: TabModel) {
        enum Format: Int, CaseIterable {
            case markdown, plain, raw
            var title: String {
                switch self {
                case .markdown: "Markdown (.md)"
                case .plain: "Plain Text (.txt)"
                case .raw: "Raw Output (.txt)"
                }
            }
            var type: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText }
        }
        let panel = NSSavePanel()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Format.allCases.map(\.title))
        let initial: Format = switch settings.outputMode {
        case .structured: .markdown
        case .plain: .plain
        case .raw: .raw
        }
        popup.selectItem(at: initial.rawValue)
        let base = (tab.title as NSString).deletingPathExtension
        func apply(_ format: Format) {
            panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = "\((panel.nameFieldStringValue as NSString).deletingPathExtension).\(format == .markdown ? "md" : "txt")"
        }
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.nameFieldStringValue = "\(base.isEmpty ? "Output" : base) output"
        panel.message = "Save this tab's output."
        apply(initial)
        let target = PopupTarget { index in Format(rawValue: index).map(apply) }
        popup.target = target
        popup.action = #selector(PopupTarget.changed(_:))
        // The popup holds its target weakly.
        let response = withExtendedLifetime(target) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        let format = Format(rawValue: popup.indexOfSelectedItem) ?? initial
        let text = switch format {
        case .markdown: tab.outputMarkdown
        case .plain: tab.outputPlainText
        case .raw: tab.rawOutput
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = AppAlert(title: "Couldn't save the output", message: error.localizedDescription)
        }
    }
}

/// Forwards an NSPopUpButton's action to a closure.
private final class PopupTarget: NSObject {
    let onChange: (Int) -> Void

    init(_ onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }
}
