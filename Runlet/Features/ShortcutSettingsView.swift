import AppKit
import RunletCore
import SwiftUI

/// Settings ▸ Shortcuts: every command from the catalog, searchable, with recording,
/// clearing, per-command reset, conflict warnings, and Reset All.
struct ShortcutSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var recordingId: String?
    @State private var monitor: Any?

    var body: some View {
        let effective = model.effectiveShortcuts
        let conflicts = ShortcutResolver.conflicts(in: effective)
        let conflicted = Set(conflicts.values.flatMap { $0 })
        VStack(spacing: 0) {
            QuickRunHotKeySettings() // #25
            Divider()
            HStack {
                TextField("Search commands or shortcuts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("shortcut-search")
                Button("Reset All") {
                    model.settings.shortcutOverrides = [:]
                }
                .disabled(model.settings.shortcutOverrides.isEmpty)
            }
            .padding(12)
            if !conflicts.isEmpty {
                Label("\(conflicts.count) shortcut\(conflicts.count == 1 ? " is" : "s are") assigned to more than one command. Only one of them will work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            List {
                ForEach(AppCommand.Category.allCases, id: \.self) { category in
                    let commands = CommandCatalog.all.filter { $0.category == category && matches($0, effective[$0.id]) }
                    if !commands.isEmpty {
                        Section(category.rawValue) {
                            ForEach(commands) { command in
                                row(command, combo: effective[command.id], conflicted: conflicted.contains(command.id))
                            }
                        }
                    }
                }
            }
            Text("Click Record, then press the new key combination. Esc cancels; Delete clears the shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .onDisappear { stopRecording() }
    }

    private func matches(_ command: AppCommand, _ combo: KeyCombo?) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return FuzzyMatch.score(query, fields: [command.title, command.category.rawValue, combo?.displayString ?? "", command.keywords]) != nil
    }

    @ViewBuilder
    private func row(_ command: AppCommand, combo: KeyCombo?, conflicted: Bool) -> some View {
        let customized = model.settings.shortcutOverrides[command.id] != nil
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                if customized, let defaultCombo = command.defaultShortcut {
                    Text("Default: \(defaultCombo.displayString)").font(.caption2).foregroundStyle(.secondary)
                } else if customized {
                    Text("Default: none").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if conflicted {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("This shortcut is also used by another command.")
            }
            if recordingId == command.id {
                Text("Press keys…")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 90)
                Button("Cancel") { stopRecording() }
            } else {
                Text(combo?.displayString ?? "—")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(combo == nil ? .secondary : .primary)
                    .frame(minWidth: 90, alignment: .trailing)
                Button("Record") { startRecording(command.id) }
                    .accessibilityIdentifier("record-\(command.id)")
                Menu {
                    Button("Clear Shortcut") { model.setShortcut(nil, for: command.id) }
                    Button("Reset to Default") { model.settings.shortcutOverrides[command.id] = nil }
                        .disabled(!customized)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .accessibilityIdentifier("shortcut-row-\(command.id)")
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recordingId = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let recording = recordingId else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty { // esc
                stopRecording()
                return nil
            }
            if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty { // delete / forward delete
                model.setShortcut(nil, for: recording)
                stopRecording()
                return nil
            }
            if let combo = KeyCombo(event: event), combo.isValidShortcut {
                model.setShortcut(combo, for: recording)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingId = nil
    }
}

/// Settings ▸ Shortcuts ▸ Quick Run (#25): the panel's global shortcut, off by default, with its
/// recorder and what stands in its way (another app, macOS, or one of Runlet's commands).
struct QuickRunHotKeySettings: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    /// Why the last key combination couldn't be recorded.
    @State private var rejected: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor)
                Toggle(isOn: $model.settings.quickRunHotKeyEnabled) {
                    Text("Open Quick Run from any app")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("quick-run-hotkey-toggle")
                Spacer()
                if recording {
                    Text("Press keys…")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: 90)
                    Button("Cancel") { stopRecording() }
                } else {
                    Text(model.settings.quickRunHotKey.displayString)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(model.settings.quickRunHotKeyEnabled ? .primary : .secondary)
                        .frame(minWidth: 90, alignment: .trailing)
                        .accessibilityIdentifier("quick-run-hotkey")
                    Button("Record") { startRecording() }
                        .accessibilityIdentifier("quick-run-hotkey-record")
                }
            }
            status
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quick-run-hotkey-status")
        }
        .padding(12)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var status: some View {
        if let rejected {
            Label(rejected, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            switch model.quickRun.hotKeyStatus {
            case .off:
                Text("A floating panel for a line of PHP, on the Laravel Sandbox unless you choose another target. Turned off, Window ▸ Quick Run, the command palette, and Open Anything still open it.")
                    .foregroundStyle(.secondary)
            case .noShortcut:
                Text("Record a shortcut to open Quick Run from any app.").foregroundStyle(.secondary)
            case .active(let hotKey):
                Label("\(hotKey.displayString) opens Quick Run from every app, and closes it again. No Accessibility permission is needed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(_, let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func startRecording() {
        stopRecording()
        rejected = nil
        recording = true
        // The shortcut is let go while recording, so pressing it again records it instead of
        // opening the panel.
        model.releaseQuickRunHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty { // esc
                stopRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                NSSound.beep()
                return nil
            }
            let hotKey = GlobalHotKey(keyCode: Int(event.keyCode), combo: combo)
            guard hotKey.isValid else {
                rejected = "\(combo.displayString) needs ⌘, ⌃, or ⌥ to work in every app."
                NSSound.beep()
                return nil
            }
            rejected = nil
            model.settings.quickRunHotKey = hotKey
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        model.applyQuickRunHotKey()
    }
}
