import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: GenerateAppIcon <output.iconset> [fallback.icns]\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "Clip32.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon canvas."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let silhouette = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.43, blue: 0.33, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.29, blue: 0.22, alpha: 1))?.draw(in: silhouette, angle: -90)

    // A second sheet and the gently lifted front edge make the mark feel like
    // stationery. Everything is vector-drawn, including the wire paperclip.
    NSGraphicsContext.saveGraphicsState()
    let rearTransform = AffineTransform(translationByX: 522, byY: 506)
    var rotation = rearTransform
    rotation.rotate(byDegrees: -8)
    rotation.translate(x: -522, y: -506)
    let rearSheet = NSBezierPath(roundedRect: NSRect(x: 290, y: 220, width: 482, height: 606), xRadius: 28, yRadius: 28)
    rearSheet.transform(using: rotation)
    let rearShadow = NSShadow()
    rearShadow.shadowColor = NSColor.black.withAlphaComponent(0.19)
    rearShadow.shadowBlurRadius = 28
    rearShadow.shadowOffset = NSSize(width: 0, height: -15)
    rearShadow.set()
    NSColor(srgbRed: 0.77, green: 0.81, blue: 0.72, alpha: 1).setFill()
    rearSheet.fill()
    NSGraphicsContext.restoreGraphicsState()

    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: 282, y: 250))
    sheet.line(to: NSPoint(x: 700, y: 250))
    sheet.curve(to: NSPoint(x: 726, y: 276), controlPoint1: NSPoint(x: 716, y: 250), controlPoint2: NSPoint(x: 726, y: 260))
    sheet.line(to: NSPoint(x: 726, y: 744))
    sheet.line(to: NSPoint(x: 630, y: 840))
    sheet.line(to: NSPoint(x: 282, y: 840))
    sheet.curve(to: NSPoint(x: 256, y: 814), controlPoint1: NSPoint(x: 266, y: 840), controlPoint2: NSPoint(x: 256, y: 830))
    sheet.line(to: NSPoint(x: 256, y: 276))
    sheet.curve(to: NSPoint(x: 282, y: 250), controlPoint1: NSPoint(x: 256, y: 260), controlPoint2: NSPoint(x: 266, y: 250))
    sheet.close()

    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor(srgbRed: 0.05, green: 0.16, blue: 0.10, alpha: 0.28)
    paperShadow.shadowBlurRadius = 30
    paperShadow.shadowOffset = NSSize(width: 0, height: -16)
    paperShadow.set()
    NSColor(srgbRed: 0.97, green: 0.955, blue: 0.90, alpha: 1).setFill()
    sheet.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Very restrained, deterministic paper fibers. They disappear naturally
    // at small icon sizes rather than becoming visible visual noise.
    NSGraphicsContext.saveGraphicsState()
    sheet.addClip()
    var seed: UInt64 = 0x5041504552
    for _ in 0..<4_200 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let x = 256 + CGFloat((seed >> 24) % 470_000) / 1_000
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let y = 250 + CGFloat((seed >> 24) % 590_000) / 1_000
        NSColor(srgbRed: 0.36, green: 0.39, blue: 0.29, alpha: 0.045).setFill()
        NSRect(x: x, y: y, width: 0.7, height: 1.4).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 630, y: 840))
    fold.line(to: NSPoint(x: 630, y: 768))
    fold.curve(to: NSPoint(x: 654, y: 744), controlPoint1: NSPoint(x: 630, y: 752), controlPoint2: NSPoint(x: 638, y: 744))
    fold.line(to: NSPoint(x: 726, y: 744))
    fold.close()
    NSColor(srgbRed: 0.83, green: 0.84, blue: 0.76, alpha: 1).setFill()
    fold.fill()

    // Quiet pencil-like rules leave the sheet recognizably paper without type.
    NSColor(srgbRed: 0.58, green: 0.66, blue: 0.55, alpha: 0.32).setFill()
    for (y, width) in [(488.0, 270.0), (432.0, 270.0), (376.0, 188.0)] {
        NSBezierPath(roundedRect: NSRect(x: 332, y: y, width: width, height: 12), xRadius: 6, yRadius: 6).fill()
    }

    let clip = NSBezierPath()
    clip.move(to: NSPoint(x: 443, y: 772))
    clip.line(to: NSPoint(x: 443, y: 635))
    clip.curve(to: NSPoint(x: 395, y: 635), controlPoint1: NSPoint(x: 443, y: 601), controlPoint2: NSPoint(x: 395, y: 601))
    clip.line(to: NSPoint(x: 395, y: 818))
    clip.curve(to: NSPoint(x: 479, y: 818), controlPoint1: NSPoint(x: 395, y: 875), controlPoint2: NSPoint(x: 479, y: 875))
    clip.line(to: NSPoint(x: 479, y: 624))
    clip.curve(to: NSPoint(x: 359, y: 624), controlPoint1: NSPoint(x: 479, y: 540), controlPoint2: NSPoint(x: 359, y: 540))
    clip.line(to: NSPoint(x: 359, y: 786))
    clip.lineWidth = 21
    clip.lineCapStyle = .round
    clip.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let clipShadow = NSShadow()
    clipShadow.shadowColor = NSColor(srgbRed: 0.13, green: 0.22, blue: 0.13, alpha: 0.22)
    clipShadow.shadowBlurRadius = 8
    clipShadow.shadowOffset = NSSize(width: 3, height: -6)
    clipShadow.set()
    NSColor(srgbRed: 0.20, green: 0.40, blue: 0.29, alpha: 1).setStroke()
    clip.stroke()
    NSGraphicsContext.restoreGraphicsState()
    clip.lineWidth = 7
    NSColor(srgbRed: 0.60, green: 0.72, blue: 0.56, alpha: 0.85).setStroke()
    clip.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Clip32.Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon."])
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let data = try drawIcon(size: points * scale)
        try data.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
    }
}

// A fallback for sessions where iconutil cannot convert the iconset.
// Modern ICNS also accepts the already-rendered PNG data directly.
if CommandLine.arguments.count == 3 {
    func bigEndian(_ value: Int) -> Data {
        var value = UInt32(value).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    let representations: [(String, String)] = [
        ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
    ]
    var chunks = Data()
    for (type, filename) in representations {
        let png = try Data(contentsOf: output.appendingPathComponent(filename))
        chunks.append(Data(type.utf8))
        chunks.append(bigEndian(png.count + 8))
        chunks.append(png)
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndian(chunks.count + 8))
    icns.append(chunks)
    let destination = URL(fileURLWithPath: CommandLine.arguments[2])
    try icns.write(to: destination, options: .atomic)
    guard let icon = NSImage(contentsOf: destination), icon.isValid else {
        throw NSError(domain: "Clip32.Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not validate generated ICNS."])
    }
}
