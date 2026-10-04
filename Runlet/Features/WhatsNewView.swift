import AppKit
import RunletCore
import SwiftUI

// What's New (#232): the window that shows a version's highlights after an update (and from
// Help ▸ What's New), with Show Me tours; and Settings ▸ General ▸ Tips.

struct WhatsNewContent {
    var sections: [WhatsNewSection]
    /// "Since 0.4.0 beta 6", "Highlights of 0.4.0 beta 7".
    var subtitle: String
    var changelog: URL?
}

/// What's New's window: one, made in AppKit so no scene has to be declared for it.
@MainActor
final class WhatsNewWindow: NSObject, NSWindowDelegate {
    static let shared = WhatsNewWindow()
    static let title = "What's New"

    private var window: WhatsNewNSWindow?
    private(set) var content: WhatsNewContent?
    /// Hidden while a Show Me tour runs.
    private var steppedAside = false

    var isVisible: Bool { window?.isVisible == true || steppedAside }

    func show(_ content: WhatsNewContent, model: AppModel) {
        self.content = content
        steppedAside = false
        let root = WhatsNewView(content: content, close: { WhatsNewWindow.shared.close() })
            .environment(model)
            .preferredColorScheme(model.settings.appearance.colorScheme)
        if let window {
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
        } else {
            let window = WhatsNewNSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = Self.title
            window.identifier = NSUserInterfaceItemIdentifier("whats-new")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let controller = NSHostingController(rootView: AnyView(root))
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 680, height: 640))
            window.contentMinSize = NSSize(width: 560, height: 420)
            window.setAccessibilityIdentifier("whats-new-window")
            window.center()
            self.window = window
        }
        #if DEBUG
        // Screenshot runs keep Runlet in the background.
        if DebugSteps.isGhosted { return window?.orderFront(nil) ?? () }
        #endif
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        steppedAside = false
        window?.close()
    }

    /// Show Me: out of the way while the tour runs over the main window.
    func stepAside() {
        guard let window, window.isVisible else { return }
        steppedAside = true
        window.orderOut(nil)
    }

    func comeBack() {
        guard steppedAside, let window else { return }
        steppedAside = false
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        steppedAside = false
    }
}

/// Esc closes it.
final class WhatsNewNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    let content: WhatsNewContent
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if content.sections.isEmpty {
                        Text("Nothing new to show for this version.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(content.sections) { section in
                        WhatsNewSectionView(section: section, showsLabel: content.sections.count > 1)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("whats-new")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New in Runlet")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if !content.subtitle.isEmpty {
                    Text(content.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("whats-new-subtitle")
                }
            }
        }
    }

    private var footer: some View {
        @Bindable var model = model
        return HStack(spacing: 14) {
            Toggle("Show after updates", isOn: $model.settings.showWhatsNewAfterUpdates)
                .toggleStyle(.checkbox)
                .help("Settings ▸ General ▸ Tips: show this window the first time a newer version or build starts.")
                .accessibilityIdentifier("whats-new-show-after-updates")
            Spacer()
            if let changelog = content.changelog {
                Link("Full Changelog", destination: changelog)
                    .accessibilityIdentifier("whats-new-changelog")
            }
            Button("Continue") { close() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("whats-new-continue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct WhatsNewSectionView: View {
    let section: WhatsNewSection
    let showsLabel: Bool

    var body: some View {
        let featured = section.features.filter(\.important)
        let others = section.features.filter { !$0.important }
        VStack(alignment: .leading, spacing: 16) {
            if showsLabel {
                Text(section.label)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(featured) { feature in
                WhatsNewFeaturedCard(feature: feature)
            }
            if !others.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(others) { feature in
                        WhatsNewFeatureCard(feature: feature)
                    }
                }
            }
            if !section.also.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Also in this version")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.also.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("whats-new-also")
            }
            if let notes = section.notes {
                Link("Release notes for \(section.label)", destination: notes)
                    .font(.callout)
            }
        }
    }
}

/// An important feature: a banner across the window.
private struct WhatsNewFeaturedCard: View {
    @Environment(AppModel.self) private var model
    let feature: WhatsNewFeature

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            WhatsNewSymbol(name: feature.symbol, size: 26, tile: 54)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(feature.title).font(.title3.weight(.semibold))
                    WhatsNewFlagBadge(feature: feature)
                }
                Text(feature.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WhatsNewImage(name: feature.image)
                if !feature.tour.isEmpty {
                    Button {
                        WhatsNew.showMe(feature, model: model)
                    } label: {
                        Label("Show Me", systemImage: "hand.point.up.left")
                    }
                    .buttonStyle(TourPrimaryButtonStyle())
                    .accessibilityLabel("Show Me: \(feature.title)")
                    .accessibilityIdentifier("whats-new-show-me-\(feature.id)")
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whats-new-featured-\(feature.id)")
    }
}

private struct WhatsNewFeatureCard: View {
    @Environment(AppModel.self) private var model
    let feature: WhatsNewFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WhatsNewSymbol(name: feature.symbol, size: 16, tile: 32)
                Text(feature.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WhatsNewFlagBadge(feature: feature)
            Text(feature.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WhatsNewImage(name: feature.image)
            Spacer(minLength: 0)
            if !feature.tour.isEmpty {
                Button("Show Me") { WhatsNew.showMe(feature, model: model) }
                    .accessibilityLabel("Show Me: \(feature.title)")
                    .accessibilityIdentifier("whats-new-show-me-\(feature.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whats-new-feature-\(feature.id)")
    }
}

private struct WhatsNewSymbol: View {
    let name: String?
    let size: CGFloat
    let tile: CGFloat

    var body: some View {
        Image(systemName: name ?? "sparkles")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: tile, height: tile)
            .background(RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// A feature behind a feature flag says so, and whether it is on.
private struct WhatsNewFlagBadge: View {
    @Environment(AppModel.self) private var model
    let feature: WhatsNewFeature

    var body: some View {
        if let flag = feature.flag.flatMap(FeatureFlag.named) {
            let on = model.isEnabled(flag)
            Text(on ? "Feature flag · On" : "Feature flag")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .foregroundStyle(Color.orange)
                .help(on ? "\(flag.title) is on in Settings ▸ Advanced." : "Turn on \(flag.title) in Settings ▸ Advanced (⌥⌘,).")
        }
    }
}

/// A feature's optional picture, from the asset catalog.
private struct WhatsNewImage: View {
    let name: String?

    var body: some View {
        if let name, let image = NSImage(named: name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Settings

/// Settings ▸ General ▸ Tips: whether What's New and the first-launch tour appear by themselves.
struct TipsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Tips") {
            Toggle(isOn: $model.settings.showWhatsNewAfterUpdates) {
                Text("Show What's New after updates")
                Text("The first time a newer version or build starts, a window shows what changed, with Show Me tours. It waits while a run is going on. Help ▸ What's New opens it any time.")
            }
            .accessibilityIdentifier("settings-show-whats-new")
            Toggle(isOn: $model.settings.showTipsOnFirstLaunch) {
                Text("Show tips on first launch")
                Text("A short guided tour of the main window the very first time Runlet starts. Help ▸ Show Tour replays it.")
            }
            .accessibilityIdentifier("settings-show-tips")
            HStack {
                Button("What's New…") { model.perform("help.whatsNew") }
                    .accessibilityIdentifier("settings-whats-new")
                Button("Show Tour") { model.perform("help.showTour") }
                    .accessibilityIdentifier("settings-show-tour")
            }
        }
    }
}
