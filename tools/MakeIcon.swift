#!/usr/bin/env swift
// Draws the app icon (a treadmill mark) and packs it into AppIcon.icns.
// Everything is drawn with plain paths so there are no asset dependencies.
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./build/icon"
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let scale = size / 1024.0
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // Rounded-square plate with a vertical gradient.
    let inset: CGFloat = 64
    let plate = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: 200, cornerHeight: 200, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.11, green: 0.60, blue: 0.86, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.05, green: 0.28, blue: 0.62, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: []
    )
    ctx.restoreGState()

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let white = NSColor.white.withAlphaComponent(0.96).cgColor

    // Treadmill deck: a thick angled bar with a raised console post.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(58)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 250, y: 330))
    ctx.addLine(to: CGPoint(x: 700, y: 330))
    ctx.strokePath()

    // Console upright + handle.
    ctx.setLineWidth(46)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 700, y: 330))
    ctx.addLine(to: CGPoint(x: 762, y: 640))
    ctx.strokePath()
    ctx.setLineWidth(40)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 700, y: 646))
    ctx.addLine(to: CGPoint(x: 812, y: 646))
    ctx.strokePath()

    // Walking figure: head, torso, legs, arm.
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: 398, y: 690, width: 104, height: 104))
    ctx.setLineWidth(44)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 452, y: 676))       // torso
    ctx.addLine(to: CGPoint(x: 432, y: 520))
    ctx.strokePath()
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 432, y: 528))       // front leg
    ctx.addLine(to: CGPoint(x: 526, y: 430))
    ctx.addLine(to: CGPoint(x: 520, y: 392))
    ctx.strokePath()
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 432, y: 528))       // rear leg
    ctx.addLine(to: CGPoint(x: 348, y: 452))
    ctx.addLine(to: CGPoint(x: 316, y: 392))
    ctx.strokePath()
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 446, y: 626))       // arm
    ctx.addLine(to: CGPoint(x: 540, y: 596))
    ctx.strokePath()

    // Motion lines behind the walker.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(26)
    for (index, y) in [700, 630, 560].enumerated() {
        let length = CGFloat(150 - index * 34)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 250, y: CGFloat(y)))
        ctx.addLine(to: CGPoint(x: 250 + length, y: CGFloat(y)))
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let rep = drawIcon(size: variant.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}
print("wrote \(variants.count) images to \(iconset.path)")
