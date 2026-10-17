// 生成 App 图标：深色圆角方块 + 仪表盘表盘（脚本用 `swift scripts/make-icon.swift` 运行）
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// 圆角背景（青蓝渐变）
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let clip = CGPath(roundedRect: bgRect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
ctx.saveGState()
ctx.addPath(clip)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.18, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

// 表盘弧线
let center = CGPoint(x: size / 2, y: size / 2 + size * 0.03)
let radius = size * 0.32
ctx.setLineWidth(size * 0.06)
ctx.setLineCap(.round)
// 底弧（灰）
ctx.setStrokeColor(NSColor(calibratedWhite: 0.35, alpha: 1).cgColor)
ctx.addArc(center: center, radius: radius,
           startAngle: 160, endAngle: 20, clockwise: true)
ctx.strokePath()
// 数据弧（青→绿）
let arcColors = [NSColor.systemTeal.cgColor, NSColor.systemGreen.cgColor]
let arcGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: arcColors as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addArc(center: center, radius: radius,
           startAngle: 160, endAngle: 100, clockwise: true)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(arcGradient,
                       start: CGPoint(x: center.x - radius, y: center.y + radius),
                       end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
ctx.restoreGState()

// 指针
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(size * 0.022)
ctx.setLineCap(.round)
let angle = 110.0 * Double.pi / 180
let needle = CGPoint(x: center.x + cos(angle) * radius * 0.75,
                     y: center.y + sin(angle) * radius * 0.75)
ctx.move(to: center)
ctx.addLine(to: needle)
ctx.strokePath()
// 中心点
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - size * 0.03, y: center.y - size * 0.03,
                           width: size * 0.06, height: size * 0.06))

ctx.restoreGState()
image.unlockFocus()

// 写 iconset
let outDir = URL(fileURLWithPath: "build/icon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                              (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                              (256, "icon_256x256"), (512, "icon_256x256@2x"),
                              (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (px, name) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
print("iconset 写入 \(outDir.path)")
