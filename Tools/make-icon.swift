import AppKit

// Boss Calendar icon: Metro Station metal dial as a 24 h day — violet busy arc, cyan build blocks, amber now index.
let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
ctx.setFillColor(rgb(0.025, 0.042, 0.058)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let wash = CGGradient(colorsSpace: cs, colors: [rgb(0.34, 0.93, 0.96, 0.16), rgb(0.34, 0.93, 0.96, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(wash, startCenter: CGPoint(x: 900, y: 940), startRadius: 0, endCenter: CGPoint(x: 900, y: 940), endRadius: 760, options: [])
ctx.setStrokeColor(rgb(1, 1, 1, 0.03)); ctx.setLineWidth(2)
for i in stride(from: 0, through: 1024, by: 64) {
    ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: 1024))
    ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: 1024, y: i))
}
ctx.strokePath()
let c = CGPoint(x: 512, y: 512)
// Housing + recessed face.
ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 50, color: rgb(0, 0, 0, 0.8))
ctx.setFillColor(rgb(0.027, 0.041, 0.055)); ctx.fillEllipse(in: CGRect(x: 112, y: 112, width: 800, height: 800))
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let face = CGGradient(colorsSpace: cs, colors: [rgb(0.075, 0.095, 0.115), rgb(0.021, 0.032, 0.042)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: 142, y: 142, width: 740, height: 740)); ctx.clip()
ctx.drawLinearGradient(face, start: CGPoint(x: 200, y: 880), end: CGPoint(x: 820, y: 150), options: [])
ctx.restoreGState()
ctx.setStrokeColor(rgb(1, 1, 1, 0.30)); ctx.setLineWidth(4); ctx.strokeEllipse(in: CGRect(x: 114, y: 114, width: 796, height: 796))
ctx.setStrokeColor(rgb(1, 1, 1, 0.08)); ctx.setLineWidth(2); ctx.strokeEllipse(in: CGRect(x: 142, y: 142, width: 740, height: 740))
// 24 h calibration (CG y-up: angle for minute m clockwise from top).
func ang(_ m: Double) -> Double { .pi / 2 - m / 1440 * 2 * .pi }
func pt(_ m: Double, _ r: Double) -> CGPoint { CGPoint(x: 512 + cos(ang(m)) * r, y: 512 + sin(ang(m)) * r) }
for q in 0..<96 {
    let major = q % 12 == 0, hour = q % 4 == 0
    ctx.setStrokeColor(rgb(1, 1, 1, major ? 0.6 : hour ? 0.32 : 0.12))
    ctx.setLineWidth(major ? 7 : hour ? 4 : 2.5)
    let m = Double(q) * 15
    ctx.move(to: pt(m, major ? 315 : hour ? 330 : 342)); ctx.addLine(to: pt(m, 356)); ctx.strokePath()
}
func arc(_ a: Double, _ b: Double, _ r: Double, _ w: CGFloat, _ color: CGColor) {
    ctx.setStrokeColor(color); ctx.setLineWidth(w); ctx.setLineCap(.butt)
    ctx.addArc(center: c, radius: r, startAngle: ang(a), endAngle: ang(b), clockwise: true); ctx.strokePath()
}
arc(9 * 60, 17.5 * 60, 292, 16, rgb(0.76, 0.57, 1, 0.9))          // busy: work day
arc(0, 24 * 60, 248, 40, rgb(1, 1, 1, 0.035))
arc(19 * 60, 20.5 * 60, 248, 40, rgb(0.32, 0.91, 0.96))            // build block 1 (done)
arc(20.75 * 60, 22 * 60, 248, 32, rgb(0.32, 0.91, 0.96, 0.6))      // build block 2 (planned)
arc(7 * 60, 8.25 * 60, 248, 32, rgb(0.32, 0.91, 0.96, 0.6))
// Glass lens hint.
ctx.setStrokeColor(rgb(1, 1, 1, 0.12)); ctx.setLineWidth(2); ctx.strokeEllipse(in: CGRect(x: 512 - 270, y: 512 - 270, width: 540, height: 540))
// Amber now index at 18:40.
let now = 18.66 * 60
ctx.setStrokeColor(rgb(1, 0.72, 0.31)); ctx.setLineWidth(12); ctx.setLineCap(.round)
ctx.move(to: pt(now, 140)); ctx.addLine(to: pt(now, 345)); ctx.strokePath()
ctx.setFillColor(rgb(1, 0.72, 0.31)); ctx.fillEllipse(in: CGRect(x: 512 - 22, y: 512 - 22, width: 44, height: 44))
ctx.setFillColor(rgb(0.027, 0.041, 0.055)); ctx.fillEllipse(in: CGRect(x: 512 - 9, y: 512 - 9, width: 18, height: 18))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
