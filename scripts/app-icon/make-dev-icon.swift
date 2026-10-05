// Renders Runlet Dev's icon (#267): the classic app icon (Runlet/Assets.xcassets/AppIcon.appiconset,
// from make-app-icon.swift) with an orange "DEV" pill across the bottom of its body, into
// AppIconDev.appiconset, the Debug configuration's ASSETCATALOG_COMPILER_APPICON_NAME. A build
// from Xcode then looks different from the installed Runlet in the Dock and the app switcher.
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
