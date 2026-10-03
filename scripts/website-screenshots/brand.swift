// Renders the website's 1200×630 Open Graph image (assets/og.jpg) with the app icon
// (assets/app-icon-1024.png). usage: brand <website dir> <hero-light.png>   (see shoot.sh)
// The favicons and the other icon PNGs come from scripts/app-icon/export-web-icons.swift (#101).
import AppKit

let args = CommandLine.arguments
let site = URL(fileURLWithPath: args[1])
let hero = NSImage(contentsOfFile: args[2])!
let icon = NSImage(contentsOf: site.appendingPathComponent("assets/app-icon-1024.png"))!

func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let jpeg = url.pathExtension == "jpg"
    try! rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.86] : [:])!.write(to: url)
}

// Open Graph image.
png(width: 1200, height: 630, to: site.appendingPathComponent("assets/og.jpg")) { cg in
    let colors = [NSColor(srgbRed: 0.973, green: 0.973, blue: 0.984, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.905, green: 0.898, blue: 1.0, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 630), end: CGPoint(x: 1200, y: 0), options: [])

    // The window, bleeding off the right and bottom edges.
    let shotWidth: CGFloat = 900
    let shotHeight = shotWidth * hero.size.height / hero.size.width
    let shot = CGRect(x: 500, y: 630 - 96 - shotHeight, width: shotWidth, height: shotHeight)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 46, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(CGPath(roundedRect: shot, cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: shot, cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.clip()
    hero.draw(in: shot)
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: shot.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
    cg.setLineWidth(0.5)
    cg.strokePath()

    // App icon and text on the left. The icon's body (824 of its 1024 px) fills the 80 px box;
    // its margins hold the shadow.
    let iconSize: CGFloat = 80 * 1024 / 824
    icon.draw(in: NSRect(x: 64 - (iconSize - 80) / 2, y: 630 - 96 - 80 - (iconSize - 80) / 2, width: iconSize, height: iconSize))
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
        NSAttributedString(string: string, attributes: attributes).draw(at: NSPoint(x: 64, y: y))
    }
    let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
    let gray = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
    let indigo = NSColor(srgbRed: 0.33, green: 0.32, blue: 0.81, alpha: 1)
    text("Runlet", size: 78, weight: .bold, color: ink, y: 630 - 96 - 80 - 24 - 92, kern: -3)
    text("A native PHP scratchpad", size: 31, weight: .semibold, color: ink, y: 630 - 330 - 40, kern: -0.6)
    text("for macOS.", size: 31, weight: .semibold, color: ink, y: 630 - 330 - 80, kern: -0.6)
    text("Sandbox · local · Docker · SSH", size: 21, weight: .regular, color: gray, y: 630 - 330 - 136)
    text("Free & open source · MIT", size: 21, weight: .semibold, color: indigo, y: 630 - 330 - 170)
}
print("ok")
