// 生成 DSHMac 应用图标：渐变圆角方块 + dsh 字样
import AppKit
import CoreGraphics

let size = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 背景：深蓝→紫渐变圆角方块（macOS 图标惯例 ~82% 圆角占比）
let inset: CGFloat = 64
let bgRect = rect.insetBy(dx: inset, dy: inset)
let radius: CGFloat = 185
let path = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
let colors = [
    CGColor(red: 0.16, green: 0.23, blue: 0.96, alpha: 1),
    CGColor(red: 0.55, green: 0.20, blue: 0.92, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: inset, y: CGFloat(size) - inset), end: CGPoint(x: CGFloat(size) - inset, y: inset), options: [])
ctx.restoreGState()

// 高光斜杠装饰（terminal prompt 意象）
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
ctx.fill(CGRect(x: 0, y: 620, width: 1024, height: 340))
ctx.restoreGState()

// 文本 "dsh"：系统粗体
let attr: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 430, weight: .bold),
    .foregroundColor: NSColor.white,
]
let text = NSAttributedString(string: "dsh", attributes: attr)
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(
    x: bgRect.midX - bounds.midX,
    y: bgRect.midY - bounds.midY
)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("图标已生成")
