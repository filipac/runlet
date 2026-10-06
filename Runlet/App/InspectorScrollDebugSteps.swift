#if DEBUG
import AppKit
import ObjectiveC

/// RUNLET_DEBUG_STEPS for the inspector panes' scroll stability (#320). They measure the list
/// of the visible pane (History, Snippets, Commands, Database): the scroll view in the
/// inspector column, the trailing column of the main window, with the tallest visible area.
/// They need no key window, so Runlet can stay in the background (`ghost`):
///
/// - `inspector-scroll:top|middle|bottom|<points>` scrolls that list.
/// - `inspector-scroll-watch` starts recording, from now on, every change of the list's scroll
///   offset and document height (as they happen, not only at the steps), whether its scroll view
///   or document view was replaced, and how often its table reloaded rows or re-measured their
///   heights.
/// - `inspector-scroll-state[:<label>]` prints the list now, and what changed since the last
///   `inspector-scroll-state` (or the watch's start): `inspector-scroll-state <label>: pane=
///   y= height= visible= rows= scrollViewSame= documentSame= offsetChanges= heightChanges=
///   yRange= heightRange= reloads= heightNotes= rowReloads= flashes=`.
/// - `inspector-wait[:<seconds>]` (in `runDebugInspectorCheck`) holds the steps until the list is
///   taller than its visible area (a long list has loaded; at most 30 s by default).
/// - `inspector-click:row|row-text|above:<points>` clicks, with mouse events, the middle of the
///   list's visible area, a point just inside a row's leading edge (on its text), or that many
///   points above the list (the pane's header).
@MainActor
enum InspectorScrollDebugSteps {
    static var waited = 0.0
    /// Body evaluations of the inspector's panes and rows since the last report (`inspectorRenderTick`).
    static var renders: [String: Int] = [:]

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "inspector-scroll":
            guard let scrollView = paneScrollView(model), let document = scrollView.documentView else {
                log("inspector-scroll: no list")
                return true
            }
            let clip = scrollView.contentView
            let bottom = max(0, document.frame.height - clip.bounds.height)
            let y: CGFloat
            switch argument {
            case "top": y = 0
            case "bottom": y = bottom
            case "middle", "": y = (bottom / 2).rounded()
            case "selected-top", "selected-bottom":
                // The selected row half hidden under the top or bottom edge of the visible area.
                guard let table = document as? NSTableView, table.selectedRow >= 0, document.isFlipped else {
                    log("inspector-scroll \(argument): no selected row")
                    return true
                }
                let row = table.rect(ofRow: table.selectedRow)
                y = argument == "selected-top" ? (row.midY).rounded() : (row.midY - clip.bounds.height).rounded()
            default: y = min(bottom, max(0, CGFloat(Double(argument) ?? 0)))
            }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? y : bottom - y))
            scrollView.reflectScrolledClipView(clip)
            log("inspector-scroll \(argument): " + describe(scrollView, model: model))
        case "inspector-scroll-watch":
            Watch.shared.start(paneScrollView(model))
            log("inspector-scroll-watch: " + (Watch.shared.scrollView.map { describe($0, model: model) } ?? "no list"))
        case "inspector-scroll-state":
            let label = argument.isEmpty ? "" : " \(argument)"
            guard let scrollView = paneScrollView(model) else {
                log("inspector-scroll-state\(label): no list")
                return true
            }
            log("inspector-scroll-state\(label): " + describe(scrollView, model: model) + " " + Watch.shared.report(scrollView))
        case "inspector-scroll-sweep":
            sweep(model)
        case "inspector-row-height":
            if let table = paneScrollView(model)?.documentView as? NSTableView {
                if let height = Double(argument) { table.rowHeight = height }
                let before = table.frame.height
                if argument == "note" { table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<table.numberOfRows)) }
                log("inspector-row-height \(argument): rowHeight=\(table.rowHeight) height=\(before)>\(table.frame.height)")
            }
        case "inspector-click":
            click(argument, model: model)
        default:
            return false
        }
        return true
    }

    /// Whether the visible pane's list is taller than its visible area (`inspector-wait`).
    static func listIsLong(_ model: AppModel) -> Bool {
        guard let scrollView = paneScrollView(model), let document = scrollView.documentView else { return false }
        return document.frame.height > scrollView.contentView.bounds.height + 40
    }

    // MARK: Finding the list

    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil && !($0 is NSPanel) }
        return candidates.first { $0.isMainWindow } ?? candidates.first
    }

    /// The scroll view of the visible pane's list: in the inspector column (the main window's
    /// trailing `libraryPanelWidth` points), not a text view's, with the largest visible area.
    static func paneScrollView(_ model: AppModel) -> NSScrollView? {
        guard model.showInspector, let window = mainWindow(), let content = window.contentView else { return nil }
        let width = min(480, max(260, model.settings.libraryPanelWidth))
        let columnMinX = content.bounds.maxX - width - 2
        var found: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scrollView = view as? NSScrollView, !(scrollView.documentView is NSTextView), !scrollView.isHiddenOrHasHiddenAncestor {
                let frame = scrollView.convert(scrollView.bounds, to: nil)
                if frame.minX >= columnMinX, frame.height > 60 { found.append(scrollView) }
            }
            view.subviews.forEach(collect)
        }
        collect(content.superview ?? content)
        return found.max { $0.contentView.bounds.height * $0.contentView.bounds.width < $1.contentView.bounds.height * $1.contentView.bounds.width }
    }

    /// `y=` from the top of the document, whatever its flippedness.
    static func offset(_ scrollView: NSScrollView) -> CGFloat {
        guard let document = scrollView.documentView else { return 0 }
        let visible = scrollView.documentVisibleRect
        return document.isFlipped ? visible.minY : document.bounds.height - visible.maxY
    }

    private static func describe(_ scrollView: NSScrollView, model: AppModel) -> String {
        let document = scrollView.documentView
        let table = document as? NSTableView
        let rows = table.map { "\($0.numberOfRows)" } ?? "-"
        let selected = table.map { $0.selectedRowIndexes.isEmpty ? "none" : $0.selectedRowIndexes.map(String.init).joined(separator: "+") } ?? "-"
        return "pane=\(model.inspectorPane) y=\(format(offset(scrollView))) height=\(format(document?.frame.height ?? 0)) visible=\(format(scrollView.contentView.bounds.height)) rows=\(rows) selected=\(selected) responder=\(scrollView.window?.firstResponder.map { String(describing: type(of: $0)).prefix(40) } ?? "none") view=\(type(of: scrollView))/\(document.map { "\(type(of: $0))" } ?? "nil")"
    }

    /// `inspector-scroll-sweep`: scrolls the list from top to bottom and back, a visible height at a
    /// time, laying it out after each step, and prints how its document height changed: a list
    /// that estimates the heights of rows it hasn't shown yet grows or shrinks as it goes.
    private static func sweep(_ model: AppModel) {
        guard let scrollView = paneScrollView(model), let document = scrollView.documentView, document.isFlipped else {
            return log("inspector-scroll-sweep: no list")
        }
        let clip = scrollView.contentView
        let start = clip.bounds.origin
        var heights: [CGFloat] = [document.frame.height]
        func go(_ y: CGFloat) {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(y, document.frame.height - clip.bounds.height))))
            scrollView.reflectScrolledClipView(clip)
            scrollView.window?.contentView?.layoutSubtreeIfNeeded()
            scrollView.window?.displayIfNeeded()
            if heights.last != document.frame.height { heights.append(document.frame.height) }
        }
        var y: CGFloat = 0
        go(0)
        while y < document.frame.height - clip.bounds.height {
            y += clip.bounds.height / 2
            go(y)
        }
        while y > 0 {
            y -= clip.bounds.height / 2
            go(y)
        }
        go(start.y)
        if let table = document as? NSTableView {
            let delegate = table.delegate.map { "\(type(of: $0))" } ?? "nil"
            let responds = ["outlineView:heightOfRowByItem:", "tableView:heightOfRow:", "outlineView:sizeToFitWidthOfColumn:"].filter { table.delegate?.responds(to: NSSelectorFromString($0)) == true }
            var delegateMethods: [String] = []
            if let delegateObject = table.delegate, let type = object_getClass(delegateObject) {
                var count: UInt32 = 0
                if let list = class_copyMethodList(type, &count) {
                    for index in 0..<Int(count) { delegateMethods.append(NSStringFromSelector(method_getName(list[index]))) }
                    free(list)
                }
            }
            log("inspector-scroll-sweep table: rowHeight=\(table.rowHeight) automatic=\(table.usesAutomaticRowHeights) style=\(table.style.rawValue) delegate=\(delegate) responds=\(responds) methods=\(delegateMethods.filter { $0.localizedCaseInsensitiveContains("height") || $0.localizedCaseInsensitiveContains("estimat") })")
        }
        log("inspector-scroll-sweep: heights=\(heights.map(format).joined(separator: ">")) " + describe(scrollView, model: model))
    }

    // MARK: Clicking

    private static func click(_ argument: String, model: AppModel) {
        guard let window = mainWindow(), let scrollView = paneScrollView(model) else {
            return log("inspector-click: no list")
        }
        let frame = scrollView.convert(scrollView.bounds, to: nil) // window coordinates (not flipped)
        let point: NSPoint
        switch argument {
        case "row", "":
            point = NSPoint(x: frame.midX, y: frame.midY)
        case "row-text":
            point = NSPoint(x: frame.minX + 40, y: frame.midY)
        default:
            let above = argument.hasPrefix("above:") ? CGFloat(Double(argument.dropFirst(6)) ?? 20) : 20
            point = NSPoint(x: frame.midX, y: frame.maxY + above)
        }
        let hit = window.contentView?.superview?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        log("inspector-click \(argument): at \(format(point.x)),\(format(point.y)) on \(hit.map { "\(type(of: $0))" } ?? "nothing")")
    }

    // MARK: Watching

    /// Records the watched list's offset and height changes as they happen.
    @MainActor
    final class Watch {
        static let shared = Watch()
        private(set) weak var scrollView: NSScrollView?
        private weak var document: NSView?
        private var observers: [NSObjectProtocol] = []
        private var lastY: CGFloat = 0
        private var lastHeight: CGFloat = 0
        private var offsetChanges = 0
        private var heightChanges = 0
        /// Changes of the scroll view's own size (its visible area).
        private var frameChanges = 0
        private var lastFrame: NSSize = .zero
        private var yRange: ClosedRange<CGFloat>?
        private var heightRange: ClosedRange<CGFloat>?
        /// The views the last report saw, to tell whether the pane was rebuilt since.
        private weak var reportedScrollView: NSScrollView?
        private weak var reportedDocument: NSView?
        fileprivate static var counts: [ObjectIdentifier: [String: Int]] = [:]

        func start(_ scrollView: NSScrollView?) {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            Self.installSwizzles()
            self.scrollView = scrollView
            document = scrollView?.documentView
            reportedScrollView = scrollView
            reportedDocument = document
            resetCounts()
            guard let scrollView, let document else { return }
            lastY = InspectorScrollDebugSteps.offset(scrollView)
            lastHeight = document.frame.height
            scrollView.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            })
            lastFrame = scrollView.frame.size
            scrollView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.scrollView else { return }
                    if scrollView.frame.size != self.lastFrame {
                        self.frameChanges += 1
                        self.lastFrame = scrollView.frame.size
                    }
                    self.sample()
                }
            })
            Self.describeClasses(scrollView)
        }

        private func sample() {
            guard let scrollView, let document else { return }
            let y = InspectorScrollDebugSteps.offset(scrollView)
            let height = document.frame.height
            if abs(y - lastY) > 0.25 {
                offsetChanges += 1
                lastY = y
            }
            if abs(height - lastHeight) > 0.25 {
                heightChanges += 1
                lastHeight = height
            }
            yRange = yRange.map { min($0.lowerBound, y)...max($0.upperBound, y) } ?? y...y
            heightRange = heightRange.map { min($0.lowerBound, height)...max($0.upperBound, height) } ?? height...height
        }

        private func resetCounts() {
            offsetChanges = 0
            heightChanges = 0
            frameChanges = 0
            InspectorScrollDebugSteps.renders = [:]
            yRange = nil
            heightRange = nil
            Self.counts = [:]
        }

        /// What changed since the last report, then starts over (watching `current` from now on
        /// when the pane's list was replaced).
        func report(_ current: NSScrollView) -> String {
            let sameScrollView = reportedScrollView === current
            let sameDocument = reportedDocument === current.documentView
            let watched = scrollView === current
            var appKit: [String: Int] = [:]
            for view in [current, current.documentView, current.verticalScroller].compactMap({ $0 as NSView? }) {
                appKit.merge(Self.counts[ObjectIdentifier(view)] ?? [:], uniquingKeysWith: +)
            }
            let appKitText = appKit.isEmpty ? "-" : appKit.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            let renders = InspectorScrollDebugSteps.renders
            let rendersText = renders.isEmpty ? "-" : renders.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            func range(_ range: ClosedRange<CGFloat>?) -> String {
                guard let range else { return "-" }
                return range.lowerBound == range.upperBound ? format(range.lowerBound) : "\(format(range.lowerBound))…\(format(range.upperBound))"
            }
            let text = "scrollViewSame=\(sameScrollView ? "yes" : "no") documentSame=\(sameDocument ? "yes" : "no") watched=\(watched ? "yes" : "no") offsetChanges=\(offsetChanges) heightChanges=\(heightChanges) yRange=\(range(yRange)) heightRange=\(range(heightRange)) frameChanges=\(frameChanges) appKit=\(appKitText) renders=\(rendersText)"
            if watched {
                reportedScrollView = current
                reportedDocument = current.documentView
                resetCounts()
                sample()
            } else {
                start(current)
            }
            return text
        }

        // MARK: Counting table updates

        private static var swizzled = false

        /// Counts, per view, `reloadData`, `noteHeightOfRows(withIndexesChanged:)`,
        /// `reloadData(forRowIndexes:columnIndexes:)`, and `flashScrollers()` (Debug builds,
        /// only once a watch starts).
        static func installSwizzles() {
            guard !swizzled else { return }
            swizzled = true
            exchange(NSTableView.self, NSSelectorFromString("reloadData"), #selector(NSTableView.runletDebugReloadAll))
            exchange(NSTableView.self, #selector(NSTableView.noteHeightOfRows(withIndexesChanged:)), #selector(NSTableView.runletDebugNoteHeightOfRows(withIndexesChanged:)))
            exchange(NSTableView.self, #selector(NSTableView.reloadData(forRowIndexes:columnIndexes:)), #selector(NSTableView.runletDebugReloadRows(forRowIndexes:columnIndexes:)))
            exchange(NSTableView.self, #selector(NSTableView.noteNumberOfRowsChanged), #selector(NSTableView.runletDebugNoteNumberOfRowsChanged))
            exchange(NSTableView.self, #selector(NSTableView.insertRows(at:withAnimation:)), #selector(NSTableView.runletDebugInsertRows(at:withAnimation:)))
            exchange(NSTableView.self, #selector(NSTableView.removeRows(at:withAnimation:)), #selector(NSTableView.runletDebugRemoveRows(at:withAnimation:)))
            exchange(NSOutlineView.self, #selector(NSOutlineView.reloadItem(_:reloadChildren:)), #selector(NSOutlineView.runletDebugReloadItem(_:reloadChildren:)))
            exchange(NSScrollView.self, #selector(NSScrollView.flashScrollers), #selector(NSScrollView.runletDebugFlashScrollers))
            exchange(NSScrollView.self, #selector(NSScrollView.tile), #selector(NSScrollView.runletDebugTile))
            exchange(NSScrollView.self, #selector(NSScrollView.reflectScrolledClipView(_:)), #selector(NSScrollView.runletDebugReflect(_:)))
            exchange(NSScroller.self, #selector(setter: NSScroller.knobProportion), #selector(NSScroller.runletDebugSetKnobProportion(_:)))
            exchange(NSScroller.self, #selector(setter: NSControl.doubleValue), #selector(NSScroller.runletDebugSetDoubleValue(_:)))
            exchange(NSScroller.self, #selector(setter: NSView.isHidden), #selector(NSScroller.runletDebugSetHidden(_:)))
        }

        /// Swaps two methods of `type`, adding the original to `type` first when it only
        /// inherits it, so other subclasses of its superclass keep theirs.
        private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let originalMethod = class_getInstanceMethod(type, original), let replacementMethod = class_getInstanceMethod(type, replacement) else { return }
            if class_addMethod(type, original, method_getImplementation(replacementMethod), method_getTypeEncoding(replacementMethod)) {
                class_replaceMethod(type, replacement, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
            } else {
                method_exchangeImplementations(originalMethod, replacementMethod)
            }
        }

        private static var described = Set<String>()

        /// Once per class: the methods SwiftUI's list classes implement themselves among those
        /// that move the scroller or re-measure rows.
        private static func describeClasses(_ scrollView: NSScrollView) {
            for view in [scrollView, scrollView.documentView, scrollView.verticalScroller].compactMap({ $0 as NSView? }) {
                var type: AnyClass? = object_getClass(view)
                while let current = type, ![NSScrollView.self, NSOutlineView.self, NSTableView.self, NSScroller.self, NSView.self].contains(where: { $0 == current }) {
                    let name = NSStringFromClass(current)
                    if described.insert(name).inserted {
                        var count: UInt32 = 0
                        var all: [String] = []
                        if let list = class_copyMethodList(current, &count) {
                            for index in 0..<Int(count) { all.append(NSStringFromSelector(method_getName(list[index]))) }
                            free(list)
                        }
                        let interesting = all.filter { $0.range(of: "flash|tile|reflect|reload|Height|scroll|Scroll|knob|Knob|estimat|Estimat", options: .regularExpression) != nil }.sorted()
                        InspectorScrollDebugSteps.log("class \(name): \(interesting.joined(separator: " "))")
                    }
                    type = class_getSuperclass(current)
                }
            }
        }

        nonisolated static func count(_ view: NSView, _ key: String) {
            MainActor.assumeIsolated {
                counts[ObjectIdentifier(view), default: [:]][key, default: 0] += 1
            }
        }
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}

extension NSTableView {
    @objc fileprivate func runletDebugReloadAll() {
        InspectorScrollDebugSteps.Watch.count(self, "reload")
        runletDebugReloadAll()
    }

    @objc fileprivate func runletDebugNoteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        InspectorScrollDebugSteps.Watch.count(self, "heights")
        runletDebugNoteHeightOfRows(withIndexesChanged: indexes)
    }

    @objc fileprivate func runletDebugReloadRows(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        InspectorScrollDebugSteps.Watch.count(self, "rows")
        runletDebugReloadRows(forRowIndexes: rows, columnIndexes: columns)
    }
}

extension NSTableView {
    @objc fileprivate func runletDebugNoteNumberOfRowsChanged() {
        InspectorScrollDebugSteps.Watch.count(self, "rowCount")
        runletDebugNoteNumberOfRowsChanged()
    }

    @objc fileprivate func runletDebugInsertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions) {
        InspectorScrollDebugSteps.Watch.count(self, "insert")
        runletDebugInsertRows(at: indexes, withAnimation: options)
    }

    @objc fileprivate func runletDebugRemoveRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions) {
        InspectorScrollDebugSteps.Watch.count(self, "remove")
        runletDebugRemoveRows(at: indexes, withAnimation: options)
    }
}

extension NSOutlineView {
    @objc fileprivate func runletDebugReloadItem(_ item: Any?, reloadChildren: Bool) {
        InspectorScrollDebugSteps.Watch.count(self, "reloadItem")
        runletDebugReloadItem(item, reloadChildren: reloadChildren)
    }
}

extension NSScrollView {
    @objc fileprivate func runletDebugFlashScrollers() {
        InspectorScrollDebugSteps.Watch.count(self, "flash")
        runletDebugFlashScrollers()
    }

    @objc fileprivate func runletDebugTile() {
        InspectorScrollDebugSteps.Watch.count(self, "tile")
        runletDebugTile()
    }

    @objc fileprivate func runletDebugReflect(_ clipView: NSClipView) {
        InspectorScrollDebugSteps.Watch.count(self, "reflect")
        runletDebugReflect(clipView)
    }
}

extension NSScroller {
    @objc fileprivate func runletDebugSetKnobProportion(_ value: CGFloat) {
        if abs(value - knobProportion) > 0.0001 { InspectorScrollDebugSteps.Watch.count(self, "knobSize") }
        runletDebugSetKnobProportion(value)
    }

    @objc fileprivate func runletDebugSetDoubleValue(_ value: Double) {
        if abs(value - doubleValue) > 0.0001 { InspectorScrollDebugSteps.Watch.count(self, "knobPosition") }
        runletDebugSetDoubleValue(value)
    }

    @objc fileprivate func runletDebugSetHidden(_ hidden: Bool) {
        if hidden != isHidden { InspectorScrollDebugSteps.Watch.count(self, hidden ? "scrollerHidden" : "scrollerShown") }
        runletDebugSetHidden(hidden)
    }
}
#endif

/// Counts a body evaluation of an inspector pane or row, which `inspector-scroll-state` reports
/// (#320). Nothing in Release builds.
@MainActor @inline(__always)
func inspectorRenderTick(_ key: String) {
    #if DEBUG
    InspectorScrollDebugSteps.renders[key, default: 0] += 1
    #endif
}
