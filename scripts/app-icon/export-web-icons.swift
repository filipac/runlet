// Exports Runlet's app icon for the README and the website from Runlet/AppIcon.icon (#101), as
// macOS draws it in its default style. Run it from the repository root after changing the icon
// (make-app-icon.swift writes AppIcon.icon), and commit what it writes:
//
//     swift scripts/app-icon/export-web-icons.swift
//
// It renders with Icon Composer's ictool (inside Xcode), so the glass looks the way macOS draws
// it, and writes to website/assets:
//
// - app-icon-1024.png, app-icon-512.png, app-icon-224.png: the icon with the margins of a macOS
//   app icon (an 824 px body on the 1024 px canvas) and a soft shadow like the one macOS draws
//   beneath it, on a transparent background. The README shows app-icon-224.png at 112 pt, and
//   scripts/website-screenshots/brand.swift draws app-icon-1024.png on the Open Graph image.
// - favicon-16.png, favicon-32.png, favicon-48.png, and logo-56.png: the rounded square alone,
//   edge to edge, rendered by ictool directly at each size so small sizes stay sharp. The page's
//   favicons, and the header and footer logos (logo-56.png is 28 pt at 2×).
// - apple-touch-icon.png: 180 px with the background running to the edges and no transparent
//   corners, because iOS rounds the corners itself.
//
// Set ICTOOL to use another ictool than the selected Xcode's.
import AppKit
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("export-web-icons: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let iconURL = root.appendingPathComponent("Runlet/AppIcon.icon")
let assetsURL = root.appendingPathComponent("website/assets")
let fileManager = FileManager.default
guard fileManager.fileExists(atPath: iconURL.appendingPathComponent("icon.json").path) else { fail("no \(iconURL.path)") }

func run(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("cannot run \(executable): \(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(executable) failed: \(output)") }
    return output
}

// Icon Composer's ictool; `xcrun ictool` is a different tool.
let ictool = ProcessInfo.processInfo.environment["ICTOOL"] ?? {
    let developer = run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: developer).deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path
}()
guard fileManager.isExecutableFile(atPath: ictool) else { fail("Icon Composer's ictool not found at \(ictool); set ICTOOL") }

let scratch = fileManager.temporaryDirectory.appendingPathComponent("runlet-web-icons-\(UUID().uuidString)")
try! fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: scratch) }

/// The icon's rounded square in the default style, edge to edge, drawn by ictool at `pixels`.
func renderBody(pixels: Int) -> CGImage {
    let output = scratch.appendingPathComponent("body-\(pixels).png")
    _ = run(ictool, [iconURL.path, "--export-image", "--output-file", output.path, "--platform", "macOS", "--rendition", "Default",
                     "--width", "\(pixels)", "--height", "\(pixels)", "--scale", "1"])
    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == pixels else { fail("ictool wrote no \(pixels) px image") }
    return image
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas(_ pixels: Int, opaque: Bool = false) -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: alpha.rawValue) else { fail("cannot create a bitmap") }
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, _ name: String) {
    let url = assetsURL.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    print("Wrote \(url.path) (\(image.width) px)")
}

/// The icon as macOS shows it: the body (824/1024 of the canvas, rounded up to an even pixel
/// count so it sits on whole pixels) and a soft shadow beneath it.
func renderFramed(pixels: Int) -> CGImage {
    let unit = CGFloat(pixels) / 1024
    let side = Int(2 * (824 * unit / 2).rounded(.up))
    let origin = CGFloat(pixels - side) / 2
    let context = canvas(pixels)
    context.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 34 * unit, color: CGColor(gray: 0, alpha: 0.28))
    context.draw(renderBody(pixels: side), in: CGRect(x: origin, y: origin, width: CGFloat(side), height: CGFloat(side)))
    return context.makeImage()!
}

for pixels in [1024, 512, 224] {
    writePNG(renderFramed(pixels: pixels), "app-icon-\(pixels).png")
}
/// ictool writes Display P3; the website's images are sRGB.
func inSRGB(_ image: CGImage) -> CGImage {
    let context = canvas(image.width)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()!
}
for pixels in [16, 32, 48] {
    writePNG(inSRGB(renderBody(pixels: pixels)), "favicon-\(pixels).png")
}
writePNG(inSRGB(renderBody(pixels: 56)), "logo-56.png")

// apple-touch-icon: the icon's own background colors (icon.json's gradient, top to bottom) under
// the rounded square, so the corners are filled and iOS can round them.
let iconJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: iconURL.appendingPathComponent("icon.json"))) as! [String: Any]
guard let stops = (iconJSON["fill"] as? [String: Any])?["linear-gradient"] as? [String], stops.count == 2 else {
    fail("expected a two-color linear-gradient fill in icon.json")
}
let colors = stops.map { stop -> CGColor in
    let components = stop.split(separator: ":").last!.split(separator: ",").map { CGFloat(Double($0)!) }
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, components: components)!
}
let touch = canvas(180, opaque: true)
let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
touch.drawLinearGradient(gradient, start: CGPoint(x: 90, y: 180), end: CGPoint(x: 90, y: 0), options: [])
touch.draw(renderBody(pixels: 180), in: CGRect(x: 0, y: 0, width: 180, height: 180))
writePNG(touch.makeImage()!, "apple-touch-icon.png")
