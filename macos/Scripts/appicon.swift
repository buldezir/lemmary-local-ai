#!/usr/bin/env swift
//
// The app icon, drawn rather than stored: run this to remake
// `Resources/LemmaryLocalAI.icns` (which is in git, so a normal build never
// runs this; only a change to the design does).
//
//   Scripts/appicon.swift                  # rewrite Resources/LemmaryLocalAI.icns
//   Scripts/appicon.swift --png out.png    # also leave a 1024px PNG
//
// Lemmary's own mark, the cream block "L" on oxblood from its favicon, inside
// the corners of a viewfinder: the same idea as the menu bar symbol
// (text.viewfinder), and what tells it apart from Lemmary's web app icon.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

/// Apple's icon template: an 824-point plate centred on the 1024 canvas, the
/// rest left for the shadow, so it sits at the same size as other apps' icons.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Superellipse rather than a rounded rect: a closer stand-in for Apple's
/// continuous corners.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Lemmary's palette (frontend/public/favicon.svg).
let oxblood = rgb(0x6E2620)
let cream = rgb(0xFFFEFA)

func drawIcon(into ctx: CGContext, small: Bool) {
    let shape = squircle(plate)

    // The shadow the grid leaves room for, drawn once under the plate. Shadow
    // offset and blur are in device pixels and ignore the context's scale, so
    // they are scaled here; unscaled, a 64px icon sat in a grey square.
    let pixels = ctx.userSpaceToDeviceSpaceTransform.a
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * pixels), blur: 28 * pixels, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(oxblood)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // A little lighter at the top than the favicon's flat colour, so the tile
    // does not look dead under the system's own lighting.
    let ground = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [rgb(0x83312A), oxblood, rgb(0x5A1E19)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    let unit = plate.width
    let cx = plate.midX, cy = plate.midY

    // The L, in the favicon's proportions: stem 4 wide, foot 12 wide and 3
    // high, 17 tall, on a 32 grid. Centred on its own bounding box, nudged
    // right because the foot makes the glyph's visual weight sit left. Without
    // the viewfinder around it, it takes the room the corners had.
    let grid = unit * (small ? 0.56 : 0.40) / 17
    let width = 12 * grid, height = 17 * grid
    let left = cx - width / 2 + grid * 0.6
    let bottom = cy - height / 2
    ctx.setFillColor(cream)
    ctx.fill(CGRect(x: left, y: bottom, width: 4 * grid, height: height))
    ctx.fill(CGRect(x: left, y: bottom, width: width, height: 3 * grid))

    // Viewfinder corners. They hold up down to 32px; at 16px they blurred into
    // the L, so there the L is drawn alone.
    guard !small else { return }
    let frame = plate.insetBy(dx: unit * 0.17, dy: unit * 0.17)
    let arm = unit * 0.15
    ctx.setStrokeColor(rgb(0xFFFEFA, 0.92))
    ctx.setLineWidth(unit * 0.048)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (x, y, dx, dy) in [
        (frame.minX, frame.maxY, 1.0, -1.0),
        (frame.maxX, frame.maxY, -1.0, -1.0),
        (frame.minX, frame.minY, 1.0, 1.0),
        (frame.maxX, frame.minY, -1.0, 1.0),
    ] {
        ctx.move(to: CGPoint(x: x, y: y + dy * arm))
        ctx.addLine(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    ctx.strokePath()
}

func render(size: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: size / canvas, y: size / canvas)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, small: size < 32)
    return ctx.makeImage()!
}

// MARK: - output

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("LemmaryLocalAI-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// The names iconutil expects; 512@2x is the 1024 the Finder reaches for on a
// Retina display.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(render(size: CGFloat(pixels)), to: iconset.appendingPathComponent(name))
}

let icns = root.appendingPathComponent("Resources/LemmaryLocalAI.icns")
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }
print("wrote \(icns.path)")

if let index = CommandLine.arguments.firstIndex(of: "--png"), index + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    writePNG(render(size: 1024), to: out)
    print("wrote \(out.path)")
}
