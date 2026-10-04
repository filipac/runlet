import AppKit
import RunletCore
import SwiftUI

// Coach marks (#232): the guided tour and What's New's Show Me tours. A step is a card in a
// child panel of the window, pointing at a view marked with `.tourAnchor(_:)`, with a ring around
// it; or a card centred on the window, with a small illustration, when the step has no anchor (a
// menu command) or its view isn't on screen. Tours never run code, connect, change data, or open
// a project: a step may only open harmless UI first (`TourPreparation`).

// MARK: - Anchors

extension View {
    /// Marks this view as a tour anchor: coach marks point at it. The id must be in
    /// `TourAnchor`; the manifest's tests check every step names one that a view uses.
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        background(TourAnchorMarker(anchor: anchor))
    }
}

private struct TourAnchorMarker: NSViewRepresentable {
    let anchor: TourAnchor

    func makeNSView(context: Context) -> TourAnchorView { TourAnchorView(anchor: anchor) }

    func updateNSView(_ view: TourAnchorView, context: Context) { view.anchor = anchor }
}

/// An invisible view behind an anchored element: it reports where the element is, and takes no
/// clicks and no accessibility focus.
final class TourAnchorView: NSView {
    var anchor: TourAnchor

    init(anchor: TourAnchor) {
        self.anchor = anchor
        super.init(frame: .zero)
        TourAnchors.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    /// On screen: in a visible window, not hidden, and not scrolled or clipped away.
    var isOnScreen: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return false }
        let visible = visibleRect
        return visible.width >= 4 && visible.height >= 4
    }

    /// The visible part, in screen coordinates. (In the toolbar, `visibleRect` can be larger than
    /// the view: it is kept within the view's bounds and the window.)
    var screenFrame: NSRect? {
        guard isOnScreen, let window else { return nil }
        let inWindow = convert(bounds.intersection(visibleRect), to: nil)
            .intersection(NSRect(origin: .zero, size: window.frame.size))
        guard inWindow.width >= 4, inWindow.height >= 4 else { return nil }
        return window.convertToScreen(inWindow)
    }
}

@MainActor
enum TourAnchors {
    private static let views = NSHashTable<TourAnchorView>.weakObjects()

    static func register(_ view: TourAnchorView) { views.add(view) }

    /// The on-screen view marked `anchor`; in `window` when given, else preferring the key or
    /// main window.
    static func view(_ anchor: TourAnchor, in window: NSWindow? = nil) -> TourAnchorView? {
        let candidates = views.allObjects.filter { $0.anchor == anchor && $0.isOnScreen }
        if let window { return candidates.first { $0.window === window } }
        return candidates.first { $0.window?.isMainWindow == true } ?? candidates.first { $0.window?.isKeyWindow == true } ?? candidates.first
    }

    /// Every anchor on screen now (debug state).
    static var onScreen: [TourAnchor] {
        Array(Set(views.allObjects.filter(\.isOnScreen).map(\.anchor))).sorted { $0.rawValue < $1.rawValue }
    }

    /// Where each anchor on screen is, relative to its window (debug state).
    static var frames: String {
        views.allObjects.filter(\.isOnScreen).sorted { $0.anchor.rawValue < $1.anchor.rawValue }.map { view in
            var chain: [String] = []
            var current: NSView? = view.superview
            while let next = current, chain.count < 4 { chain.append(String(describing: type(of: next))); current = next.superview }
            return "\(view.anchor.rawValue)=\(NSStringFromRect(view.convert(view.bounds, to: nil))) in \(chain.joined(separator: "<"))"
        }.joined(separator: "; ")
    }
}

// MARK: - Tour

/// The running tour: one at a time, over one window.
@MainActor
final class TourController {
    static let shared = TourController()

    enum Kind: Equatable {
        /// The first-launch tour, or Help ▸ Show Tour.
        case guided
        /// Show Me for a What's New feature (its title).
        case feature(String)
    }

    enum Ending { case finished, skipped, interrupted }

    struct Session {
        var steps: [TourStep]
        var index: Int
        var kind: Kind
        var onEnd: (Ending) -> Void
    }

    /// Where the current card is.
    enum Placement: Equatable {
        case pointing(TourAnchor, edge: TourAnchor.Placement)
        case centred
    }

    private(set) var session: Session?
    private(set) var placement: Placement?
    private weak var model: AppModel?
    private weak var host: NSWindow?
    private var bubble: CoachMarkPanel?
    private var ring: CoachMarkRingPanel?
    private let card = CoachMarkState()
    private var timer: Timer?
    private var lastAnchorFrame: NSRect?
    /// What the tour opened, to put back when it ends.
    private var inspectorBefore: (visible: Bool, pane: AppModel.InspectorPane)?

    var isRunning: Bool { session != nil }

    /// Starts `steps` over the active main window (ending a tour already running).
    func start(_ steps: [TourStep], kind: Kind, model: AppModel, onEnd: @escaping (Ending) -> Void = { _ in }) {
        if session != nil { end(.interrupted) }
        guard !steps.isEmpty, let window = Self.mainWindow(model) else { return onEnd(.interrupted) }
        self.model = model
        host = window
        inspectorBefore = nil
        // From Settings or What's New: the main window comes forward (without activating a
        // Runlet in the background, as screenshot runs keep it).
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        session = Session(steps: steps, index: 0, kind: kind, onEnd: onEnd)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { TourController.shared.follow() }
        }
        show()
    }

    func next() {
        guard var session else { return }
        guard session.index + 1 < session.steps.count else { return end(.finished) }
        session.index += 1
        self.session = session
        show()
    }

    func back() {
        guard var session, session.index > 0 else { return }
        session.index -= 1
        self.session = session
        show()
    }

    /// Goes to step `index` (0-based).
    func go(to index: Int) {
        guard var session, session.steps.indices.contains(index) else { return }
        session.index = index
        self.session = session
        show()
    }

    func skip() { end(.skipped) }

    func end(_ ending: Ending) {
        guard let session else { return }
        self.session = nil
        timer?.invalidate()
        timer = nil
        let wasKey = bubble?.isKeyWindow == true
        for panel in [bubble as NSWindow?, ring] {
            guard let panel else { continue }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        bubble = nil
        ring = nil
        placement = nil
        lastAnchorFrame = nil
        // The panel the tour opened closes again; one that was open stays.
        if let before = inspectorBefore, let model {
            model.inspectorPane = before.pane
            model.setInspectorVisible(before.visible)
        }
        inspectorBefore = nil
        if wasKey, let host, host.isVisible { host.makeKeyAndOrderFront(nil) }
        session.onEnd(ending)
    }

    // MARK: Showing a step

    private func show() {
        guard let session, let model else { return }
        let step = session.steps[session.index]
        var waits = false
        if let preparation = step.preparation { waits = prepare(preparation, model: model) }
        card.update(step: step, index: session.index, count: session.steps.count, kind: session.kind, model: model)
        // A panel that just opened needs a moment to lay out before it can be pointed at.
        if waits {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.present(announce: true) }
        } else {
            present(announce: true)
        }
    }

    /// Opens harmless UI for a step; true when something changed.
    private func prepare(_ preparation: TourPreparation, model: AppModel) -> Bool {
        func inspector(_ pane: AppModel.InspectorPane) -> Bool {
            if inspectorBefore == nil { inspectorBefore = (model.showInspector, model.inspectorPane) }
            let changed = !model.showInspector || model.inspectorPane != pane
            model.inspectorPane = pane
            model.setInspectorVisible(true)
            return changed
        }
        switch preparation {
        case .inspectorHistory: return inspector(.history)
        case .inspectorSnippets: return inspector(.snippets)
        case .inspectorDatabase: return inspector(.database)
        case .outputPane:
            guard let tab = model.selectedTab, !model.isOutputPaneShown(for: tab) else { return false }
            model.updateOutputPane(.show, for: tab)
            return true
        }
    }

    /// Places the card (and ring) for the current step, pointing at its anchor when it's on
    /// screen, else centred.
    private func present(announce: Bool) {
        guard let session, let model else { return }
        guard let host = (host?.isVisible == true ? host : nil) ?? Self.mainWindow(model) else { return end(.interrupted) }
        self.host = host
        let step = session.steps[session.index]
        let anchorView = step.tourAnchor.flatMap { TourAnchors.view($0, in: host) ?? TourAnchors.view($0) }
        let anchorFrame = anchorView?.screenFrame
        lastAnchorFrame = anchorFrame
        card.isCentred = anchorFrame == nil
        card.anchorMissing = step.tourAnchor != nil && anchorFrame == nil

        let bubble = self.bubble ?? makeBubble()
        self.bubble = bubble
        let parent = anchorView?.window ?? host
        bubble.appearance = parent.effectiveAppearance
        // Measure the card without an arrow (a view of its own reads the state as it is now);
        // the arrow adds its length on one side.
        card.arrowEdge = nil
        let measure = NSHostingView(rootView: CoachMarkCard(state: card, actions: CoachMarkActions(next: {}, back: {}, skip: {})))
        measure.appearance = parent.effectiveAppearance
        let base = measure.fittingSize

        var frame: NSRect
        var ringAttached = false
        if let anchorFrame, let anchor = step.tourAnchor {
            let layout = CoachMarkLayout(anchor: anchorFrame, card: base, window: parent.frame, screen: parent.screen?.visibleFrame ?? parent.frame)
            let result = layout.place(preferring: anchor.placement)
            frame = result.frame
            card.arrowEdge = result.arrowEdge
            card.arrowOffset = result.arrowOffset
            placement = .pointing(anchor, edge: result.placement)
            ringAttached = showRing(around: result.placement == .inside ? anchorFrame.insetBy(dx: 2, dy: 2) : anchorFrame.insetBy(dx: -4, dy: -4), parent: parent)
        } else {
            frame = CoachMarkLayout.centred(card: base, in: host.frame)
            placement = .centred
            hideRing()
        }
        frame = frame.integral
        if bubble.parent !== parent || ringAttached {
            // The card stays above its ring.
            bubble.parent?.removeChildWindow(bubble)
            parent.addChildWindow(bubble, ordered: .above)
        }
        bubble.setFrame(frame, display: true)
        // Keyboard focus only when nobody is typing, so Return and Esc work without taking
        // keystrokes from the editor; VoiceOver hears the step either way.
        if NSApp.isActive, !TypingMonitor.typedRecently, !bubble.isKeyWindow {
            bubble.makeKeyAndOrderFront(nil)
        } else {
            bubble.orderFront(nil)
        }
        if announce { announceStep(step, session: session) }
    }

    private func makeBubble() -> CoachMarkPanel {
        let panel = CoachMarkPanel(content: CoachMarkCard(state: card, actions: CoachMarkActions(
            next: { TourController.shared.next() },
            back: { TourController.shared.back() },
            skip: { TourController.shared.skip() }
        )))
        panel.onCancel = { TourController.shared.skip() }
        return panel
    }

    /// Shows the ring; true when it was just put on `parent`.
    private func showRing(around rect: NSRect, parent: NSWindow) -> Bool {
        let ring = self.ring ?? CoachMarkRingPanel()
        self.ring = ring
        ring.appearance = parent.effectiveAppearance
        var attached = false
        if ring.parent !== parent {
            ring.parent?.removeChildWindow(ring)
            parent.addChildWindow(ring, ordered: .above)
            attached = true
        }
        ring.setFrame(rect.insetBy(dx: -CoachMarkRingPanel.glow, dy: -CoachMarkRingPanel.glow).integral, display: true)
        return attached
    }

    private func hideRing() {
        guard let ring else { return }
        ring.parent?.removeChildWindow(ring)
        ring.orderOut(nil)
    }

    /// Follows the anchor while the window changes (a resize, a panel opening, another tab).
    private func follow() {
        guard let session, let model else { return }
        guard let host, host.isVisible else {
            // The window went away: a Show Me tour ends, a guided one moves to another window.
            if Self.mainWindow(model) == nil { end(.interrupted) } else { present(announce: false) }
            return
        }
        let step = session.steps[session.index]
        let frame = step.tourAnchor.flatMap { TourAnchors.view($0, in: host) ?? TourAnchors.view($0) }?.screenFrame
        if frame != lastAnchorFrame { present(announce: false) }
    }

    private func announceStep(_ step: TourStep, session: Session) {
        let text = "\(card.kindTitle), step \(session.index + 1) of \(session.steps.count). \(step.title). \(step.text)"
        let element: Any = bubble ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The window a tour shows over: the active main window when it's on screen.
    static func mainWindow(_ model: AppModel) -> NSWindow? {
        if let window = model.activeWindow?.nsWindow, window.isVisible { return window }
        return model.windows.compactMap(\.nsWindow).first { $0.isVisible }
    }

    // MARK: Debug state

    var debugDescription: String {
        guard let session else { return "no tour" }
        let step = session.steps[session.index]
        let where_: String = switch placement {
        case .pointing(let anchor, let edge): "pointing at \(anchor.rawValue) (\(edge))"
        case .centred: "centred" + (step.tourAnchor.map { " (\($0.rawValue) not on screen)" } ?? "")
        case nil: "not placed"
        }
        return "tour \(card.kindTitle) step \(session.index + 1)/\(session.steps.count) \"\(step.title)\" \(where_) key=\(bubble?.isKeyWindow == true) frame=\(bubble.map { NSStringFromRect($0.frame) } ?? "-") ring=\(ring.map { "\(NSStringFromRect($0.frame)) visible=\($0.isVisible)" } ?? "-") anchor=\(lastAnchorFrame.map(NSStringFromRect) ?? "-") window=\(host.map { NSStringFromRect($0.frame) } ?? "-")"
    }
}

// MARK: - Layout

/// Where a card goes beside its anchor, in screen coordinates (y up).
struct CoachMarkLayout {
    /// Room around the card for its shadow (the panel is larger than the card).
    static let margin: CGFloat = 20
    static let arrowLength: CGFloat = 9
    /// Between the arrow's tip and the element.
    static let gap: CGFloat = 3

    var anchor: NSRect
    /// The card's panel size without an arrow (margins included).
    var card: CGSize
    var window: NSRect
    var screen: NSRect

    struct Result {
        var frame: NSRect
        var placement: TourAnchor.Placement
        /// The card's side the arrow is on; nil inside the element.
        var arrowEdge: Edge?
        /// From the card's leading edge (top and bottom arrows) or top edge (side arrows).
        var arrowOffset: CGFloat
    }

    func place(preferring preferred: TourAnchor.Placement) -> Result {
        if preferred == .inside { return inside() }
        let order = [preferred] + [TourAnchor.Placement.below, .above, .leading].filter { $0 != preferred }
        for bounds in [window.insetBy(dx: 4, dy: 4), screen] {
            for placement in order {
                let result = place(placement)
                if bounds.contains(body(of: result)) { return result }
            }
        }
        return inside()
    }

    /// The card itself, without its margins.
    private func body(of result: Result) -> NSRect {
        result.frame.insetBy(dx: Self.margin, dy: Self.margin)
    }

    private func place(_ placement: TourAnchor.Placement) -> Result {
        let m = Self.margin, a = Self.arrowLength, g = Self.gap
        let bodyWidth = card.width - 2 * m, bodyHeight = card.height - 2 * m
        let bounds = window.insetBy(dx: 6, dy: 6)
        switch placement {
        case .below, .above:
            let tipX = anchor.midX
            let left = min(max(tipX - bodyWidth / 2, bounds.minX), bounds.maxX - bodyWidth)
            let offset = min(max(tipX - left, 18), bodyWidth - 18)
            let height = card.height + a
            let y = placement == .below ? anchor.minY - g - (height - m) : anchor.maxY + g - m
            return Result(frame: NSRect(x: left - m, y: y, width: card.width, height: height), placement: placement,
                          arrowEdge: placement == .below ? .top : .bottom, arrowOffset: offset)
        case .leading:
            let tipY = anchor.midY
            let bottom = min(max(tipY - bodyHeight / 2, bounds.minY), bounds.maxY - bodyHeight)
            let offset = min(max((bottom + bodyHeight) - tipY, 18), bodyHeight - 18)
            let width = card.width + a
            return Result(frame: NSRect(x: anchor.minX - g - (width - m), y: bottom - m, width: width, height: card.height),
                          placement: .leading, arrowEdge: .trailing, arrowOffset: offset)
        case .inside:
            return inside()
        }
    }

    /// Inside a large element (the editor, the output), near its bottom, with no arrow.
    private func inside() -> Result {
        let m = Self.margin
        let bodyWidth = card.width - 2 * m
        let x = anchor.midX - bodyWidth / 2 - m
        let y = max(anchor.minY + 24, window.minY + 30) - m
        return Result(frame: NSRect(x: x, y: y, width: card.width, height: card.height), placement: .inside, arrowEdge: nil, arrowOffset: 0)
    }

    /// Centred on the window, a little above the middle.
    static func centred(card: CGSize, in window: NSRect) -> NSRect {
        NSRect(x: window.midX - card.width / 2, y: window.midY - card.height / 2 + window.height * 0.08, width: card.width, height: card.height)
    }
}

// MARK: - Panels

/// A coach mark's window: borderless and transparent, drawing its own card and shadow. `shot`
/// (DebugSteps) draws these as they are, without the backing it gives other overlays.
class CoachMarkWindow: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeMain: Bool { false }
}

/// The card: takes keyboard focus for Return and Esc when nobody is typing.
final class CoachMarkPanel: CoachMarkWindow {
    let hosting: NSHostingView<AnyView>
    var onCancel: (() -> Void)?

    init<Content: View>(content: Content) {
        hosting = NSHostingView(rootView: AnyView(content))
        super.init(size: NSSize(width: 360, height: 200))
        title = "Tour"
        hosting.sizingOptions = []
        contentView = hosting
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Tour")
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The ring around the element a step points at. Clicks pass through to it.
final class CoachMarkRingPanel: CoachMarkWindow {
    static let glow: CGFloat = 6

    init() {
        super.init(size: NSSize(width: 40, height: 40))
        title = "Tour Highlight"
        ignoresMouseEvents = true
        let view = NSHostingView(rootView: CoachMarkRing())
        view.sizingOptions = []
        contentView = view
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
}

private struct CoachMarkRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .shadow(color: Color.accentColor.opacity(0.55), radius: 5)
            .padding(CoachMarkRingPanel.glow)
            .accessibilityHidden(true)
    }
}

// MARK: - The card

@MainActor
@Observable
final class CoachMarkState {
    var step = TourStep(title: "", text: "")
    var index = 0
    var count = 1
    var kindTitle = "Tour"
    var isGuided = true
    var isCentred = false
    /// The step names an element that isn't on screen now.
    var anchorMissing = false
    var arrowEdge: Edge?
    var arrowOffset: CGFloat = 0
    /// The shortcut of the step's command, as the user mapped it.
    var shortcut: String?

    func update(step: TourStep, index: Int, count: Int, kind: TourController.Kind, model: AppModel) {
        self.step = step
        self.index = index
        self.count = count
        switch kind {
        case .guided:
            kindTitle = "Tour"
            isGuided = true
        case .feature(let title):
            kindTitle = "Show Me · \(title)"
            isGuided = false
        }
        shortcut = step.command.flatMap { model.shortcut(for: $0)?.displayString } ?? step.keys
    }
}

struct CoachMarkActions {
    var next: () -> Void
    var back: () -> Void
    var skip: () -> Void
}

/// The coach mark's card: what the step is about, where (for a centred one), and Back / Next / Skip.
struct CoachMarkCard: View {
    let state: CoachMarkState
    let actions: CoachMarkActions

    var body: some View {
        let edge = state.arrowEdge
        let arrow = CoachMarkLayout.arrowLength
        content
            .frame(width: state.isCentred ? 340 : 300, alignment: .leading)
            .padding(16)
            .padding(.top, edge == .top ? arrow : 0)
            .padding(.bottom, edge == .bottom ? arrow : 0)
            .padding(.leading, edge == .leading ? arrow : 0)
            .padding(.trailing, edge == .trailing ? arrow : 0)
            .background {
                CoachBubbleShape(edge: edge, offset: state.arrowOffset, arrow: arrow)
                    .fill(Color.coachMarkBackground)
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            }
            .overlay {
                CoachBubbleShape(edge: edge, offset: state.arrowOffset, arrow: arrow)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
            .padding(CoachMarkLayout.margin)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(state.kindTitle), step \(state.index + 1) of \(state.count): \(state.step.title)")
            .accessibilityIdentifier("coach-mark")
    }

    private var isLast: Bool { state.index + 1 >= state.count }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.kindTitle.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.count > 1 {
                    Text("\(state.index + 1) of \(state.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("coach-mark-progress")
                }
            }
            if state.isCentred { CoachMarkIllustration(step: state.step, shortcut: state.shortcut) }
            Text(state.step.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(state.step.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.anchorMissing, let anchor = state.step.tourAnchor {
                Label(anchor.whereToFind, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.isCentred, state.step.menu != nil || state.shortcut != nil {
                CoachMarkShortcutRow(menu: state.step.menu, shortcut: state.shortcut)
            }
            HStack(spacing: 8) {
                if state.count > 1 { CoachMarkDots(count: state.count, index: state.index) }
                Spacer(minLength: 8)
                Button(state.isGuided ? "Skip Tour" : "Close") { actions.skip() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("coach-mark-skip")
                if state.index > 0 {
                    Button("Back") { actions.back() }
                        .accessibilityIdentifier("coach-mark-back")
                }
                Button(isLast ? "Done" : "Next") { actions.next() }
                    .buttonStyle(TourPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("coach-mark-next")
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
    }
}

/// A centred step's picture: its symbol, the menu path, and the shortcut.
private struct CoachMarkIllustration: View {
    let step: TourStep
    let shortcut: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: step.illustrationSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.13)))
            if step.menu != nil || shortcut != nil {
                CoachMarkMenuPicture(menu: step.menu, shortcut: shortcut)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([step.menu, shortcut.map { "shortcut \($0)" }].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A tiny menu: the menu's name over its highlighted item and shortcut.
private struct CoachMarkMenuPicture: View {
    let menu: String?
    let shortcut: String?

    var body: some View {
        let parts = (menu ?? "").components(separatedBy: " ▸ ")
        VStack(alignment: .leading, spacing: 3) {
            if parts.count > 1 {
                Text(parts.dropLast().joined(separator: " ▸ "))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let item = parts.last, !item.isEmpty {
                    Text(item).font(.caption).lineLimit(1)
                }
                if let shortcut { Text(shortcut).font(.caption.monospaced()).opacity(0.85) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
    }
}

/// The menu path and keys, for a step that points at an element.
private struct CoachMarkShortcutRow: View {
    let menu: String?
    let shortcut: String?

    var body: some View {
        HStack(spacing: 6) {
            if let menu {
                Text(menu).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Next and Done: the accent color even while the card's window isn't key, so the way on is
/// always clear.
struct TourPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

private struct CoachMarkDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A rounded card with an arrow on one side.
nonisolated private struct CoachBubbleShape: InsettableShape {
    var edge: Edge?
    var offset: CGFloat
    var arrow: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> CoachBubbleShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    func path(in full: CGRect) -> Path {
        let rect = full.insetBy(dx: inset, dy: inset)
        var body = rect
        switch edge {
        case .top: body.origin.y += arrow; body.size.height -= arrow
        case .bottom: body.size.height -= arrow
        case .leading: body.origin.x += arrow; body.size.width -= arrow
        case .trailing: body.size.width -= arrow
        case nil: break
        }
        var path = Path(roundedRect: body, cornerRadius: 12, style: .continuous)
        let half: CGFloat = 9
        var triangle = Path()
        switch edge {
        case .top:
            let x = body.minX + offset
            triangle.move(to: CGPoint(x: x - half, y: body.minY + 1))
            triangle.addLine(to: CGPoint(x: x, y: rect.minY))
            triangle.addLine(to: CGPoint(x: x + half, y: body.minY + 1))
        case .bottom:
            let x = body.minX + offset
            triangle.move(to: CGPoint(x: x - half, y: body.maxY - 1))
            triangle.addLine(to: CGPoint(x: x, y: rect.maxY))
            triangle.addLine(to: CGPoint(x: x + half, y: body.maxY - 1))
        case .leading:
            let y = body.minY + offset
            triangle.move(to: CGPoint(x: body.minX + 1, y: y - half))
            triangle.addLine(to: CGPoint(x: rect.minX, y: y))
            triangle.addLine(to: CGPoint(x: body.minX + 1, y: y + half))
        case .trailing:
            let y = body.minY + offset
            triangle.move(to: CGPoint(x: body.maxX - 1, y: y - half))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: y))
            triangle.addLine(to: CGPoint(x: body.maxX - 1, y: y + half))
        case nil:
            return path
        }
        triangle.closeSubpath()
        path.addPath(triangle)
        return path
    }
}

extension Color {
    /// The coach mark's card: white in light mode, a raised gray in dark mode.
    static let coachMarkBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
}

// MARK: - Typing

/// When a key was last typed in Runlet (outside the coach marks and What's New), so they never
/// take keystrokes from someone typing.
@MainActor
enum TypingMonitor {
    private static var monitor: Any?
    private(set) static var lastKeyDown = Date.distantPast

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if !(event.window is CoachMarkWindow), !(event.window is WhatsNewNSWindow) { lastKeyDown = Date() }
            }
            return event
        }
    }

    static var typedRecently: Bool { Date().timeIntervalSince(lastKeyDown) < 2 }
}
