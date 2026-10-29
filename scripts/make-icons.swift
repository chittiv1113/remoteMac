// Generates the app's icon set.
//
// The icons are committed as PNGs because the server serves them directly, but
// they are generated rather than drawn by hand so the source of truth is this
// file: change a colour here, re-run, and every size follows.
//
//   swift scripts/make-icons.swift Web
//
// The mark is a phone with a pointer arrow crossing its edge — the whole
// product in one shape: the phone is the input, the cursor is the output.

import AppKit
import CoreGraphics
import Foundation

// Palette, matching the --bg and --accent tokens in Web/style.css.
let background = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0, alpha: 1)
let foreground = NSColor(srgbRed: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF1 / 255.0, alpha: 1)
let accent = NSColor(srgbRed: 0xA5 / 255.0, green: 0x00 / 255.0, blue: 0x34 / 255.0, alpha: 1)

/// Everything below is laid out on a 1024×1024 grid and scaled at render time,
/// so the proportions hold at every output size.
let grid: CGFloat = 1024

/// Draw the mark into the current context.
///
/// `opaque` paints the rounded background plate. iOS applies its own corner
/// mask to a home-screen icon, so the radius here only has to look right if
/// nothing masks it.
func drawMark(in context: CGContext, cornerRadius: CGFloat, opaque: Bool) {
    if opaque {
        let plate = CGPath(roundedRect: CGRect(x: 0, y: 0, width: grid, height: grid),
                           cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                           transform: nil)
        context.addPath(plate)
        context.setFillColor(background.cgColor)
        context.fillPath()
    }

    // ── the phone ──
    // Offset left and up so the arrow, which hangs off its lower-right corner,
    // keeps the whole composition centred on the grid.
    let phone = CGRect(x: 246, y: 250, width: 376, height: 596)
    let stroke: CGFloat = 54
    context.addPath(CGPath(roundedRect: phone, cornerWidth: 72, cornerHeight: 72, transform: nil))
    context.setStrokeColor(foreground.cgColor)
    context.setLineWidth(stroke)
    context.strokePath()

    // The speaker slot, which is what makes the rectangle read as a phone
    // rather than a door, at any size.
    let slot = CGRect(x: phone.midX - 78, y: phone.maxY - 128, width: 156, height: 34)
    context.addPath(CGPath(roundedRect: slot, cornerWidth: 17, cornerHeight: 17, transform: nil))
    context.setFillColor(foreground.cgColor)
    context.fillPath()

    // ── the pointer ──
    // A standard arrow, defined tip-first in a 0…100 box with y running down,
    // then mapped onto the grid.
    let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 74), CGPoint(x: 20, y: 56),
        CGPoint(x: 32, y: 88), CGPoint(x: 46, y: 82), CGPoint(x: 33, y: 50),
        CGPoint(x: 58, y: 50),
    ]
    let arrowScale: CGFloat = 5.2
    let arrowOrigin = CGPoint(x: 494, y: 556)   // tip, in grid coordinates

    let arrow = CGMutablePath()
    for (index, point) in outline.enumerated() {
        let mapped = CGPoint(x: arrowOrigin.x + point.x * arrowScale,
                             y: arrowOrigin.y - point.y * arrowScale)   // flip y
        if index == 0 { arrow.move(to: mapped) } else { arrow.addLine(to: mapped) }
    }
    arrow.closeSubpath()

    // A halo in the background colour separates the arrow from the phone's
    // outline where they cross, so the shapes stay legible when overlapping.
    context.addPath(arrow)
    context.setStrokeColor(background.cgColor)
    context.setLineWidth(58)
    context.setLineJoin(.round)
    context.strokePath()

    context.addPath(arrow)
    context.setFillColor(accent.cgColor)
    context.fillPath()

    context.addPath(arrow)
    context.setStrokeColor(foreground.cgColor)
    context.setLineWidth(20)
    context.setLineJoin(.round)
    context.strokePath()
}

func render(size: Int, cornerRadius: CGFloat, opaque: Bool, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw Failure.contextUnavailable }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    let scale = CGFloat(size) / grid
    context.scaleBy(x: scale, y: scale)

    drawMark(in: context, cornerRadius: cornerRadius, opaque: opaque)

    guard let image = context.makeImage() else { throw Failure.renderFailed }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: size, height: size)
    guard let encoded = bitmap.representation(using: .png, properties: [:]) else {
        throw Failure.encodeFailed
    }
    let png = stripMetadata(from: encoded)
    try png.write(to: url)
    print("  \(url.lastPathComponent)  \(size)×\(size)  \(png.count) bytes")
}

/// Keep only the chunks needed to decode the image.
///
/// The encoder attaches an `eXIf` chunk describing the pixel dimensions, which
/// the dimensions in `IHDR` already state. Shipped assets should carry pixels
/// and nothing else — metadata in a binary is exactly the kind of thing that
/// gets committed once and then travels forever unnoticed.
func stripMetadata(from png: Data) -> Data {
    let signature = png.prefix(8)
    let essential: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS"]

    var output = Data(signature)
    var index = 8
    while index + 8 <= png.count {
        let length = png[index ..< index + 4].reduce(0) { Int($0) << 8 | Int($1) }
        guard let type = String(data: png[index + 4 ..< index + 8], encoding: .ascii) else { break }
        let end = index + 12 + length
        guard end <= png.count else { break }
        if essential.contains(type) { output.append(png[index ..< end]) }
        index = end
        if type == "IEND" { break }
    }
    return output
}

enum Failure: Error { case contextUnavailable, renderFailed, encodeFailed }

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1] : "Web", isDirectory: true)

print("▸ writing icons to \(outputDirectory.path)")
do {
    // Home-screen and PWA icons: opaque, with the platform's own corner mask in
    // mind — a generous radius that still looks right if nothing masks it.
    for size in [180, 192, 512] {
        try render(size: size, cornerRadius: 224, opaque: true,
                   to: outputDirectory.appendingPathComponent("icon-\(size).png"))
    }
    print("✅ done")
} catch {
    print("❌ \(error)")
    exit(1)
}
