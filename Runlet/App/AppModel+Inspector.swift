import AppKit
import RunletCore
import UniformTypeIdentifiers

/// Run inspector settings per target, and exporting a tab's output.
extension AppModel {
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
