#!/usr/bin/env swift

import AppKit
import Foundation

let logicalSize = NSSize(width: 720, height: 440)
let scale: CGFloat = 2

guard CommandLine.arguments.count == 2 else {
  fputs("usage: generate_dmg_background.swift /absolute/path/to/background.png\n", stderr)
  exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard outputURL.path.hasPrefix("/") else {
  fputs("background output path must be absolute\n", stderr)
  exit(2)
}

guard let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(logicalSize.width * scale),
  pixelsHigh: Int(logicalSize.height * scale),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  fputs("unable to allocate DMG background bitmap\n", stderr)
  exit(1)
}

bitmap.size = logicalSize
guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
  fputs("unable to create DMG background graphics context\n", stderr)
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
graphicsContext.shouldAntialias = true

let canvas = NSRect(origin: .zero, size: logicalSize)
let topColor = NSColor(calibratedRed: 0.975, green: 0.982, blue: 0.978, alpha: 1)
let bottomColor = NSColor(calibratedRed: 0.925, green: 0.945, blue: 0.934, alpha: 1)
NSGradient(starting: topColor, ending: bottomColor)?.draw(in: canvas, angle: 90)

func drawGlow(center: NSPoint, radius: CGFloat, color: NSColor) {
  NSGradient(starting: color, ending: color.withAlphaComponent(0))?.draw(
    fromCenter: center,
    radius: 0,
    toCenter: center,
    radius: radius,
    options: [.drawsAfterEndingLocation]
  )
}

drawGlow(
  center: NSPoint(x: 150, y: 220),
  radius: 250,
  color: NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.39, alpha: 0.20)
)
drawGlow(
  center: NSPoint(x: 575, y: 205),
  radius: 230,
  color: NSColor(calibratedRed: 0.38, green: 0.78, blue: 0.51, alpha: 0.11)
)

let centeredParagraph = NSMutableParagraphStyle()
centeredParagraph.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 29, weight: .semibold),
  .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
  .paragraphStyle: centeredParagraph,
  .kern: -0.35,
]
("CodexDone" as NSString).draw(
  in: NSRect(x: 0, y: 360, width: logicalSize.width, height: 42),
  withAttributes: titleAttributes
)

let arrowColor = NSColor(calibratedRed: 0.05, green: 0.67, blue: 0.29, alpha: 0.90)
arrowColor.setStroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 292, y: 205))
arrow.line(to: NSPoint(x: 430, y: 205))
arrow.move(to: NSPoint(x: 411, y: 222))
arrow.line(to: NSPoint(x: 430, y: 205))
arrow.line(to: NSPoint(x: 411, y: 188))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

let captionAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 15, weight: .medium),
  .foregroundColor: NSColor(calibratedWhite: 0.29, alpha: 0.86),
  .paragraphStyle: centeredParagraph,
]
("Drag to Applications" as NSString).draw(
  in: NSRect(x: 0, y: 38, width: logicalSize.width, height: 24),
  withAttributes: captionAttributes
)

NSColor(calibratedWhite: 0.72, alpha: 0.25).setStroke()
let border = NSBezierPath(rect: canvas.insetBy(dx: 0.5, dy: 0.5))
border.lineWidth = 1
border.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
  fputs("unable to encode DMG background PNG\n", stderr)
  exit(1)
}

do {
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try pngData.write(to: outputURL, options: .atomic)
} catch {
  fputs("unable to write DMG background: \(error.localizedDescription)\n", stderr)
  exit(1)
}
