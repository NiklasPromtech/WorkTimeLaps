// Renders the app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// A record ring (the time-lapse) around a closed diary, on a squircle in
// the app's indigo → pink palette. Drawn on the standard macOS icon grid:
// an 824 px body centred in a 1024 px canvas.

import AppKit

let canvas: CGFloat = 1024
let body: CGFloat = 824
let inset = (canvas - body) / 2

func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: inset, y: inset, width: body, height: body)
    let squircle = CGPath(roundedRect: rect, cornerWidth: body * 0.225, cornerHeight: body * 0.225, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Body: diagonal indigo → violet → pink.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        NSColor(red: 0.29, green: 0.30, blue: 0.93, alpha: 1).cgColor,
        NSColor(red: 0.55, green: 0.33, blue: 0.95, alpha: 1).cgColor,
        NSColor(red: 0.94, green: 0.36, blue: 0.62, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Glassy highlight across the top.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Record ring: a faint full track, and a bright arc for the day so far.
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let radius: CGFloat = 268
    ctx.setLineCap(.round)
    ctx.setLineWidth(46)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.62, clockwise: true)
    ctx.strokePath()

    // Recording dot at the end of the arc.
    let endAngle = CGFloat.pi / 2 - .pi * 1.62
    let dot = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
    ctx.setFillColor(NSColor(red: 1.0, green: 0.36, blue: 0.40, alpha: 1).cgColor)
    ctx.setShadow(offset: .zero, blur: 18, color: NSColor(red: 1, green: 0.3, blue: 0.4, alpha: 0.9).cgColor)
    ctx.fillEllipse(in: CGRect(x: dot.x - 34, y: dot.y - 34, width: 68, height: 68))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // The diary.
    let config = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let book = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = book.size
        book.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2 - 6,
                             width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = renderMaster()
let masterURL = iconset.appendingPathComponent("icon_512x512@2x.png")
try! master.representation(using: .png, properties: [:])!.write(to: masterURL)

func resized(_ pixels: Int, name: String) {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(contentsOf: masterURL)!.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1)] {
    resized(points * scale, name: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
precondition(task.terminationStatus == 0, "iconutil failed")
print("Wrote \(output.path)")
if CommandLine.arguments.count > 1 {
    try! master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
