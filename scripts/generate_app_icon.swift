import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift OUTPUT_PNG\n", stderr)
    exit(64)
}

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Unable to create icon graphics context.\n", stderr)
    exit(1)
}

let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 44, dy: 44)
let shape = CGPath(roundedRect: bounds, cornerWidth: 224, cornerHeight: 224, transform: nil)
context.saveGState()
context.addPath(shape)
context.clip()

let colors = [
    CGColor(red: 0.714, green: 0.102, blue: 0.835, alpha: 1),
    CGColor(red: 0.486, green: 0.141, blue: 0.882, alpha: 1),
    CGColor(red: 0.098, green: 0.220, blue: 0.953, alpha: 1),
] as CFArray
guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else {
    image.unlockFocus()
    fputs("Unable to create icon gradient.\n", stderr)
    exit(1)
}
context.drawLinearGradient(gradient, start: CGPoint(x: 90, y: 920), end: CGPoint(x: 930, y: 100), options: [])

// A deliberately original Evee voice glyph: five soft waveform strokes.
context.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
context.setLineWidth(62)
context.setLineCap(.round)
let heights: [CGFloat] = [180, 330, 470, 330, 180]
for (index, height) in heights.enumerated() {
    let x = CGFloat(292 + index * 110)
    context.move(to: CGPoint(x: x, y: 512 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 512 + height / 2))
    context.strokePath()
}
context.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
