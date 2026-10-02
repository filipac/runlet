#if DEBUG
import AppKit
import RunletCore
import WebKit

/// More RUNLET_DEBUG_STEPS steps (see `AppDelegate.runDebugInspectorCheck`), for checking
/// keyboard flows and file watching without UI scripting. Key events are sent to Runlet only,
/// so it has to be the active app (`activate` first):
/// `perform:<command id>` · `key:<[cmd+][shift+][opt+][ctrl+]name>` (a letter, digit, or
/// return, escape, delete, tab, up, down, left, right) · `type:<text>` · `state` (prints the
/// key window's focus and the active window's tabs) · `open:<path>` (like Finder) ·
/// `write:<path>|<text>` (appends in place) · `replace:<path>|<text>` (an atomic save) ·
/// `remove:<path>` · `edit:<text>` (inserts at the current tab's cursor) · `click:<accessibility
/// identifier>` · `dock[:<n>]` (lists the Dock menu, or chooses its nth item) ·
/// `settings-tab:<name>` (picks a tab of the open Settings window) · `mcp:on|off` (Settings ▸
/// AI Clients ▸ Allow AI clients to connect) · `mcp-approve` / `mcp-approve:session` /
/// `mcp-decline` (answers the AI client approval sheet on screen, as its Run button with or
/// without "Allow for this session", or Cancel; Debug builds only, for scripted end-to-end
/// checks with scratch data). In texts, `\n`
/// is a newline. A command that shows an alert should be pressed
/// with its shortcut (`key:cmd+s`), not `perform`: run from a step, `NSAlert.runModal` returns
/// at once.
///
/// Screenshot steps, used by scripts/website-screenshots/shoot.sh. They need no key events, so
/// Runlet can stay in the background:
/// `ghost` / `ghost:off` (keeps Runlet's windows drawing but invisible, click-through, and
/// without a Dock icon, so a screenshot run shows nothing on screen; launch with `open -g -j`
/// and make it the first step) · `appearance:light|dark|system` · `frame:<width>x<height>` (the
/// main window's size in points; `frame:<window title>=<width>x<height>` for another window) ·
/// `scale:<n>` (`shot` draws at least n pixels per point, e.g. 2 on a 1x screen) · `caret:end` or `caret:<line>[:<column>]` (the current tab's cursor) ·
/// `palette:anything|commands[:<query>]` (opens the palette with that search) · `complete`
/// (Show Completions in the current tab) · `segment:<label prefix>` (picks a segment, e.g.
/// `segment:Table` for a result's table) · `command:<name>` (runs a project command the
/// Commands pane listed, as its ▶ button does) · `terminal:<text>` (types into the active
/// window's selected terminal tab, straight to its process, so Runlet can stay in the
/// background; `\n` is Return, `\c` a comma) · `scroll:<accessibility identifier>` (scrolls
/// the element to the middle of its scroll view, e.g. a toggle low in a sheet's form) ·
/// `shot:<name>` (writes `<name>.png` to
/// RUNLET_SNAPSHOT_DIR: the main window with its sheet, palette, and popups drawn on top;
/// `shot:<name>@<window title>` draws another window, such as Settings).
@MainActor
enum DebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "appearance":
            // The app's setting, plus the whole app's appearance, as on a Mac set to that mode
            // (panels such as the completion list follow the system's).
            let appearance = AppearancePreference(rawValue: argument) ?? .system
            model.settings.appearance = appearance
            NSApp.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        case "frame":
            // `frame:<width>x<height>`, or `frame:<window title>=<width>x<height>` (e.g. Settings).
            let (title, spec) = titled(argument, "=")
            let size = spec.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window = title.flatMap(window(titled:)) ?? (title == nil ? mainWindow() : nil) {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            }
        case "ghost":
            ghost(argument != "off")
        case "scale":
            shotScale = Double(argument).map { CGFloat($0) } ?? 1
        case "caret":
            guard let editor = model.selectedTab?.editor else { return true }
            if argument == "end" {
                let end = (editor.text as NSString).length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            } else {
                let numbers = argument.split(separator: ":").compactMap { Int($0) }
                if let line = numbers.first { editor.goTo(line: line, column: numbers.count > 1 ? numbers[1] : 1) }
            }
        case "palette":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let commands = parts.first == "commands"
            if !NSApp.windows.contains(where: { $0 is PalettePanel && $0.isVisible }) {
                model.perform(commands ? "library.commandPalette" : "library.openAnything")
            }
            if parts.count > 1, let controller = NSApp.windows.compactMap({ ($0 as? PalettePanel)?.controller }).first {
                controller.edit(parts[1])
            }
        case "complete":
            // Show Completions in the current tab's editor, without key focus.
            model.selectedTab?.editor.textView.complete(nil)
        case "segment":
            // `segment:<label prefix>` picks the first segment whose label starts with it (the
            // last such control in the main window), e.g. `segment:Table` for a result's table.
            let controls = segmentedControls(in: mainWindow().flatMap { $0.contentView?.superview ?? $0.contentView })
            guard let control = controls.last(where: { control in (0..<control.segmentCount).contains { (control.label(forSegment: $0) ?? "").hasPrefix(argument) } }),
                  let index = (0..<control.segmentCount).first(where: { (control.label(forSegment: $0) ?? "").hasPrefix(argument) }) else {
                log("segment \(argument) not found among \(controls.map { control in (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" } })")
                return true
            }
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
        case "scroll":
            scroll(to: argument)
        case "shot":
            // `shot:<name>`, or `shot:<name>@<window title>` for another window (e.g. Settings).
            let (title, name) = titled(argument, "@", titleFirst: false)
            shot(name.isEmpty ? "shot" : name, window: title.flatMap(window(titled:)))
        case "command":
            // Runs a listed project command like its ▶ button (the Commands pane must have listed it).
            if let tab = model.selectedTab, let command = model.commands(for: tab.target)?.commands.first(where: { $0.name == argument }) {
                model.runProjectCommand(command, in: tab)
            } else {
                log("command \(argument) not listed")
            }
        case "terminal":
            // Typed into the selected terminal tab's process, like keys (no key window needed).
            if let session = model.activeWindow?.terminals.selected, session.isRunning {
                session.view.send(txt: argument.replacingOccurrences(of: "\\n", with: "\r").replacingOccurrences(of: "\\c", with: ","))
            } else {
                log("terminal: no running terminal tab")
            }
        case "perform":
            model.perform(argument)
        case "key":
            press(argument)
        case "type":
            for character in argument { key(code(for: character) ?? 0, text: String(character)) }
        case "state":
            log(state(model))
        case "open":
            AppDelegate.open(URL(fileURLWithPath: argument))
        case "write", "replace":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            let text = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            if name == "replace" {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: parts[0]), options: .atomic)
            } else if let handle = FileHandle(forWritingAtPath: parts[0]) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                handle.closeFile()
            }
        case "remove":
            try? FileManager.default.removeItem(atPath: argument)
        case "edit":
            model.selectedTab?.editor.insert(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "click":
            click(argument)
        case "settings-tab":
            // `settings-tab:<name>` picks a Settings tab (its toolbar item), e.g. `settings-tab:PHP`.
            let items = NSApp.windows.compactMap(\.toolbar).flatMap(\.items)
            if let item = items.first(where: { $0.label == argument }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                log("settings tab \(argument) not found among \(items.map(\.label))")
            }
        case "mcp":
            model.setMCPServerEnabled(argument != "off")
            log("mcp listening=\(model.mcp.isListening) socket=\(model.mcpSocketPath) error=\(model.mcp.listenerError ?? "none")")
        case "mcp-approve", "mcp-decline":
            guard let request = model.mcp.presented else {
                log("\(name): no approval sheet")
                return true
            }
            if name == "mcp-decline" {
                model.declineMCPRun(request)
            } else {
                model.approveMCPRun(request, allowSession: argument == "session")
            }
        case "dock":
            // `dock` lists the Dock menu; `dock:<n>` chooses its nth item.
            let menu = DockMenu.make(model: model)
            log("dock menu: \(menu?.items.map(\.title) ?? [])")
            if let index = Int(argument), let menu, menu.items.indices.contains(index) { menu.performActionForItem(at: index) }
        default:
            return false
        }
        return true
    }

    /// The editor window screenshots are taken of: the active document window, never a panel or sheet.
    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil && !($0 is NSPanel) }
        return candidates.first { $0.isMainWindow } ?? candidates.first
    }

    /// A visible window by title (Settings is titled after its current tab, e.g. "PHP").
    private static func window(titled title: String) -> NSWindow? {
        let window = NSApp.windows.first { $0.isVisible && $0.title == title }
        if window == nil { log("no window titled \(title)") }
        return window
    }

    /// Splits `<title><separator><rest>` (or `<rest><separator><title>`); no title without the separator.
    private static func titled(_ argument: String, _ separator: Character, titleFirst: Bool = true) -> (title: String?, rest: String) {
        let parts = argument.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return (nil, argument) }
        return titleFirst ? (parts[0], parts[1]) : (parts[1], parts[0])
    }

    private static var ghostTimer: Timer?
    /// Whether `ghost` keeps Runlet invisible (approval sheets then don't activate the app).
    static var isGhosted: Bool { ghostTimer != nil }
    /// Seconds `mcp-wait` has waited so far.
    static var mcpWaited = 0.0
    /// Minimum pixels per point for `shot` (`scale:<n>`); the window's own scale when higher.
    private static var shotScale: CGFloat = 1

    /// Keeps every Runlet window transparent and click-through (re-applied to windows that open
    /// later), so screenshot runs don't cover the screen. Views still draw for `shot`.
    private static func ghost(_ on: Bool) {
        ghostTimer?.invalidate()
        ghostTimer = nil
        applyGhost(on)
        // No Dock icon or menu bar while ghosted (nothing to click or quit by mistake).
        NSApp.setActivationPolicy(on ? .accessory : .regular)
        // A launch with `open -g -j` starts hidden; show the (now invisible) windows without
        // activating Runlet, so the user's frontmost app keeps the keyboard.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if on {
            let timer = Timer(timeInterval: 0.03, repeats: true) { _ in MainActor.assumeIsolated { applyGhost(true) } }
            RunLoop.main.add(timer, forMode: .common)
            ghostTimer = timer
        }
    }

    private static func applyGhost(_ on: Bool) {
        for window in NSApp.windows {
            window.alphaValue = on ? 0 : 1
            window.ignoresMouseEvents = on
            // Completion and info popups hide while Runlet is in the background.
            if on, let popup = window as? PopupPanel { popup.hidesOnDeactivate = false }
        }
    }

    /// Renders the main window, then its sheets and child windows (palette, completion and info
    /// popups) at their positions, into `<name>.png` in RUNLET_SNAPSHOT_DIR. Like
    /// `WindowSnapshots`, it uses AppKit drawing: no Screen Recording permission, nothing
    /// outside Runlet. Window corners and shadows are left to whatever shows the image;
    /// overlays get a rounded backing and a soft shadow, since their materials are composited
    /// by the window server and don't draw here. Web views and terminals are drawn on their own
    /// (see below), and the window buttons in their active colors.
    private static func shot(_ name: String, window: NSWindow? = nil) {
        guard let main = window ?? mainWindow() else { return log("shot: no window") }
        let scale = max(main.backingScaleFactor, shotScale)
        // Web views (mail and HTML previews) don't draw through cacheDisplay at another scale:
        // ask WebKit for their pictures first, then compose.
        let webViews = views(of: WKWebView.self, in: main.contentView).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
        guard !webViews.isEmpty else { return compose(name, main: main, scale: scale, web: []) }
        var pictures: [(image: CGImage, frame: CGRect, visible: CGRect)] = []
        var pending = webViews.count
        for webView in webViews {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * scale / main.backingScaleFactor))
            let frame = webView.convert(webView.bounds, to: nil)
            let visible = webView.convert(webView.visibleRect, to: nil)
            webView.takeSnapshot(with: configuration) { image, _ in
                MainActor.assumeIsolated {
                    if let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { pictures.append((image, frame, visible)) }
                    pending -= 1
                    if pending == 0 { compose(name, main: main, scale: scale, web: pictures) }
                }
            }
        }
    }

    private static func compose(_ name: String, main: NSWindow, scale: CGFloat, web: [(image: CGImage, frame: CGRect, visible: CGRect)]) {
        guard let directory = WindowSnapshots.directory else { return log("shot: no RUNLET_SNAPSHOT_DIR") }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = main.frame.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        let dark = main.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        var overlays: [NSWindow] = []
        var sheet = main.attachedSheet
        while let current = sheet {
            overlays.append(current)
            sheet = current.attachedSheet
        }
        overlays += (main.childWindows ?? []).sorted { $0.level.rawValue < $1.level.rawValue }
        for window in [main] + overlays {
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 1, view.bounds.height > 1,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = view.bounds.size
            // Behind-window materials are blended by the window server and draw as flat gray
            // here; blend them within the window instead while drawing.
            let effects = window === main ? [] : visualEffectViews(in: view).filter { $0.blendingMode == .behindWindow }
            effects.forEach { $0.blendingMode = .withinWindow }
            view.cacheDisplay(in: view.bounds, to: rep)
            effects.forEach { $0.blendingMode = .behindWindow }
            guard let image = rep.cgImage else { continue }
            let rect = window === main ? CGRect(origin: .zero, size: size)
                : CGRect(x: window.frame.minX - main.frame.minX, y: window.frame.minY - main.frame.minY, width: window.frame.width, height: window.frame.height)
            context.saveGState()
            if window !== main {
                let radius = window.isOpaque ? 16 : (window.contentView?.layer?.cornerRadius ?? 10)
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28).cgColor)
                context.addPath(path)
                context.setFillColor(dark ? NSColor(white: 0.17, alpha: 1).cgColor : NSColor(white: 0.985, alpha: 1).cgColor)
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.addPath(path)
                context.clip()
            }
            context.draw(image, in: rect)
            context.restoreGState()
            if window === main {
                // Runlet stays in the background, so its window draws inactive: give the close,
                // minimize, and zoom buttons their active colors, as on a window in use (muted
                // while a sheet dims the window).
                let alpha: CGFloat = main.attachedSheet == nil ? 1 : 0.6
                let buttons: [(NSWindow.ButtonType, NSColor)] = [
                    (.closeButton, NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: alpha)),
                    (.miniaturizeButton, NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: alpha)),
                    (.zoomButton, NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: alpha)),
                ]
                // Paint over the inactive buttons with the title bar's own color (sampled just
                // right of them) first.
                let frames = buttons.compactMap { main.standardWindowButton($0.0) }.filter { !$0.isHiddenOrHasHiddenAncestor }.map { $0.convert($0.bounds, to: nil) }
                if let group = frames.dropFirst().reduce(frames.first, { $0?.union($1) }),
                   let backdrop = context.makeImage()?.cropping(to: CGRect(x: (group.maxX + 6) * scale, y: (size.height - group.midY) * scale, width: 1, height: 1)) {
                    context.draw(backdrop, in: group.insetBy(dx: -4, dy: -4))
                }
                for (kind, color) in buttons {
                    guard let button = main.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor else { continue }
                    let frame = button.convert(button.bounds, to: nil)
                    let diameter = min(frame.width, frame.height)
                    let circle = CGRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2, width: diameter, height: diameter)
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: circle)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
                    context.setLineWidth(0.5)
                    context.strokeEllipse(in: circle.insetBy(dx: 0.25, dy: 0.25))
                }
                for picture in web {
                    context.saveGState()
                    context.clip(to: picture.visible)
                    context.draw(picture.image, in: picture.frame)
                    context.restoreGState()
                }
                // SwiftTerm draws glyphs with the context's text matrix, which earlier views in
                // the same pass leave flipped: draw terminals again in a context of their own.
                for terminal in views(of: RunletTerminalView.self, in: view) where !terminal.isHiddenOrHasHiddenAncestor && !terminal.visibleRect.isEmpty {
                    guard let own = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(terminal.bounds.width * scale), pixelsHigh: Int(terminal.bounds.height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    else { continue }
                    own.size = terminal.bounds.size
                    terminal.cacheDisplay(in: terminal.bounds, to: own)
                    guard let picture = own.cgImage else { continue }
                    context.saveGState()
                    context.clip(to: terminal.convert(terminal.visibleRect, to: nil))
                    context.draw(picture, in: terminal.convert(terminal.bounds, to: nil))
                    context.restoreGState()
                }
            }
        }
        guard let output = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: output)
        let url = directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            log("shot \(url.lastPathComponent) \(output.width)x\(output.height) active=\(NSApp.isActive) key=\(main.isKeyWindow) web=\(web.count) overlays=\(overlays.map { String(describing: type(of: $0)) })")
        } catch {
            log("shot failed: \(error)")
        }
    }

    private static func segmentedControls(in view: NSView?) -> [NSSegmentedControl] {
        views(of: NSSegmentedControl.self, in: view)
    }

    private static func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        views(of: NSVisualEffectView.self, in: view)
    }

    private static func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        let own: [V] = (view as? V).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Clicks the element with this accessibility identifier in the frontmost window that has it.
    private static func click(_ identifier: String) {
        let windows = NSApp.orderedWindows.filter(\.isVisible)
        guard let (window, frame) = windows.lazy.compactMap({ window in accessibilityFrame(of: identifier, in: window).map { (window, $0) } }).first else {
            return log("\(identifier) not found")
        }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Scrolls the element with this accessibility identifier (a sheet's first) to the middle of
    /// the innermost scroll view that holds it.
    private static func scroll(to identifier: String) {
        let windows = NSApp.windows.filter(\.isVisible).sorted { ($0.sheetParent != nil ? 0 : 1) < ($1.sheetParent != nil ? 0 : 1) }
        guard let (window, frame) = windows.lazy.compactMap({ window in accessibilityFrame(of: identifier, in: window).map { (window, $0) } }).first else {
            return log("\(identifier) not found")
        }
        let rect = window.convertFromScreen(frame)
        let scrollViews = views(of: NSScrollView.self, in: window.contentView?.superview ?? window.contentView)
        guard let scrollView = scrollViews.last(where: { scroll in
            guard let document = scroll.documentView else { return false }
            return document.frame.contains(scroll.contentView.convert(NSPoint(x: rect.midX, y: rect.midY), from: nil))
        }), let document = scrollView.documentView else { return log("no scroll view holds \(identifier)") }
        let clip = scrollView.contentView
        let target = clip.convert(rect, from: nil)
        var origin = clip.bounds.origin
        origin.y = min(max(target.midY - clip.bounds.height / 2, document.frame.minY), max(document.frame.minY, document.frame.maxY - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private static func accessibilityFrame(of identifier: String, in element: AnyObject, depth: Int = 0) -> NSRect? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier?() == identifier { return element.accessibilityFrame?() }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = accessibilityFrame(of: identifier, in: child as AnyObject, depth: depth + 1) { return frame }
        }
        return nil
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }

    private static func state(_ model: AppModel) -> String {
        let keyWindow = NSApp.keyWindow
        var focus = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        if let editor = keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            focus = "field:\(field.accessibilityIdentifier())"
        } else if keyWindow?.firstResponder is CodeTextView {
            focus = "editor"
        }
        let window = model.activeWindow
        let tabs = window?.tabs.map { tab in
            let code = (tab.editorIfLoaded?.text ?? tab.code).replacingOccurrences(of: "\n", with: "\\n")
            let issue = model.diskIssue(for: tab).map { " issue=\($0)" } ?? ""
            return "\(tab.id == window?.selectedTabId ? "*" : "")\(tab.title)\(tab.isFileDirty ? "•" : "") [\(model.targetLabel(tab.target))] \"\(code.prefix(60))\"\(issue)"
        } ?? []
        let floating = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map { "\($0.title):\($0.level.rawValue)" }
        return "key=\(keyWindow.map { $0 is PalettePanel ? "palette" : $0.title } ?? "none") focus=\(focus) inspector=\(model.showInspector ? "\(model.inspectorPane)" : "hidden") windows=\(floating) tabs=\(tabs)"
    }

    /// ANSI key codes 0–50, by the character they type.
    private static let keyCodes = Array("asdfhgzxcv§bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `")
    private static let named: [String: UInt16] = ["return": 36, "escape": 53, "delete": 51, "tab": 48, "space": 49, "up": 126, "down": 125, "left": 123, "right": 124]

    private static func code(for character: Character) -> UInt16? {
        keyCodes.firstIndex(of: Character(character.lowercased())).map(UInt16.init)
    }

    private static func press(_ spec: String) {
        var parts = spec.split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        guard let code = named[name] ?? name.first.flatMap(code(for:)) else { return log("unknown key \(spec)") }
        key(code, flags)
    }

    /// One key press, made the way the window server makes them (see `PaletteDebugCheck`), and
    /// queued like a real one, so `NSApp.currentEvent` is that press while it is handled.
    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
            if let event = NSEvent(cgEvent: event) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
#endif
