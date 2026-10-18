#!/usr/bin/env swift
// Melon Tools app icon generator.
// Draws a 1024x1024 icon: navy rounded square + melon slice (green rind, paper flesh, ink seeds) + gold tick.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}

// Background rounded square (macOS-style margin)
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: CGFloat(S) - margin * 2, height: CGFloat(S) - margin * 2)
let bgPath = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [color(0x0A2E5C), color(0x012357), color(0x011B42)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Subtle gold glow at top-right
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let glow = CGGradient(colorsSpace: cs,
                      colors: [color(0xFAC440, 0.22), color(0xFAC440, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 800, y: 830), startRadius: 0,
                       endCenter: CGPoint(x: 800, y: 830), endRadius: 520, options: [])
ctx.restoreGState()

// Melon slice: semicircle, flat side down
let center = CGPoint(x: 512, y: 330)
let r: CGFloat = 310

// Rind (green), slightly larger semicircle underneath
ctx.setFillColor(color(0x2F8A4C))
ctx.beginPath()
ctx.move(to: CGPoint(x: center.x - (r + 40), y: center.y))
ctx.addArc(center: center, radius: r + 40, startAngle: .pi, endAngle: 0, clockwise: true)
ctx.closePath()
ctx.fillPath()

// Inner rind highlight (light green)
ctx.setFillColor(color(0x7FBF7F))
ctx.beginPath()
ctx.move(to: CGPoint(x: center.x - (r + 20), y: center.y))
ctx.addArc(center: center, radius: r + 20, startAngle: .pi, endAngle: 0, clockwise: true)
ctx.closePath()
ctx.fillPath()

// Flesh (paper)
ctx.setFillColor(color(0xF3F3F1))
ctx.beginPath()
ctx.move(to: CGPoint(x: center.x - r, y: center.y))
ctx.addArc(center: center, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
ctx.closePath()
ctx.fillPath()

// Seeds (ink ellipses)
ctx.setFillColor(color(0x012357))
let seeds: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    // dx, dy, rx, ry
    (0, 150, 26, 38),
    (-140, 95, 24, 35),
    (140, 95, 24, 35),
    (-235, 30, 22, 32),
    (235, 30, 22, 32),
    (-80, 210, 22, 32),
    (80, 210, 22, 32),
]
for (dx, dy, rx, ry) in seeds {
    let seedRect = CGRect(x: center.x + dx - rx, y: center.y + dy - ry, width: rx * 2, height: ry * 2)
    ctx.fillEllipse(in: seedRect)
}

// Gold tick / prompt accent at bottom center
ctx.setStrokeColor(color(0xFAC440))
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 420, y: 210))
ctx.addLine(to: CGPoint(x: 520, y: 150))
ctx.addLine(to: CGPoint(x: 420, y: 90))
ctx.strokePath()
ctx.beginPath()
ctx.move(to: CGPoint(x: 560, y: 92))
ctx.addLine(to: CGPoint(x: 660, y: 92))
ctx.strokePath()

guard let image = ctx.makeImage() else { fatalError("image") }
let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(url.path)")
