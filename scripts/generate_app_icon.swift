import AppKit
import CoreGraphics
import Foundation

@main
struct EveeIconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let pixels = Int(CommandLine.arguments[2]),
              pixels >= 16 else {
            fputs("usage: evee-icon-generator OUTPUT_PNG PIXELS\n", stderr)
            exit(64)
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fputs("Unable to create icon bitmap.\n", stderr)
            exit(1)
        }
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.current = previousContext }
        let context = graphicsContext.cgContext

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        let side = CGFloat(pixels)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let bounds = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.043, dy: side * 0.043)
        let tile = CGPath(
            roundedRect: bounds,
            cornerWidth: side * 0.218,
            cornerHeight: side * 0.218,
            transform: nil
        )
        context.addPath(tile)
        context.setFillColor(CGColor(red: 0.149, green: 0.145, blue: 0.165, alpha: 1))
        context.fillPath()

        let glyphRect = bounds.insetBy(dx: side * 0.145, dy: side * 0.145)
        context.saveGState()
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.addPath(EveeMarkGeometry.path(in: glyphRect))
        context.setStrokeColor(CGColor(red: 0.961, green: 0.949, blue: 0.925, alpha: 1))
        context.setLineWidth(max(2, side * 0.082))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Unable to encode icon.\n", stderr)
            exit(1)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
