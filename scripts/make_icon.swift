// Draws the FlashEdit app icon: a night-indigo tile (the darker ambient background) with a glowing flash bolt.
// Usage: swift scripts/make_icon.swift assets   ->  assets/icon.png (1024 px) and assets/AppIcon.icns
import AppKit
import CoreGraphics
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {  // (colour, alpha, location)
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

// the macOS icon grid: an 824 px tile with Apple's continuous corners, 100 px margin for the shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath

// drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(squircle); ctx.setFillColor(color(0x15163A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
// night sky: indigo at the top to near-black at the bottom
ctx.drawLinearGradient(gradient([(0x3A3F8F, 1, 0), (0x1A1B4B, 1, 0.55), (0x0B0B22, 1, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// the flash: warm burst behind the bolt
let centre = CGPoint(x: 512, y: 540)
ctx.drawRadialGradient(gradient([(0xFFF6D6, 1, 0), (0xFFD66B, 0.8, 0.16), (0xFF9C45, 0.38, 0.38), (0xB0508F, 0.12, 0.62), (0x6B4BFF, 0, 1)]),
                       startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 500, options: [])
// faint rays, like a flash catching the lens
for k in 0..<12 {
    let a = CGFloat(k) / 12 * 2 * .pi + 0.13, w: CGFloat = 0.045
    let ray = CGMutablePath()
    ray.move(to: centre)
    ray.addLine(to: CGPoint(x: centre.x + cos(a - w) * 700, y: centre.y + sin(a - w) * 700))
    ray.addLine(to: CGPoint(x: centre.x + cos(a + w) * 700, y: centre.y + sin(a + w) * 700))
    ray.closeSubpath()
    ctx.saveGState()
    ctx.addPath(ray); ctx.clip()
    ctx.drawRadialGradient(gradient([(0xFFF1C2, 0.22, 0), (0xFFF1C2, 0, 1)]),
                           startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 520, options: [])
    ctx.restoreGState()
}
// gloss on the upper half
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// the bolt
let pts: [CGPoint] = [(575, 850), (330, 505), (480, 505), (420, 180), (700, 575), (545, 575), (620, 850)]
    .map { CGPoint(x: $0.0, y: $0.1) }
let bolt = CGMutablePath()
bolt.addLines(between: pts); bolt.closeSubpath()
// glow: the bolt lights up the tile around it
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: color(0xFFD25A, 0.9))
ctx.addPath(bolt); ctx.setFillColor(color(0xFFE08A)); ctx.fillPath()
ctx.restoreGState()
// depth: soft shadow, then a darker body offset below the face
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x2A0E00, 0.55))
ctx.addPath(bolt); ctx.setFillColor(color(0xE08A16)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.translateBy(x: 0, y: -14)
ctx.addPath(bolt); ctx.setFillColor(color(0xC8640C)); ctx.fillPath()
ctx.restoreGState()
// face: bright white at the top to warm gold at the bottom
ctx.saveGState()
ctx.addPath(bolt); ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFFFFF, 1, 0), (0xFFF3C4, 1, 0.45), (0xFFC23D, 1, 1)]),
                       start: CGPoint(x: 512, y: 850), end: CGPoint(x: 512, y: 180), options: [])
ctx.restoreGState()
ctx.addPath(bolt); ctx.setStrokeColor(color(0xFFFFFF, 0.6)); ctx.setLineWidth(4); ctx.setLineJoin(.round); ctx.strokePath()

// crisp inner edge on the tile
ctx.addPath(squircle); ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

// write icon.png and the .icns (via an .iconset and iconutil)
let image = ctx.makeImage()!
func png(_ img: CGImage, _ url: URL) {
    let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
}
func scaled(_ px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return c.makeImage()!
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
png(image, out.appending(path: "icon.png"))
let set = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    png(scaled(base), set.appending(path: "icon_\(base)x\(base).png"))
    png(scaled(base * 2), set.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.appending(path: "AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print("wrote \(out.path)/icon.png and AppIcon.icns")
