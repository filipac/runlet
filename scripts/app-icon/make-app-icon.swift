// Renders Runlet's app icon from its mark, website/assets/favicon.svg (#101). Run it from the
// repository root after changing the mark, then export-web-icons.swift (the README's and the
// website's images of the icon), and commit what they write:
//
//     swift scripts/app-icon/make-app-icon.swift
//     swift scripts/app-icon/export-web-icons.swift
//
// It writes two icons, both named AppIcon (the app's ASSETCATALOG_COMPILER_APPICON_NAME):
//
// - Runlet/AppIcon.icon, an Icon Composer icon for macOS 26's Liquid Glass. The mark's two
//   colors fill the background (Icon Composer runs the gradient from top to bottom), and the
//   play triangle and the cursor bar, cut from the SVG, are glass layers. macOS draws it in
//   its default, dark, tinted, and clear styles. Open it in Icon Composer (Xcode ▸ Open
//   Developer Tool) to preview them.
// - Runlet/Assets.xcassets/AppIcon.appiconset, a classic icon: PNGs for 16, 32, 128, 256, and
//   512 pt at @1x and @2x (16 to 1024 px). It follows Apple's macOS app icon template: a
//   rounded-square body of 824×824 px centered on the 1024×1024 canvas, with continuous
//   corners (radius 185 px) and a soft drop shadow beneath it. The body takes the mark's
//   diagonal gradient, with a faint highlight at the top for depth, and the glyphs are drawn
//   from the SVG, so they keep their proportions inside the body. Each size is drawn directly
//   at its pixel size, not scaled down from 1024, and the body is snapped to an even number of
//   whole pixels (14 px at 16, 26 px at 32, 104 px at 128, as macOS draws other apps' icons),
//   so small sizes stay sharp.
//
// When both exist, actool compiles AppIcon.icon and renders the app's flat images (in
// Assets.car and AppIcon.icns) from it, and leaves the classic set out. The classic set is the
// fallback: delete Runlet/AppIcon.icon and the app uses it.
import AppKit
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("website/assets/favicon.svg")
let iconSetURL = root.appendingPathComponent("Runlet/Assets.xcassets/AppIcon.appiconset")
let iconComposerURL = root.appendingPathComponent("Runlet/AppIcon.icon")
guard let svg = try? String(contentsOf: svgURL, encoding: .utf8) else { fail("cannot read \(svgURL.path)") }

// MARK: - The mark

func matches(_ pattern: String) -> [[String]] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).map { match in
        (0..<match.numberOfRanges).map { String(svg[Range(match.range(at: $0), in: svg)!]) }
    }
}

func srgb(hex: String, alpha: CGFloat = 1) -> CGColor {
    let value = Int(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

// The background: a 64×64 rounded square with a two-stop gradient from the top-left corner to
// the bottom-right one. The icon draws its own body in that gradient instead of this rect.
let stopHexes = matches(##"stop-color="#([0-9a-fA-F]{6})""##).map { $0[1] }
let stopColors = stopHexes.map { srgb(hex: $0) }
guard stopColors.count == 2 else { fail("expected a two-stop gradient in \(svgURL.path)") }
guard let background = matches(#"<rect width="64" height="64"[^>]*/>"#).first?[0] else {
    fail("expected the 64×64 background rect in \(svgURL.path)")
}
// The glyphs: the same SVG without its background.
let glyphSVG = svg.replacingOccurrences(of: background, with: "")
guard let glyphs = NSImage(data: Data(glyphSVG.utf8)), glyphs.isValid else { fail("cannot load the glyphs as an SVG image") }

// MARK: - Geometry

/// Apple's continuous-corner ("squircle") rounded rectangle, as UIKit draws it: each corner
/// starts 1.528 radii from the vertex and blends into the straight edges.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    // Corners in drawing order: vertex, unit vector back along the incoming edge, unit vector
    // along the outgoing edge.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (vertex, incoming, outgoing)) in corners.enumerated() {
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: vertex.x + (a * incoming.dx + b * outgoing.dx) * r, y: vertex.y + (a * incoming.dy + b * outgoing.dy) * r)
        }
        if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
        path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addLine(to: p(0.63149399, 0.07491100))
        path.addCurve(to: p(0.07491176, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
        path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
    }
    path.closeSubpath()
    return path
}

// MARK: - Rendering

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func renderIcon(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let unit = size / 1024  // one pixel of the 1024 px master
    guard let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create a bitmap") }

    // The body: 824/1024 of the canvas, rounded up to an even pixel count so it sits on whole pixels.
    let side = 2 * (824 * unit / 2).rounded(.up)
    let body = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    let shape = continuousRoundedRect(body, radius: side * 185.4 / 824)

    // Drop shadow: a tight one that defines the bottom edge, and a soft one that lifts the body.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit, color: CGColor(gray: 0, alpha: 0.30))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: max(4 * unit, 0.5), color: CGColor(gray: 0, alpha: 0.22))
    cg.addPath(shape)
    cg.setFillColor(stopColors[1])
    cg.fillPath()
    cg.endTransparencyLayer()
    cg.restoreGState()

    // The body's gradient, from the top-left corner to the bottom-right one, as in the SVG.
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: stopColors as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Depth: a faint highlight over the top half and a little shade at the bottom.
    let highlight = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
    cg.drawLinearGradient(highlight, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY), options: [])
    let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 0, alpha: 0.10), CGColor(gray: 0, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(shade, start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.minY + side * 0.4), options: [])
    cg.restoreGState()

    // The glyphs, mapped from the SVG's 64×64 view box onto the body, with a soft shadow at
    // sizes large enough to show it.
    cg.saveGState()
    if pixels >= 64 {
        cg.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 16 * unit, color: srgb(hex: "1e1670", alpha: 0.35))
    }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    glyphs.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = previous
    cg.restoreGState()

    return cg.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func writeJSON(_ object: Any, to url: URL) {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(Data("\n".utf8))
    try! data.write(to: url)
}

// MARK: - The classic icon

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconSetURL)
try! fileManager.createDirectory(at: iconSetURL, withIntermediateDirectories: true)
writeJSON(["info": ["author": "xcode", "version": 1]], to: iconSetURL.deletingLastPathComponent().appendingPathComponent("Contents.json"))

var images: [[String: String]] = []
var rendered: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        if rendered[pixels] == nil { rendered[pixels] = renderIcon(pixels: pixels) }
        writePNG(rendered[pixels]!, to: iconSetURL.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: iconSetURL.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconSetURL.path)")

// MARK: - The Icon Composer icon

// The glyphs, one SVG layer each, in the 1024 pt canvas Icon Composer lays layers out on.
let layerNames = ["play", "cursor"]
let glyphElements = matches(#"<(path|rect|circle|ellipse|polygon)\b[^>]*/>"#).map { $0[0] }.filter { $0 != background }
guard glyphElements.count == layerNames.count else {
    fail("expected \(layerNames.count) glyphs (\(layerNames.joined(separator: ", "))) in \(svgURL.path); update layerNames")
}
try? fileManager.removeItem(at: iconComposerURL)
let layerAssetsURL = iconComposerURL.appendingPathComponent("Assets")
try! fileManager.createDirectory(at: layerAssetsURL, withIntermediateDirectories: true)
var layers: [[String: Any]] = []
for (name, element) in zip(layerNames, glyphElements) {
    // A translucent glyph (the cursor bar) becomes a translucent layer.
    var element = element
    var layer: [String: Any] = ["image-name": "\(name).svg", "name": name]
    if let opacity = matches(#"fill-opacity="([0-9.]+)""#).first(where: { element.contains($0[0]) }) {
        element = element.replacingOccurrences(of: " " + opacity[0], with: "")
        layer["opacity"] = NSDecimalNumber(string: opacity[1])  // written as 0.85, not 0.8499…
    }
    let layerSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 64 64">
          \(element)
        </svg>

        """
    try! layerSVG.write(to: layerAssetsURL.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    layers.insert(layer, at: 0)  // Icon Composer lists the top layer first.
}
func iconComposerColor(_ hex: String) -> String {
    let value = Int(hex, radix: 16)!
    let components = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
    return "extended-srgb:" + components.joined(separator: ",") + ",1.00000"
}
writeJSON([
    "fill": ["linear-gradient": stopHexes.map(iconComposerColor)],
    "groups": [[
        "layers": layers,
        "shadow": ["kind": "neutral", "opacity": 0.5],
        // Opaque glass keeps the glyphs white, as in the mark, and legible at 16 px.
        "translucency": ["enabled": false, "value": 0.5],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
], to: iconComposerURL.appendingPathComponent("icon.json"))
print("Wrote \(iconComposerURL.path)")
