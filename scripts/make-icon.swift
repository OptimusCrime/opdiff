// Draws the OptimusDiff app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repo root)
//
// Design: dark navy rounded square (macOS icon grid) with a tiny diff on it:
// a neutral context line, a red "−" deletion and a green "+" addition.

import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    let s = canvas
    // Apple's icon grid: 824×824 body centred on a 1024 canvas, ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12), blur: 28,
        color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (top lighter navy → bottom deep navy).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            CGColor(srgbRed: 0.20, green: 0.25, blue: 0.40, alpha: 1),
            CGColor(srgbRed: 0.08, green: 0.10, blue: 0.18, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: s / 2, y: body.maxY),
        end: CGPoint(x: s / 2, y: body.minY), options: [])
    ctx.restoreGState()

    // Three diff lines.
    let left: CGFloat = 250
    let right: CGFloat = 774
    let barHeight: CGFloat = 112
    let gap: CGFloat = 44
    let radius: CGFloat = 26
    let total = barHeight * 3 + gap * 2
    let top = s / 2 + total / 2

    func bar(row: Int, fill: CGColor) -> CGRect {
        let y = top - CGFloat(row + 1) * barHeight - CGFloat(row) * gap
        let rect = CGRect(x: left, y: y, width: right - left, height: barHeight)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        return rect
    }

    func codeStub(in rect: CGRect, from x: CGFloat, width: CGFloat, alpha: CGFloat) {
        let h: CGFloat = 22
        let stub = CGRect(x: x, y: rect.midY - h / 2, width: width, height: h)
        ctx.addPath(CGPath(roundedRect: stub, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.fillPath()
    }

    func sign(in rect: CGRect, plus: Bool) {
        let cx = rect.minX + 78
        let cy = rect.midY
        let len: CGFloat = 58
        let thick: CGFloat = 16
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(
            CGPath(
                roundedRect: CGRect(x: cx - len / 2, y: cy - thick / 2, width: len, height: thick),
                cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
        if plus {
            ctx.addPath(
                CGPath(
                    roundedRect: CGRect(x: cx - thick / 2, y: cy - len / 2, width: thick, height: len),
                    cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
        }
        ctx.fillPath()
    }

    // Context line.
    let context = bar(row: 0, fill: CGColor(gray: 1, alpha: 0.10))
    codeStub(in: context, from: context.minX + 140, width: 300, alpha: 0.45)

    // Deletion.
    let deletion = bar(row: 1, fill: CGColor(srgbRed: 0.97, green: 0.32, blue: 0.29, alpha: 1))
    sign(in: deletion, plus: false)
    codeStub(in: deletion, from: deletion.minX + 140, width: 230, alpha: 0.75)

    // Addition.
    let addition = bar(row: 2, fill: CGColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1))
    sign(in: addition, plus: true)
    codeStub(in: addition, from: addition.minX + 140, width: 330, alpha: 0.75)
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try png(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
