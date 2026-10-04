import AppKit
import RunletCore
import SwiftUI

/// The Software Update window (#233): the offer (version, release notes, size), the download's
/// progress, and anything that went wrong. One window, opened by `AppUpdater`.
@MainActor
enum UpdateWindow {
    static let title = "Software Update"
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(_ updater: AppUpdater) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: UpdateView(updater: updater))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.title = title
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("software-update-window")
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                Self.window = nil
                updater.windowWillClose()
            }
        }
        self.window = window
        #if DEBUG
        if DebugSteps.isGhosted {
            window.orderFront(nil)
            return
        }
        #endif
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    static var isVisible: Bool { window?.isVisible ?? false }
}

struct UpdateView: View {
    let updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(width: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            header("Checking for updates…", detail: "Looking for a newer \(channelName) version of Runlet.", symbol: nil)
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            header("Runlet is up to date", detail: "\(runningName) is the newest version on the \(channelName) channel.", symbol: nil)
            buttons { okButton }
        case .found(let offer):
            offerHeader(offer)
            ReleaseNotesView(text: offer.notes, format: offer.notesFormat)
            notices
            HStack {
                Button("Skip This Version") { updater.skipVersion() }
                    .accessibilityIdentifier("update-skip")
                Spacer()
                Button("Later") { updater.later() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("update-later")
                Button("Install and Relaunch") { updater.installOffer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.isRunInProgress)
                    .accessibilityIdentifier("update-install")
            }
        case .downloading(let offer, let received, let expected):
            offerHeader(offer)
            VStack(alignment: .leading, spacing: 6) {
                if let expected, expected > 0 {
                    ProgressView(value: Double(min(received, expected)), total: Double(expected))
                    Text("Downloading… \(Self.bytes(received)) of \(Self.bytes(expected))")
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Downloading… \(Self.bytes(received))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            buttons { Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("update-cancel") }
        case .extracting(let offer, let progress):
            offerHeader(offer)
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text("Checking the signature and unpacking…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .readyToInstall(let offer):
            offerHeader(offer)
            Label("Downloaded and verified. Install when the running code has finished, or stop it first: quitting stops it.", systemImage: "checkmark.seal")
                .font(.callout)
            buttons {
                Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.installNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.isRunInProgress)
            }
        case .installing(let offer):
            header("Installing Runlet \(offer.version.displayName)…", detail: "Runlet quits, the new version replaces it, and it opens again.", symbol: nil)
            ProgressView().progressViewStyle(.linear)
        case .problem(let problem):
            problemView(problem)
        }
    }

    private var channelName: String { updater.channel.displayName }
    private var runningName: String { "Runlet \(updater.running?.description ?? "")" }

    private func offerHeader(_ offer: AppUpdater.Offer) -> some View {
        var detail = "Runlet \(offer.version.displayName) (\(offer.version.build)) is available on the \(channelName) channel. You have \(updater.running?.description ?? "an older version")."
        if let size = offer.size { detail += " Download: \(Self.bytes(size))." }
        return header("A new version of Runlet is available", detail: detail, symbol: nil, link: offer.releasePage)
    }

    @ViewBuilder private var notices: some View {
        if updater.isRunInProgress {
            Label("Code is running. Stop it or let it finish, then install.", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if case .needsAdministrator(let folder) = updater.installLocation {
            Label("Runlet's folder (\(folder)) isn't writable by your account, so macOS asks for an administrator's name and password to install the update.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update-needs-administrator")
        }
    }

    @ViewBuilder private func problemView(_ problem: AppUpdater.Problem) -> some View {
        switch problem {
        case .notConfigured:
            header("Updates aren't set up in this build", detail: "This copy of Runlet has no update signing key, so it can't verify updates and won't install any. Download new versions from GitHub.", symbol: "exclamationmark.triangle")
            buttons {
                releasesButton
                okButton
            }
        case .mustMove(let location):
            header("Move Runlet to Applications first", detail: Self.moveDetail(location), symbol: "folder.badge.questionmark")
            buttons { okButton }
        case .couldNotCheck(let detail):
            header("Couldn't check for updates", detail: "Runlet couldn't read the list of releases. Check your connection, or try again later.", symbol: "wifi.exclamationmark")
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Try Again") { updater.check(userInitiated: true) }
                okButton
            }
        case .failed(let title, let detail):
            header(title, detail: detail, symbol: "exclamationmark.triangle")
            buttons { okButton }
        case .afterUpdate(let result, let record):
            let to = record.map { "Runlet \($0.toVersion)" } ?? "The new version"
            let from = record.map { "Runlet \($0.fromVersion)" } ?? "the previous version"
            switch result.outcome {
            case .rolledBack:
                header("\(to) didn't start", detail: "Runlet put back \(from), the version you had, and that's what is running now. \(result.detail)", symbol: "arrow.uturn.backward.circle")
                buttons {
                    releasesButton
                    okButton
                }
            case .notInstalled:
                header("The update wasn't installed", detail: "The installer didn't replace Runlet, so \(from) is still installed.", symbol: "exclamationmark.triangle")
                buttons { okButton }
            case .restoreFailed:
                header("\(to) didn't start", detail: "Runlet couldn't put \(from) back either. Download Runlet again from GitHub. \(result.detail)", symbol: "xmark.octagon")
                buttons {
                    releasesButton
                    okButton
                }
            case .updated:
                header("Runlet was updated", detail: "\(to) is installed.", symbol: nil)
                buttons { okButton }
            }
        }
    }

    static func moveDetail(_ location: UpdateInstallLocation) -> String {
        switch location {
        case .translocated:
            "macOS runs this copy from a temporary read-only location because it was opened straight from where it was downloaded. Quit Runlet, drag it to your Applications folder, and open it from there; then it can update itself."
        case .readOnlyVolume:
            "Runlet is running from the disk image, which is read-only. Quit Runlet, drag it to your Applications folder, and open it from there; then it can update itself."
        case .ready, .needsAdministrator:
            ""
        }
    }

    private var okButton: some View {
        Button("OK") { UpdateWindow.close() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("update-ok")
    }

    private var releasesButton: some View {
        Button("Open Releases Page") {
            if let url = URL(string: "https://github.com/filipac/runlet/releases") { NSWorkspace.shared.open(url) }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func header(_ title: String, detail: String, symbol: String?, link: URL? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.background).padding(-2))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Link("Release page on GitHub", destination: link).font(.callout)
                }
            }
        }
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

/// Release notes from the appcast item: Markdown (GitHub's release body) drawn as headings,
/// nested bullets, and paragraphs with inline styles; plain text as it is; HTML as its text.
struct ReleaseNotesView: View {
    let text: String
    let format: String

    enum Block: Hashable {
        case heading(String)
        case bullet(depth: Int, text: String)
        case paragraph(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if blocks.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
        .frame(height: 240)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityIdentifier("update-release-notes")
    }

    @ViewBuilder private func row(_ block: Block) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text)).font(.headline).padding(.top, 4)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blocks: [Block] { Self.blocks(text, format: format) }

    static func blocks(_ text: String, format: String) -> [Block] {
        switch format {
        case "plain-text":
            return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { .paragraph($0) }
        case "markdown":
            return markdownBlocks(text)
        default:
            let data = Data(text.utf8)
            let plain = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil))?.string ?? text
            return blocks(plain, format: "plain-text")
        }
    }

    static func markdownBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(depth: min(indent / 2, 3), text: String(line.dropFirst(2))))
            } else if case .bullet(let depth, let previous)? = blocks.last, paragraph.isEmpty, indent > 0 {
                // A bullet's continuation line.
                blocks[blocks.count - 1] = .bullet(depth: depth, text: previous + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
