// Renders one element of the website from disk to a PNG with WebKit, to check a layout at a given
// width and appearance, and for pull request screenshots. Nothing is shown on screen; images load
// eagerly and the fade-in is skipped.
//
//   swiftc -O -o build/render-section scripts/website-screenshots/render-section.swift
//   build/render-section website/index.html '#own-php' 1280 light out.png [scale]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 6, Double(args[3]) != nil else {
    print("usage: render-section <index.html> <css selector> <width> <light|dark> <out.png> [scale]")
    exit(2)
}
let width = Double(args[3])!
let page = URL(fileURLWithPath: args[1])
let selector = args[2]
let dark = args[4] == "dark"
let output = URL(fileURLWithPath: args[5])
let scale = args.count > 6 ? Double(args[6]) ?? 1 : 1

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
    var overflowing = ""

    func start() {
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.navigationDelegate = self
        window.contentView = webView
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do { try await self.capture() } catch { self.fail("\(error)") }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("\(error)") }

    @MainActor func measure() async throws -> CGRect {
        let script = """
        const style = document.createElement('style');
        style.textContent = '.reveal { transition: none !important; opacity: 1 !important; transform: none !important; } ::-webkit-scrollbar { display: none; }';
        document.head.appendChild(style);
        document.documentElement.style.scrollBehavior = 'auto';
        document.querySelectorAll('img').forEach(image => { image.loading = 'eager'; });
        await Promise.all([...document.images].map(image => image.decode().catch(() => null)));
        const element = document.querySelector(selector);
        if (!element) return null;
        const r = element.getBoundingClientRect();
        // Anything in it that sticks out of the viewport (a horizontal scroll on phones).
        // (Content inside a scrolling or clipping box is fine: only the box itself counts.)
        const clipped = e => { for (let p = e.parentElement; p && p !== document.body; p = p.parentElement) { if (getComputedStyle(p).overflowX !== 'visible') return true; } return false; };
        const wide = [element, ...element.querySelectorAll('*')].filter(e => {
            const b = e.getBoundingClientRect();
            return b.width > 0 && (b.right > innerWidth + 0.5 || b.left < -0.5) && !clipped(e);
        }).map(e => e.tagName.toLowerCase() + (e.className ? '.' + String(e.className).split(' ').join('.') : '')).join(' ');
        return [r.left + scrollX, r.top + scrollY, r.width, r.height, document.documentElement.scrollHeight, wide];
        """
        guard let values = try await webView.callAsyncJavaScript(script, arguments: ["selector": selector], contentWorld: .page) as? [Any], values.count == 6 else {
            throw NSError(domain: "render-section", code: 1, userInfo: [NSLocalizedDescriptionKey: "no element matches \(selector)"])
        }
        // Lay the whole page out in the viewport, so lazy and scroll-driven content is there.
        let height = (values[4] as? NSNumber)?.doubleValue ?? 900
        if webView.frame.height != height {
            webView.setFrameSize(NSSize(width: width, height: height))
            window.setContentSize(NSSize(width: width, height: height))
        }
        overflowing = values[5] as? String ?? ""
        let n = values.prefix(5).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    @MainActor func capture() async throws {
        _ = try await measure()
        try await Task.sleep(for: .milliseconds(600))
        let rect = try await measure()
        try await Task.sleep(for: .milliseconds(400))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: rect.width * scale)
        let image = try await webView.takeSnapshot(configuration: configuration)
        // Exactly `scale` pixels per CSS pixel, whatever the screen's scale.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((rect.width * scale).rounded()), pixelsHigh: Int((rect.height * scale).rounded()),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: rect.size))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        print("wrote \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh); wider than the viewport: \(overflowing.isEmpty ? "nothing" : overflowing)")
        exit(0)
    }

    func fail(_ message: String) {
        FileHandle.standardError.write(Data("render-section: \(message)\n".utf8))
        exit(1)
    }
}

let renderer = Renderer()
renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { renderer.fail("timed out") }
app.run()
