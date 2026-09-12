import AppKit

// Package the approved artwork without redrawing its contents. A geometric
// application silhouette removes the presentation margin and yields clean alpha.
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
             (512, "512x512"), (1024, "512x512@2x")]
for (pixels, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: CGFloat(pixels)/1254, y: -CGFloat(pixels)/1254)
    let edge = CGMutablePath()
    edge.move(to: CGPoint(x: 340, y: 98))
    edge.addLine(to: CGPoint(x: 914, y: 98))
    edge.addCurve(to: CGPoint(x: 1162, y: 342), control1: CGPoint(x: 1082, y: 98), control2: CGPoint(x: 1162, y: 176))
    edge.addLine(to: CGPoint(x: 1162, y: 914))
    edge.addCurve(to: CGPoint(x: 914, y: 1154), control1: CGPoint(x: 1162, y: 1078), control2: CGPoint(x: 1082, y: 1154))
    edge.addLine(to: CGPoint(x: 340, y: 1154))
    edge.addCurve(to: CGPoint(x: 92, y: 914), control1: CGPoint(x: 172, y: 1154), control2: CGPoint(x: 92, y: 1078))
    edge.addLine(to: CGPoint(x: 92, y: 342))
    edge.addCurve(to: CGPoint(x: 340, y: 98), control1: CGPoint(x: 92, y: 176), control2: CGPoint(x: 172, y: 98))
    edge.closeSubpath()
    cg.addPath(edge); cg.clip()
    // CGImage drawing is flipped back so the approved upper-right gray arc stays put.
    cg.translateBy(x: 0, y: 1254)
    cg.scaleBy(x: 1, y: -1)
    cg.draw(source.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: 1254, height: 1254))
    NSGraphicsContext.restoreGraphicsState()
    for (x, y) in [(0, 0), (pixels-1, 0), (0, pixels-1), (pixels-1, pixels-1)] {
        precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent == 0)
    }
    precondition(bitmap.colorAt(x: pixels/2, y: pixels/2)!.alphaComponent > 0.99)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(name).png"))
}
print("Packaged 10 icon representations, 16–1024 px; transparent corners and opaque center verified.")
