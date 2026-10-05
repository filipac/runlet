// Renders Runlet Dev's icon (#267), named AppIconDev (the Debug configuration's
// ASSETCATALOG_COMPILER_APPICON_NAME), so a build from Xcode looks different from the installed
// Runlet in the Dock and the app switcher. Like the release's AppIcon, it comes in two forms:
//
// - Runlet/AppIconDev.icon, an Icon Composer icon: Runlet/AppIcon.icon (the same fill and glass
//   layers) with a top layer that holds an orange "DEV" pill (Assets/dev.png). macOS 26 and later
//   draw this one; the Dock doesn't draw a classic icon set on its own (#269).
// - Runlet/Assets.xcassets/AppIconDev.appiconset, the classic icon (AppIcon.appiconset, from
//   make-app-icon.swift) with the same pill across the bottom of its body, for macOS 15.
// Run it from the repository root after make-app-icon.swift, and commit what it writes:
//
//     swift scripts/app-icon/make-dev-icon.swift
//
// Releases keep AppIcon (and AppIcon.icon, the Liquid Glass one); only Debug builds use this.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Runlet/Assets.xcassets/AppIcon.appiconset")
let target = root.appendingPathComponent("Runlet/Assets.xcassets/AppIconDev.appiconset")

guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents.json").path) else {
    FileHandle.standardError.write(Data("Run it from the repository root: no \(source.path)\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: target)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: source.appendingPathComponent("Contents.json"), to: target.appendingPathComponent("Contents.json"))

let orange = NSColor(srgbRed: 0.98, green: 0.45, blue: 0.09, alpha: 1)
let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".png") }.sorted()
for name in files {
    guard let image = NSImage(contentsOf: source.appendingPathComponent(name)),
          let input = image.representations.first as? NSBitmapImageRep else { continue }
    let size = input.pixelsWide
    guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
    let canvas = CGFloat(size)
    input.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))
    // The body is 824 of 1024 px, centered: the pill sits inside its lower part.
    let pill = NSRect(x: canvas * 0.25, y: canvas * 0.125, width: canvas * 0.5, height: canvas * 0.165)
    let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
    orange.setFill()
    path.fill()
    if size >= 64 {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = max(1, canvas * 0.012)
        path.stroke()
        let font = NSFont.systemFont(ofSize: pill.height * 0.62, weight: .heavy)
        let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: pill.height * 0.06])
        let textSize = text.size()
        text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2 + font.descender * 0.15))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = output.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: target.appendingPathComponent(name))
}
print("Wrote \(files.count) icons to \(target.path)")

// The Icon Composer icon: AppIcon.icon plus a "dev" group on top.
let composerSource = root.appendingPathComponent("Runlet/AppIcon.icon")
let composerTarget = root.appendingPathComponent("Runlet/AppIconDev.icon")
try? FileManager.default.removeItem(at: composerTarget)
try FileManager.default.copyItem(at: composerSource, to: composerTarget)
// The pill on the icon's full 1024 × 1024 canvas (the whole canvas is the icon's body here),
// below the play triangle's cursor bar.
let side = 1024
guard let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
let full = CGFloat(side)
let badge = NSRect(x: full * 0.2, y: full * 0.075, width: full * 0.6, height: full * 0.2)
let badgePath = NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2)
orange.setFill()
badgePath.fill()
let badgeFont = NSFont.systemFont(ofSize: badge.height * 0.62, weight: .heavy)
let label = NSAttributedString(string: "DEV", attributes: [.font: badgeFont, .foregroundColor: NSColor.white, .kern: badge.height * 0.06])
let labelSize = label.size()
label.draw(at: NSPoint(x: badge.midX - labelSize.width / 2, y: badge.midY - labelSize.height / 2 + badgeFont.descender * 0.15))
NSGraphicsContext.restoreGraphicsState()
try layer.representation(using: .png, properties: [:])!.write(to: composerTarget.appendingPathComponent("Assets/dev.png"))
let jsonURL = composerTarget.appendingPathComponent("icon.json")
var icon = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
var groups = icon["groups"] as? [[String: Any]] ?? []
// Icon Composer lists the topmost group first.
groups.insert([
    "layers": [["image-name": "dev.png", "name": "dev", "glass": false]],
    "shadow": ["kind": "neutral", "opacity": 0.35],
    "translucency": ["enabled": false, "value": 0.5],
], at: 0)
icon["groups"] = groups
try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL)
print("Wrote \(composerTarget.path)")
