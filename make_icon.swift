import AppKit
import CoreGraphics

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)

// 圆角底（macOS 图标留边 40pt，圆角 210）
let body = CGRect(x: 40, y: 40, width: S - 80, height: S - 80)
let p = CGPath(roundedRect: body, cornerWidth: 210, cornerHeight: 210, transform: nil)
ctx.addPath(p); ctx.clip()

let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [
    NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.96, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.86, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: S - 100), end: CGPoint(x: S - 100, y: 100), options: [])

// 白色下载箭头
ctx.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
ctx.fill(CGRect(x: 470, y: 430, width: 84, height: 250))
ctx.move(to: CGPoint(x: 355, y: 470))
ctx.addLine(to: CGPoint(x: 669, y: 470))
ctx.addLine(to: CGPoint(x: 512, y: 300))
ctx.closePath(); ctx.fillPath()
// 托盘
ctx.fill(CGRect(x: 320, y: 232, width: 384, height: 52))
// 顶部速度线
ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
ctx.fill(CGRect(x: 400, y: 700, width: 60, height: 34))
ctx.fill(CGRect(x: 482, y: 745, width: 60, height: 34))
ctx.fill(CGRect(x: 564, y: 700, width: 60, height: 34))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"))
