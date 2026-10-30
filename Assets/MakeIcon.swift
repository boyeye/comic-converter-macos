import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Draws Assets/AppIcon.png (1024×1024): two tilted comic pages on a halftone indigo tile, with a
// convert badge in the lower-right corner.
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [Int], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.map { rgb($0) } as CFArray, locations: locations)!
}
let ink = rgb(0x1B1F3B)

// Tile: macOS grid (824 pt body inside 1024), drop shadow, indigo→violet gradient.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x3A2E9E)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([0x7C6CFF, 0x5B3FD9, 0x34207F]), start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
// Halftone dots growing toward the lower-right corner: the comic print texture.
for row in 0..<26 {
    for col in 0..<26 {
        let x = 100 + CGFloat(col) * 33 + (row % 2 == 0 ? 0 : 16.5), y = 100 + CGFloat(row) * 33
        let t = max(0, ((x - 100) / 824 + (1 - (y - 100) / 824)) / 2 - 0.45) / 0.55
        guard t > 0 else { continue }
        let r = 2 + 9 * t
        ctx.setFillColor(rgb(0xFFFFFF, 0.10))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
}
// Soft top highlight.
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.32), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!,
                       startCenter: CGPoint(x: 330, y: 930), startRadius: 0, endCenter: CGPoint(x: 330, y: 930), endRadius: 560, options: [])
ctx.restoreGState()

func card(center: CGPoint, size: CGSize, angle: CGFloat, draw: (CGRect) -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: angle)
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let path = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0x0B0830, 0.45))
    ctx.addPath(path); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    draw(rect)
    ctx.restoreGState()
}

func panel(_ r: CGRect, fill: CGColor, _ extra: ((CGRect) -> Void)? = nil) {
    let p = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.saveGState()
    ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(p); ctx.clip(); extra?(r)
    ctx.restoreGState()
    ctx.addPath(p); ctx.setStrokeColor(ink); ctx.setLineWidth(9); ctx.strokePath()
}

// Back page: warm, simple grid.
card(center: CGPoint(x: 380, y: 590), size: CGSize(width: 330, height: 440), angle: 0.17) { r in
    ctx.setFillColor(rgb(0xFFF4D6)); ctx.fill(r)
    let i = r.insetBy(dx: 26, dy: 26), g: CGFloat = 16, h = (i.height - g) / 2
    panel(CGRect(x: i.minX, y: i.minY + h + g, width: i.width, height: h), fill: rgb(0xFFC94A))
    panel(CGRect(x: i.minX, y: i.minY, width: (i.width - g) * 0.5, height: h), fill: rgb(0xFF8A65))
    panel(CGRect(x: i.minX + (i.width - g) * 0.5 + g, y: i.minY, width: (i.width - g) * 0.5, height: h), fill: rgb(0xFFE08A))
}

// Front page: cool palette, sun, speed lines and a speech bubble.
card(center: CGPoint(x: 572, y: 548), size: CGSize(width: 350, height: 470), angle: -0.09) { r in
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(r)
    let i = r.insetBy(dx: 26, dy: 26), g: CGFloat = 16
    let topH = i.height * 0.42, bottomH = i.height - topH - g
    panel(CGRect(x: i.minX, y: i.maxY - topH, width: i.width * 0.58, height: topH), fill: rgb(0x8FD3FF)) { p in
        ctx.setFillColor(rgb(0xFFD54A)); ctx.fillEllipse(in: CGRect(x: p.minX + 26, y: p.maxY - 92, width: 64, height: 64))
        ctx.setFillColor(rgb(0x4C9F70))
        ctx.move(to: CGPoint(x: p.minX - 10, y: p.minY)); ctx.addLine(to: CGPoint(x: p.minX + 70, y: p.minY + 70))
        ctx.addLine(to: CGPoint(x: p.minX + 130, y: p.minY + 30)); ctx.addLine(to: CGPoint(x: p.maxX + 10, y: p.minY + 90))
        ctx.addLine(to: CGPoint(x: p.maxX + 10, y: p.minY - 10)); ctx.closePath(); ctx.fillPath()
    }
    panel(CGRect(x: i.minX + i.width * 0.58 + g, y: i.maxY - topH, width: i.width * 0.42 - g, height: topH), fill: rgb(0xFF9EC4))
    panel(CGRect(x: i.minX, y: i.minY, width: i.width, height: bottomH), fill: rgb(0xFFE7A3)) { p in
        // Speed lines radiating from a focus point.
        let focus = CGPoint(x: p.midX + 30, y: p.midY)
        ctx.setStrokeColor(rgb(0xF29E38)); ctx.setLineWidth(7); ctx.setLineCap(.round)
        for k in 0..<14 {
            let a = CGFloat(k) / 14 * .pi * 2
            ctx.move(to: CGPoint(x: focus.x + cos(a) * 70, y: focus.y + sin(a) * 55))
            ctx.addLine(to: CGPoint(x: focus.x + cos(a) * 260, y: focus.y + sin(a) * 200))
        }
        ctx.strokePath()
        ctx.setFillColor(rgb(0xFF5A5F)); ctx.fillEllipse(in: CGRect(x: focus.x - 46, y: focus.y - 46, width: 92, height: 92))
        ctx.setStrokeColor(ink); ctx.setLineWidth(8); ctx.strokeEllipse(in: CGRect(x: focus.x - 46, y: focus.y - 46, width: 92, height: 92))
    }
}

// Speech bubble overlapping the front page's top edge.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x0B0830, 0.35))
let bubble = CGMutablePath()
bubble.addEllipse(in: CGRect(x: 612, y: 718, width: 230, height: 150))
bubble.move(to: CGPoint(x: 662, y: 740)); bubble.addLine(to: CGPoint(x: 622, y: 678)); bubble.addLine(to: CGPoint(x: 702, y: 728))
ctx.addPath(bubble); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.addEllipse(in: CGRect(x: 612, y: 718, width: 230, height: 150)); ctx.setStrokeColor(ink); ctx.setLineWidth(9); ctx.strokePath()
ctx.setFillColor(ink)
for k in 0..<3 { ctx.fillEllipse(in: CGRect(x: 677 + CGFloat(k) * 42, y: 780, width: 26, height: 26)) }

// Convert badge: coral disc with a white ring and two chasing arrows.
let c = CGPoint(x: 752, y: 262), radius: CGFloat = 132
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x0B0830, 0.45))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
ctx.restoreGState()
ctx.saveGState()
let inner = radius - 14
ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner)); ctx.clip()
ctx.drawLinearGradient(gradient([0xFF8A5B, 0xFF4F7B]), start: CGPoint(x: c.x - inner, y: c.y + inner), end: CGPoint(x: c.x + inner, y: c.y - inner), options: [])
ctx.restoreGState()
let r: CGFloat = 64
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.setLineWidth(22); ctx.setLineCap(.round)
for (start, end) in [(CGFloat.pi * 0.20, CGFloat.pi * 0.80), (CGFloat.pi * 1.20, CGFloat.pi * 1.80)] {
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false); ctx.strokePath()
    // Arrowhead tangent to the arc end, pointing along the direction of travel.
    let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
    let dir = CGPoint(x: -sin(end), y: cos(end)), nrm = CGPoint(x: cos(end), y: sin(end))
    ctx.move(to: CGPoint(x: tip.x + dir.x * 36, y: tip.y + dir.y * 36))
    ctx.addLine(to: CGPoint(x: tip.x + nrm.x * 30 - dir.x * 8, y: tip.y + nrm.y * 30 - dir.y * 8))
    ctx.addLine(to: CGPoint(x: tip.x - nrm.x * 30 - dir.x * 8, y: tip.y - nrm.y * 30 - dir.y * 8))
    ctx.closePath(); ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(d))
