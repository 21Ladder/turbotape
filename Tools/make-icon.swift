// Draws the TurboTape app icon (VHS cassette). Regenerate the AppIcon set with:
//   swiftc -O Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon_1024.png
//   then sips -z <size> <size> icon_1024.png for each size in App/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreText

// TurboTape app icon: a VHS cassette on a retro sunset squircle, tilted, with speed streaks.
let S: CGFloat = 1024
let out = CommandLine.arguments[1]

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// work in top-left coordinates
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func linear(_ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func text(_ s: String, font: String, size: CGFloat, color: CGColor, at p: CGPoint, kern: CGFloat = 0) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    // CoreText draws upright in bottom-left space: flip locally
    ctx.translateBy(x: p.x, y: p.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
func textWidth(_ s: String, font: String, size: CGFloat, kern: CGFloat = 0) -> CGFloat {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .kern: kern]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// 1. squircle background (macOS icon grid: 824 pt body, 100 pt margins) with a drop shadow
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x1B1035)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
linear([rgb(0x140B2E), rgb(0x4A1475), rgb(0xC2185B), rgb(0xFF8A3D)], [0, 0.45, 0.78, 1],
       from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// retro sun behind the cassette
ctx.saveGState()
let sun = CGRect(x: 512 - 250, y: 470, width: 500, height: 500)
ctx.addEllipse(in: sun); ctx.clip()
linear([rgb(0xFFE082, 0.95), rgb(0xFF7043, 0.9)], [0, 1], from: CGPoint(x: 512, y: 470), to: CGPoint(x: 512, y: 860))
// horizontal cuts through the sun
for (i, y) in stride(from: 760.0, to: 980.0, by: 34.0).enumerated() {
    ctx.setFillColor(rgb(0xC2185B))
    ctx.fill(CGRect(x: 200, y: y, width: 624, height: 6 + CGFloat(i) * 3))
}
ctx.restoreGState()
// scanlines
for y in stride(from: 100.0, to: 924.0, by: 8.0) {
    ctx.setFillColor(rgb(0xFFFFFF, 0.035))
    ctx.fill(CGRect(x: 100, y: y, width: 824, height: 2))
}
ctx.restoreGState()

// 2. the cassette, tilted, with speed streaks behind it
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()  // streaks and shadow stay inside the icon
ctx.translateBy(x: 530, y: 505)
ctx.rotate(by: -7 * .pi / 180)
ctx.scaleBy(x: 0.9, y: 0.9)
ctx.translateBy(x: -512, y: -500)

let cas = CGRect(x: 512 - 350, y: 500 - 215, width: 700, height: 430)

// speed streaks trailing to the left
let streaks: [(y: CGFloat, len: CGFloat, color: UInt32)] = [(cas.minY + 95, 230, 0xFFE082), (cas.minY + 200, 300, 0xFF8A3D), (cas.minY + 305, 210, 0x4DD0E1)]
for s in streaks {
    let r = CGRect(x: cas.minX - s.len + 30, y: s.y, width: s.len, height: 30)
    ctx.saveGState()
    ctx.addPath(rounded(r, 15)); ctx.clip()
    linear([rgb(s.color, 0), rgb(s.color, 0.95)], [0, 1], from: CGPoint(x: r.minX, y: 0), to: CGPoint(x: r.maxX, y: 0))
    ctx.restoreGState()
}

// body with shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: rgb(0x000000, 0.55))
ctx.addPath(rounded(cas, 34)); ctx.setFillColor(rgb(0x1A1A1D)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(cas, 34)); ctx.clip()
linear([rgb(0x3A3A40), rgb(0x1C1C20), rgb(0x0E0E10)], [0, 0.35, 1], from: CGPoint(x: 0, y: cas.minY), to: CGPoint(x: 0, y: cas.maxY))
// grip ridges on the sides
for x in [cas.minX + 18, cas.maxX - 40] {
    for k in 0..<7 {
        ctx.setFillColor(rgb(0x000000, 0.35))
        ctx.fill(CGRect(x: x, y: cas.minY + 150 + CGFloat(k) * 26, width: 22, height: 10))
    }
}
ctx.restoreGState()
ctx.addPath(rounded(cas.insetBy(dx: 2, dy: 2), 32)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(4); ctx.strokePath()

// label
let label = CGRect(x: cas.minX + 62, y: cas.minY + 34, width: cas.width - 124, height: 150)
ctx.addPath(rounded(label, 14)); ctx.setFillColor(rgb(0xF6EDD9)); ctx.fillPath()
ctx.saveGState()
ctx.addPath(rounded(label, 14)); ctx.clip()
// rainbow stripes across the lower part of the label
let stripeColors: [UInt32] = [0xE53935, 0xFB8C00, 0xFDD835, 0x26C6DA]
for (i, c) in stripeColors.enumerated() {
    ctx.setFillColor(rgb(c))
    ctx.fill(CGRect(x: label.minX, y: label.minY + 92 + CGFloat(i) * 13, width: label.width, height: 13))
}
ctx.restoreGState()
let title = "TURBOTAPE"
let titleFont = "Futura-CondensedExtraBold"
let tw = textWidth(title, font: titleFont, size: 70, kern: 4)
text(title, font: titleFont, size: 70, color: rgb(0x1A1446), at: CGPoint(x: label.midX - tw / 2, y: label.minY + 78), kern: 4)

// window with the reels
let win = CGRect(x: cas.midX - 225, y: label.maxY + 34, width: 450, height: 160)
ctx.addPath(rounded(win, 22)); ctx.setFillColor(rgb(0x050506)); ctx.fillPath()
ctx.saveGState()
ctx.addPath(rounded(win, 22)); ctx.clip()
let reelY = win.midY + 4
let left = CGPoint(x: win.minX + 118, y: reelY), right = CGPoint(x: win.maxX - 118, y: reelY)
// tape wound on the reels (left full, right nearly empty) and the tape between them
ctx.setFillColor(rgb(0x3E2723))
ctx.addEllipse(in: CGRect(x: left.x - 92, y: left.y - 92, width: 184, height: 184)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: right.x - 56, y: right.y - 56, width: 112, height: 112)); ctx.fillPath()
ctx.fill(CGRect(x: left.x, y: win.maxY - 24, width: right.x - left.x, height: 10))
// tape sheen rings
for r in stride(from: 50.0, to: 92.0, by: 9.0) {
    ctx.addEllipse(in: CGRect(x: left.x - r, y: left.y - r, width: 2 * r, height: 2 * r))
    ctx.setStrokeColor(rgb(0x6D4C41, 0.6)); ctx.setLineWidth(2); ctx.strokePath()
}
// white hubs with teeth
for c in [left, right] {
    ctx.addEllipse(in: CGRect(x: c.x - 38, y: c.y - 38, width: 76, height: 76)); ctx.setFillColor(rgb(0xF5F5F5)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30)); ctx.setFillColor(rgb(0x050506)); ctx.fillPath()
    for k in 0..<6 {
        let a = CGFloat(k) * .pi / 3
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: a)
        ctx.setFillColor(rgb(0x050506))
        ctx.fill(CGRect(x: 20, y: -5, width: 18, height: 10))
        ctx.restoreGState()
    }
}
// glass reflection
ctx.saveGState()
ctx.move(to: CGPoint(x: win.minX + 40, y: win.minY)); ctx.addLine(to: CGPoint(x: win.minX + 150, y: win.minY))
ctx.addLine(to: CGPoint(x: win.minX + 60, y: win.maxY)); ctx.addLine(to: CGPoint(x: win.minX - 50, y: win.maxY)); ctx.closePath()
ctx.setFillColor(rgb(0xFFFFFF, 0.07)); ctx.fillPath()
ctx.restoreGState()
ctx.restoreGState()
ctx.addPath(rounded(win, 22)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

// screws and the bottom flap
for p in [CGPoint(x: cas.minX + 40, y: cas.maxY - 40), CGPoint(x: cas.maxX - 40, y: cas.maxY - 40), CGPoint(x: cas.minX + 40, y: cas.minY + 40), CGPoint(x: cas.maxX - 40, y: cas.minY + 40)] {
    ctx.addEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)); ctx.setFillColor(rgb(0x2C2C31)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)); ctx.setStrokeColor(rgb(0x000000, 0.6)); ctx.setLineWidth(2); ctx.strokePath()
}
ctx.setFillColor(rgb(0xFFFFFF, 0.08))
ctx.fill(CGRect(x: cas.minX + 120, y: cas.maxY - 26, width: cas.width - 240, height: 3))
ctx.restoreGState()

// 3. subtle top gloss on the squircle
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
linear([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)], [0, 1], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 420))
ctx.restoreGState()
ctx.addPath(rounded(body.insetBy(dx: 1, dy: 1), 184)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
