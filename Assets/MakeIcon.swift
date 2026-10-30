import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Draws Assets/AppIcon.png (1024×1024): two comic pages, the front one passing through a convert arrow.
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(40, 44, 80)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [rgb(255, 122, 89), rgb(238, 66, 102), rgb(120, 60, 200)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
ctx.restoreGState()

func page(_ rect: CGRect, angle: CGFloat, ink: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY); ctx.rotate(by: angle); ctx.translateBy(x: -rect.midX, y: -rect.midY)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.3))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Comic panel grid.
    let inset = rect.insetBy(dx: 30, dy: 30), gap: CGFloat = 16
    let rowH = (inset.height - 2 * gap) / 3
    let panels = [
        CGRect(x: inset.minX, y: inset.maxY - rowH, width: inset.width * 0.58, height: rowH),
        CGRect(x: inset.minX + inset.width * 0.58 + gap, y: inset.maxY - rowH, width: inset.width * 0.42 - gap, height: rowH),
        CGRect(x: inset.minX, y: inset.minY + rowH + gap, width: inset.width, height: rowH),
        CGRect(x: inset.minX, y: inset.minY, width: inset.width * 0.4, height: rowH),
        CGRect(x: inset.minX + inset.width * 0.4 + gap, y: inset.minY, width: inset.width * 0.6 - gap, height: rowH),
    ]
    ctx.setStrokeColor(ink); ctx.setLineWidth(10)
    for p in panels { ctx.addPath(CGPath(roundedRect: p, cornerWidth: 8, cornerHeight: 8, transform: nil)) }
    ctx.strokePath()
    ctx.restoreGState()
}
page(CGRect(x: 230, y: 290, width: 330, height: 460), angle: 0.12, ink: rgb(150, 150, 170))
page(CGRect(x: 450, y: 250, width: 360, height: 500), angle: -0.06, ink: rgb(40, 40, 60))

// Convert badge.
let badge = CGRect(x: 160, y: 170, width: 260, height: 260)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0, 0, 0, 0.3))
ctx.setFillColor(rgb(255, 255, 255)); ctx.fillEllipse(in: badge)
ctx.restoreGState()
ctx.setStrokeColor(rgb(238, 66, 102)); ctx.setLineWidth(26); ctx.setLineCap(.round)
let c = CGPoint(x: badge.midX, y: badge.midY), r: CGFloat = 78
for (start, end) in [(CGFloat.pi * 0.15, CGFloat.pi * 0.85), (CGFloat.pi * 1.15, CGFloat.pi * 1.85)] {
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false); ctx.strokePath()
    let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
    let dir = CGPoint(x: -sin(end), y: cos(end)), nrm = CGPoint(x: cos(end), y: sin(end))
    ctx.setFillColor(rgb(238, 66, 102))
    ctx.move(to: CGPoint(x: tip.x + dir.x * 40, y: tip.y + dir.y * 40))
    ctx.addLine(to: CGPoint(x: tip.x + nrm.x * 34 - dir.x * 6, y: tip.y + nrm.y * 34 - dir.y * 6))
    ctx.addLine(to: CGPoint(x: tip.x - nrm.x * 34 - dir.x * 6, y: tip.y - nrm.y * 34 - dir.y * 6))
    ctx.closePath(); ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(d))
