import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var chunks = Data()
func bigEndian(_ value: UInt32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
let types = ["16:1": "icp4", "16:2": "ic11", "32:1": "icp5", "32:2": "ic12", "128:1": "ic07", "128:2": "ic13", "256:1": "ic08", "256:2": "ic14", "512:1": "ic09", "512:2": "ic10"]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.05, y: p * 0.05, width: p * 0.90, height: p * 0.90)
        let shape = NSBezierPath(roundedRect: rect, xRadius: p * 0.20, yRadius: p * 0.20)
        NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.14, alpha: 1).setFill(); shape.fill()
        NSColor(calibratedWhite: 1, alpha: 0.13).setStroke(); shape.lineWidth = max(1, p * 0.003); shape.stroke()
        let font = NSFont.systemFont(ofSize: p * 0.75, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.74, green: 0.86, blue: 0.64, alpha: 1)]
        let text = "b" as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (p - textSize.width) / 2, y: (p - textSize.height) / 2 + p * 0.02), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
        chunks.append(Data(types["\(size):\(scale)"]!.utf8)); chunks.append(bigEndian(UInt32(png.count + 8))); chunks.append(png)
    }
}
try (Data("icns".utf8) + bigEndian(UInt32(chunks.count + 8)) + chunks).write(to: directory.deletingLastPathComponent().appendingPathComponent("Bob.icns"))
