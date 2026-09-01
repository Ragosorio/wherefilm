#!/usr/bin/env swift
//
// Derives every brand asset the app and the site need from one master icon.
//
//   swift Scripts/make-brand-assets.swift
//
// Two things this fixes. The site was serving the 1254px master as its 40px
// logo — 1.4 MB for a favicon, on a page whose whole claim is that it feels
// expensive. And the Open Graph image the layout points at did not exist, so
// every shared link showed a blank card.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let master = root.appendingPathComponent("Brand/wherefilm-icon-master.png")
let publicDir = root.appendingPathComponent("site/public")
let brandDir = publicDir.appendingPathComponent("brand")

guard let masterImage = NSImage(contentsOf: master) else {
    FileHandle.standardError.write(Data("Cannot read \(master.path)\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: brandDir, withIntermediateDirectories: true)

// Palette, straight from the brand: Inkwell, Ophelia, Vapor, and the beam blue.
let inkWell = CGColor(red: 11 / 255, green: 20 / 255, blue: 33 / 255, alpha: 1)
let ophelia = CGColor(red: 40 / 255, green: 48 / 255, blue: 65 / 255, alpha: 1)
let beam = CGColor(red: 113 / 255, green: 138 / 255, blue: 190 / 255, alpha: 1)
let vapor = CGColor(red: 181 / 255, green: 185 / 255, blue: 188 / 255, alpha: 1)

func context(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create a \(width)×\(height) context") }
    return context
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [.compressionFactor: 0.9]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    print("· \(url.lastPathComponent) — \(image.width)×\(image.height) — \(size / 1024) KB")
}

func masterCGImage() -> CGImage {
    var rect = CGRect(origin: .zero, size: masterImage.size)
    guard let cgImage = masterImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fatalError("cannot rasterise the master icon")
    }
    return cgImage
}

let source = masterCGImage()

// ---------------------------------------------------------------------------
// Icon sizes the site actually requests
// ---------------------------------------------------------------------------
print("Icons")
for size in [32, 64, 96, 180, 192, 256, 512] {
    let ctx = context(width: size, height: size)
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = ctx.makeImage() else { continue }
    try write(image, to: brandDir.appendingPathComponent("icon-\(size).png"))
}

// The one the markup calls `wherefilm-icon.png`, now at a sane weight: it is
// never displayed above 92 CSS pixels, so 256 covers 2× and 3× displays.
let logoContext = context(width: 256, height: 256)
logoContext.interpolationQuality = .high
logoContext.draw(source, in: CGRect(x: 0, y: 0, width: 256, height: 256))
if let logo = logoContext.makeImage() {
    try write(logo, to: brandDir.appendingPathComponent("wherefilm-icon.png"))
}

// ---------------------------------------------------------------------------
// Open Graph card
// ---------------------------------------------------------------------------
print("\nOpen Graph")
let ogWidth = 1200
let ogHeight = 630
let og = context(width: ogWidth, height: ogHeight)

// Base gradient, corner to corner.
og.saveGState()
let baseGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [inkWell, CGColor(red: 5 / 255, green: 8 / 255, blue: 13 / 255, alpha: 1), ophelia] as CFArray,
    locations: [0, 0.56, 1])!
og.drawLinearGradient(baseGradient,
                      start: CGPoint(x: 0, y: ogHeight),
                      end: CGPoint(x: ogWidth, y: 0),
                      options: [])
og.restoreGState()

// The beam: the same idea as the icon, a light thrown across the archive.
og.saveGState()
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [beam.copy(alpha: 0.34)!, beam.copy(alpha: 0)!] as CFArray,
    locations: [0, 1])!
og.drawRadialGradient(glow,
                      startCenter: CGPoint(x: Double(ogWidth) * 0.82, y: Double(ogHeight) * 0.92),
                      startRadius: 0,
                      endCenter: CGPoint(x: Double(ogWidth) * 0.82, y: Double(ogHeight) * 0.92),
                      endRadius: 480,
                      options: [])
og.restoreGState()

// Hairline frame, so the card reads as a deliberate object on any timeline.
og.setStrokeColor(vapor.copy(alpha: 0.16)!)
og.setLineWidth(2)
og.stroke(CGRect(x: 1, y: 1, width: ogWidth - 2, height: ogHeight - 2))

// Icon.
let iconSize = 132.0
og.interpolationQuality = .high
og.draw(source, in: CGRect(x: 84, y: Double(ogHeight) - 84 - iconSize,
                           width: iconSize, height: iconSize))

func drawText(_ string: String, font: NSFont, color: CGColor,
              at point: CGPoint, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    let line = NSAttributedString(string: string, attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(line)
    let path = CGPath(rect: CGRect(x: point.x, y: point.y - 200, width: 1040, height: 200),
                      transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, og)
}

let display = NSFont.systemFont(ofSize: 74, weight: .semibold)
let body = NSFont.systemFont(ofSize: 30, weight: .regular)
let label = NSFont.systemFont(ofSize: 21, weight: .semibold)

drawText("WHEREFILM", font: label, color: vapor,
         at: CGPoint(x: 84, y: 380), tracking: 5)
drawText("Encuentra el momento.\nNo el archivo.", font: display,
         color: CGColor(red: 244 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1),
         at: CGPoint(x: 84, y: 356), tracking: -1.6)
drawText("Busca tus fotos y videos con tus propias palabras.\nTodo ocurre en tu Mac.",
         font: body, color: vapor.copy(alpha: 0.8)!,
         at: CGPoint(x: 84, y: 152))

if let image = og.makeImage() {
    try write(image, to: publicDir.appendingPathComponent("og-wherefilm.png"))
}

print("\nDone.")
