import AppKit

let destination = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let n = CGFloat(pixels)
        let rect = NSRect(x: n * 0.06, y: n * 0.06, width: n * 0.88, height: n * 0.88)
        let background = NSBezierPath(roundedRect: rect, xRadius: n * 0.21, yRadius: n * 0.21)
        NSGradient(starting: NSColor(red: 0.08, green: 0.31, blue: 0.81, alpha: 1), ending: NSColor(red: 0.1, green: 0.63, blue: 0.98, alpha: 1))!.draw(in: background, angle: 75)
        for (index, height) in [0.24, 0.42, 0.60].enumerated() {
            NSColor.white.withAlphaComponent(index == 0 ? 0.72 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: n * (0.23 + Double(index) * 0.20), y: n * 0.23, width: n * 0.14, height: n * height), xRadius: n * 0.035, yRadius: n * 0.035).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
// ICNS accepts PNG payloads for these modern representation types.
func bigEndian(_ n: Int) -> Data {
    var value = UInt32(n).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var representations = Data()
for (type, file) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
                     ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
                     ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
                     ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent(file))
    representations.append(Data(type.utf8)); representations.append(bigEndian(png.count + 8)); representations.append(png)
}
var icon = Data("icns".utf8); icon.append(bigEndian(representations.count + 8)); icon.append(representations)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
