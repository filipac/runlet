// Lays out the website's "Runlet's own PHP" collage (#67) from shoot-own-php.sh's shots: the
// banner on a Mac without PHP, the download in progress, Settings ▸ PHP after the install, and a
// run, as overlapping window cards with numbered captions, in the site's colors.
// usage: own-php-collage <shots dir> <light|dark> <out.png>   (see shoot-own-php.sh)
import AppKit

let args = CommandLine.arguments
let shots = URL(fileURLWithPath: args[1])
let dark = args[2] == "dark"
let output = URL(fileURLWithPath: args[3])

// Canvas in points, drawn at 2x (2400 px wide).
let canvas = CGSize(width: 1200, height: 830)
let scale: CGFloat = 2

func shot(_ name: String) -> CGImage {
    let url = shots.appendingPathComponent("\(name)-\(args[2]).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("missing \(url.path)")
    }
    return image
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The site's tokens (website/styles.css).
let accent = color(0x5856D6)
let text = dark ? color(0xF5F5F7) : color(0x1D1D1F)
let text2 = dark ? color(0xA1A1A6) : color(0x6E6E73)
let surface = dark ? color(0x1C1C1E) : color(0xFFFFFF)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = canvas
let graphics = NSGraphicsContext(bitmapImageRep: rep)!
let cg = graphics.cgContext
// Top-left origin, in points (the bitmap's size in points already scales by 2).
cg.translateBy(x: 0, y: canvas.height)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
cg.interpolationQuality = .high

// Background: a soft wash of the accent.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let wash = dark ? [color(0x16161D), color(0x0B0B0F)] : [color(0xFAFAFD), color(0xE9E8FB)]
cg.drawLinearGradient(CGGradient(colorsSpace: space, colors: wash as CFArray, locations: [0, 1])!,
                      start: .zero, end: CGPoint(x: canvas.width, y: canvas.height), options: [])
let glow = [color(0x5856D6, dark ? 0.30 : 0.16), color(0x5856D6, 0)]
cg.drawRadialGradient(CGGradient(colorsSpace: space, colors: glow as CFArray, locations: [0, 1])!,
                      startCenter: CGPoint(x: canvas.width * 0.72, y: canvas.height * 0.42), startRadius: 0,
                      endCenter: CGPoint(x: canvas.width * 0.72, y: canvas.height * 0.42), endRadius: canvas.width * 0.55, options: [])

/// Draws `crop` (in the shot's points; shots are 2x) of a shot as a window card at `origin`, `width` wide.
@discardableResult
func card(_ image: CGImage, crop: CGRect, at origin: CGPoint, width: CGFloat, radius: CGFloat = 10) -> CGRect {
    let pixels = CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)
    let part = image.cropping(to: pixels)!
    let frame = CGRect(x: origin.x, y: origin.y, width: width, height: width * crop.height / crop.width)
    let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: CGColor(gray: 0, alpha: dark ? 0.7 : 0.22))
    cg.addPath(path)
    cg.setFillColor(surface)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.08))
    cg.addPath(path)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.translateBy(x: frame.minX, y: frame.maxY)
    cg.scaleBy(x: 1, y: -1)
    cg.draw(part, in: CGRect(origin: .zero, size: frame.size))
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.18) : CGColor(gray: 0, alpha: 0.14))
    cg.setLineWidth(0.5)
    cg.strokePath()
    return frame
}

/// A caption chip: a numbered accent badge and a short label, centered vertically on `point`'s y.
func chip(_ number: Int, _ label: String, at point: CGPoint) {
    let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: text)!, .kern: -0.2]
    let string = NSAttributedString(string: label, attributes: attributes)
    let size = string.size()
    let badge: CGFloat = 26
    let frame = CGRect(x: point.x, y: point.y - 20, width: 7 + badge + 10 + ceil(size.width) + 16, height: 40)
    let path = CGPath(roundedRect: frame, cornerWidth: 20, cornerHeight: 20, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.16))
    cg.addPath(path)
    cg.setFillColor(dark ? color(0x2C2C2E) : color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 20, cornerHeight: 20, transform: nil))
    cg.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.08))
    cg.setLineWidth(0.5)
    cg.strokePath()
    let circle = CGRect(x: frame.minX + 7, y: frame.midY - badge / 2, width: badge, height: badge)
    cg.setFillColor(accent)
    cg.fillEllipse(in: circle)
    let digit = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white])
    let digitSize = digit.size()
    digit.draw(at: CGPoint(x: circle.midX - digitSize.width / 2, y: circle.midY - digitSize.height / 2))
    string.draw(at: CGPoint(x: circle.maxX + 10, y: frame.midY - size.height / 2))
}

let noPHP = shot("no-php"), downloading = shot("downloading"), settings = shot("settings-installed"), run = shot("run")
// The window's top: title bar, tab, banner, and the snippet's first line.
let banner = CGRect(x: 0, y: 0, width: 760, height: 158)
let runSize = CGSize(width: CGFloat(run.width) / 2, height: CGFloat(run.height) / 2)

/// Rings `rect` (in the shot's points) of a card drawn from `crop`, to point at what changed.
func ring(_ rect: CGRect, crop: CGRect, card: CGRect) {
    let k = card.width / crop.width
    let frame = CGRect(x: card.minX + (rect.minX - crop.minX) * k, y: card.minY + (rect.minY - crop.minY) * k,
                       width: rect.width * k, height: rect.height * k)
    let path = CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 10, color: color(0x5856D6, dark ? 0.9 : 0.55))
    cg.addPath(path)
    cg.setStrokeColor(dark ? color(0x7D7AFF) : accent)
    cg.setLineWidth(2)
    cg.strokePath()
    cg.restoreGState()
}

// 1 and 2: the banner before and during the download, stacked top left; 4: the run, bottom
// left; 3: Settings on the right, over the run's edge. Each caption sits just above its card.
let settingsCrop = CGRect(x: 0, y: 0, width: 560, height: 580)
let runCrop = CGRect(origin: .zero, size: runSize)
let firstCard = card(noPHP, crop: banner, at: CGPoint(x: 40, y: 76), width: 600)
ring(CGRect(x: 598, y: 92, width: 156, height: 32), crop: banner, card: firstCard)
let secondCard = card(downloading, crop: banner, at: CGPoint(x: 124, y: 260), width: 600)
ring(CGRect(x: 585, y: 92, width: 169, height: 32), crop: banner, card: secondCard)
let runCard = card(run, crop: runCrop, at: CGPoint(x: 40, y: 444), width: 780)
let settingsCard = card(settings, crop: settingsCrop, at: CGPoint(x: 744, y: 180), width: 416)
ring(CGRect(x: 22, y: 461, width: 516, height: 44), crop: settingsCrop, card: settingsCard)

chip(1, "No PHP, no Docker", at: CGPoint(x: firstCard.minX, y: firstCard.minY - 30))
chip(2, "One click, about 26 MB", at: CGPoint(x: secondCard.minX, y: secondCard.minY - 30))
chip(3, "Checked and installed", at: CGPoint(x: settingsCard.minX, y: settingsCard.minY - 30))
chip(4, "Runs right away", at: CGPoint(x: runCard.minX, y: runCard.minY - 30))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
