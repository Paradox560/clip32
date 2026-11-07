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
    NSGradient(starting: NSColor(srgbRed: 0.44, green: 0.44, blue: 0.94, alpha: 1),
               ending: NSColor(srgbRed: 0.27, green: 0.28, blue: 0.74, alpha: 1))?.draw(in: silhouette, angle: -90)

    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: NSRect(x: 322, y: 228, width: 440, height: 528), xRadius: 48, yRadius: 48).fill()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.35, alpha: 0.2)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 256, y: 280, width: 448, height: 524), xRadius: 48, yRadius: 48).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(srgbRed: 0.31, green: 0.32, blue: 0.79, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 378, y: 750, width: 204, height: 82), xRadius: 28, yRadius: 28).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 444, y: 780, width: 72, height: 15), xRadius: 7.5, yRadius: 7.5).fill()

    NSColor(srgbRed: 0.81, green: 0.82, blue: 0.94, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 332, y: 635, width: 290, height: 20), xRadius: 10, yRadius: 10).fill()
    NSBezierPath(roundedRect: NSRect(x: 332, y: 583, width: 210, height: 20), xRadius: 10, yRadius: 10).fill()

    let font = NSFont.monospacedDigitSystemFont(ofSize: 184, weight: .semibold)
    let number = NSAttributedString(string: "32", attributes: [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.77, alpha: 1),
        .kern: -8
    ])
    number.draw(at: NSPoint(x: 480 - number.size().width / 2, y: 332))

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
