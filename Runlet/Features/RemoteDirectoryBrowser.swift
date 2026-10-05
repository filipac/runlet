import RunletCore
import RunletExecution
import SwiftUI

/// Browse… next to an SSH profile's Directory, its container step's working directory, and a
/// Docker profile's working directory: a folder picker that lists folders on the server or in
/// the container (a read-only `php -r`; nothing is written). It connects only while open, one
/// listing per folder visited. Symlinks such as Forge's `current` are shown and kept as
/// chosen, never resolved to `releases/<id>`. A folder the listing user can't open can't be
/// chosen.
struct RemoteDirectoryBrowser: View {
    @Environment(\.dismiss) private var dismiss
    /// "forge@shop", "app on forge@shop" for a container on a server, or a local container's name.
    let place: String
    /// Where to start (blank: the home folder).
    let startPath: String
    /// "on" a server, "in" a container (the title and the loading text).
    var preposition = "on"
    let list: (String) async -> RemoteDirectoryListing
    let choose: (String) -> Void

    @State private var listing: RemoteDirectoryListing?
    @State private var pathText = ""
    @State private var isLoading = false
    @State private var selection: String?
    @State private var showHidden = false
    @State private var loadTask: Task<Void, Never>?
    /// The last folder that listed without an error (Up and the breadcrumb use it).
    @State private var lastGood: RemoteDirectoryListing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a Folder \(preposition) \(place)").font(.headline)
                navigationBar
                breadcrumb
                if let notice = listing?.notice {
                    Label {
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("remote-browser-notice")
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 620, height: 520)
        .onAppear { load(startPath) }
        .onDisappear { loadTask?.cancel() }
        #if DEBUG
        // DEBUG steps `browse:<path>` and `browse:select:<name>` (DebugSteps.swift), for screenshots.
        .onReceive(NotificationCenter.default.publisher(for: .debugRemoteBrowser)) { note in
            let argument = note.userInfo?["argument"] as? String ?? ""
            if argument.hasPrefix("select:") {
                let name = String(argument.dropFirst("select:".count))
                selection = listing?.entries.first { $0.name == name }?.path
            } else {
                load(argument)
            }
        }
        #endif
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button {
                if let parent = (lastGood ?? listing)?.parent { load(parent) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Enclosing folder")
            .disabled((lastGood ?? listing)?.parent == nil || isLoading)
            .accessibilityIdentifier("remote-browser-up")
            Button {
                load("~")
            } label: {
                Image(systemName: "house")
            }
            .help("Home folder")
            .disabled(isLoading)
            TextField("Path", text: $pathText, prompt: Text("/var/www or ~/sites"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { load(pathText) }
                .accessibilityIdentifier("remote-browser-path")
            Button {
                load(pathText)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Go to the typed path, or list this folder again")
            .disabled(isLoading)
        }
    }

    /// "/ › home › forge › site": click a part to go there.
    @ViewBuilder
    private var breadcrumb: some View {
        if let current = lastGood?.path, current.hasPrefix("/") {
            let parts = current.split(separator: "/").map(String.init)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb("/", path: "/")
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        crumb(part, path: "/" + parts[...index].joined(separator: "/"))
                    }
                }
            }
        }
    }

    private func crumb(_ title: String, path: String) -> some View {
        Button(title) { load(path) }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(path == lastGood?.path ? .primary : .secondary)
            .disabled(isLoading)
    }

    // MARK: Listing

    @ViewBuilder
    private var content: some View {
        if isLoading, listing == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Listing folders \(preposition) \(place)…").font(.callout).foregroundStyle(.secondary)
            }
        } else if let listing, let error = listing.error {
            ContentUnavailableView {
                Label("Couldn't List This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                HStack {
                    if lastGood != nil, lastGood?.path != listing.path {
                        // A long path shortens in its middle, keeping both ends (#257).
                        Button { if let path = lastGood?.path { load(path) } } label: {
                            Text("Back to \(lastGood?.path ?? "")").lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Button("Try Again") { load(listing.path) }
                        .fixedSize()
                }
            }
            .accessibilityIdentifier("remote-browser-error")
        } else if let listing {
            let entries = visibleEntries(listing)
            List(selection: $selection) {
                ForEach(entries) { entry in
                    RemoteDirectoryRow(entry: entry, inContainer: preposition == "in")
                        .tag(entry.path)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { paths in
                if let path = paths.first { load(path) }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder", description: Text(listing.entries.isEmpty ? "\(listing.path) has no subfolders." : "Only hidden folders are here."))
                }
            }
            .overlay(alignment: .top) {
                if isLoading { ProgressView().controlSize(.small).padding(6) }
            }
            .accessibilityIdentifier("remote-browser-list")
        }
    }

    private func visibleEntries(_ listing: RemoteDirectoryListing) -> [RemoteDirectoryEntry] {
        showHidden ? listing.entries : listing.entries.filter { !$0.name.hasPrefix(".") }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Show hidden folders", isOn: $showHidden)
                .toggleStyle(.checkbox)
            if let entry = selectedEntry, !entry.readable {
                Label("“\(entry.name)” can't be opened (permission denied), so it can't be the working directory.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("remote-browser-unreadable")
            } else if let listing = lastGood, listing.truncated {
                Text("Only the first \(RemoteDirectories.entryLimit) folders are listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(chooseTitle) {
                if let path = chosenPath {
                    choose(path)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosenPath == nil || isLoading)
            .accessibilityIdentifier("remote-browser-choose")
        }
    }

    private var selectedEntry: RemoteDirectoryEntry? {
        guard let selection else { return nil }
        return listing?.entries.first { $0.path == selection }
    }

    /// The selected subfolder, else the folder being shown (it listed, so it can be opened). A
    /// subfolder the listing user can't open is never chosen: runs couldn't enter it either.
    private var chosenPath: String? {
        if let selection {
            return selectedEntry?.readable == false ? nil : selection
        }
        guard let listing, listing.error == nil else { return nil }
        return listing.path
    }

    private var chooseTitle: String {
        guard let path = chosenPath else { return "Choose" }
        let name = (path as NSString).lastPathComponent
        return "Choose “\(name.isEmpty ? "/" : name)”"
    }

    private func load(_ path: String) {
        let requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            let result = await list(requested)
            guard !Task.isCancelled else { return }
            listing = result
            selection = nil
            isLoading = false
            if result.error == nil {
                lastGood = result
                pathText = result.path
            } else {
                pathText = requested.isEmpty ? result.path : requested
            }
        }
    }
}

/// One folder: name, where a symlink points, and what it looks like (Laravel, Composer, …).
private struct RemoteDirectoryRow: View {
    let entry: RemoteDirectoryEntry
    var inContainer = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isApplication ? "shippingbox.fill" : "folder")
                .foregroundStyle(entry.isApplication ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.readable ? .primary : .secondary)
            if entry.isSymlink {
                Label(entry.target.map { "→ \($0)" } ?? "symlink", systemImage: "arrow.turn.down.right")
                    .labelStyle(.titleOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("A symlink. Runlet keeps it as chosen, so the profile follows it (for example to the next release).")
            }
            Spacer(minLength: 4)
            ForEach(entry.markers, id: \.self) { marker in
                Text(RemoteDirectoryMarkers.label(marker))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            }
            if !entry.readable {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(inContainer ? "The execution user can't open this folder" : "This login can't open this folder")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote-folder-\(entry.name)")
    }
}

enum RemoteDirectoryMarkers {
    static func label(_ marker: String) -> String {
        switch marker {
        case "laravel": "Laravel"
        case "symfony": "Symfony"
        case "wordpress": "WordPress"
        case "composer": "Composer"
        case "runlet": ".runlet"
        default: marker
        }
    }
}

/// What Detect found: the home folder first, then folders that look like PHP applications.
/// Clicking one fills the Directory field.
struct DetectedDirectoriesView: View {
    let detection: RemoteDirectoryDetection
    let place: String
    var connect: (() -> Void)?
    let use: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = detection.error {
                Label {
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                if let connect {
                    Button("Connect…", action: connect)
                }
            }
            if let home = detection.home {
                Text("Home folder\(detection.user.map { " of \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                pathButton(home, markers: [])
            }
            if !detection.candidates.isEmpty {
                Text("Applications on \(place)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(detection.candidates) { candidate in
                            pathButton(candidate.path, markers: candidate.markers, symlink: candidate.isSymlink ? candidate.target : nil)
                        }
                    }
                }
                .frame(maxHeight: 260)
            } else if detection.error == nil {
                Text("No folders with artisan, composer.json, wp-config.php, or .runlet were found in the usual places. Use Browse… to look around.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        .accessibilityIdentifier("ssh-detected-directories")
    }

    private func pathButton(_ path: String, markers: [String], symlink: String? = nil) -> some View {
        Button {
            use(path)
        } label: {
            HStack(spacing: 6) {
                Text(path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let symlink {
                    Text("→ \(symlink)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                ForEach(markers, id: \.self) { marker in
                    Text(RemoteDirectoryMarkers.label(marker))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .help("Use \(path)")
    }
}

#if DEBUG
extension Notification.Name {
    /// DEBUG steps `browse:<path>` (lists that folder in the open directory browser) and
    /// `browse:select:<name>` (selects a listed subfolder).
    static let debugRemoteBrowser = Notification.Name("RunletDebugRemoteBrowser")
}
#endif
