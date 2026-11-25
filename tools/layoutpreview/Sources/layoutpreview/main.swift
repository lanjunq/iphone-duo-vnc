import Foundation
import CoreGraphics
import CoreText
import ImageIO
import DuoVNCKit

// usage: layoutpreview out.png
// Draws the session screen for several iPhone Duo configurations using the app's real layout code.

struct Config {
    var title: String
    var size: CGSize
    var divisions: [CGRect]
}

let configs: [Config] = [
    Config(title: "内屏横放 890×626", size: CGSize(width: 890, height: 626), divisions: []),
    Config(title: "内屏竖放 626×890", size: CGSize(width: 626, height: 890), divisions: []),
    Config(title: "半折（笔记本姿态）626×890", size: CGSize(width: 626, height: 890),
           divisions: [CGRect(x: 0, y: 441, width: 626, height: 8)]),
    Config(title: "外屏竖放 466×678", size: CGSize(width: 466, height: 678), divisions: []),
    Config(title: "外屏横放 678×466", size: CGSize(width: 678, height: 466), divisions: []),
]

let scale: CGFloat = 1.6
let gap: CGFloat = 40, labelH: CGFloat = 34
let totalW = configs.reduce(gap) { $0 + $1.size.width + gap }
let maxH = configs.map { $0.size.height }.max()! + labelH + gap * 2
let W = Int(totalW * scale), H = Int(maxH * scale)
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to a top-left origin in points.
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: scale, y: -scale)
ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: maxH))

func text(_ s: String, in r: CGRect, size: CGFloat, color: CGColor, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.saveGState()
    ctx.translateBy(x: r.midX - b.width / 2, y: r.midY + b.height / 2 - 2)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func rounded(_ r: CGRect, _ radius: CGFloat, fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
    ctx.fillPath()
}

var x = gap
for c in configs {
    let origin = CGPoint(x: x, y: gap + labelH)
    text(c.title, in: CGRect(x: x, y: gap - 6, width: c.size.width, height: labelH), size: 17,
         color: CGColor(gray: 0.1, alpha: 1), bold: true)
    let bounds = CGRect(origin: .zero, size: c.size)
    let out = LayoutEngine.layout(LayoutEngine.Input(bounds: bounds, remoteAspectRatio: 16.0 / 9.0), divisions: c.divisions)
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    rounded(bounds, 22, fill: CGColor(gray: 0.11, alpha: 1))
    ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    // Desktop area and the fitted remote screen inside it.
    ctx.setFillColor(CGColor(gray: 0.0, alpha: 1)); ctx.fill(out.desktopFrame)
    let fit = out.fittedContentSize
    let screen = CGRect(x: out.desktopFrame.midX - fit.width / 2, y: out.desktopFrame.midY - fit.height / 2,
                        width: fit.width, height: fit.height)
    ctx.setFillColor(CGColor(red: 0.20, green: 0.42, blue: 0.70, alpha: 1)); ctx.fill(screen)
    text("Mac 桌面 16:9", in: screen, size: 18, color: CGColor(gray: 1, alpha: 0.95))
    text("\(Int(fit.width))×\(Int(fit.height)) pt", in: screen.offsetBy(dx: 0, dy: 24), size: 13, color: CGColor(gray: 1, alpha: 0.8))
    // Toolbar buttons from the real ToolbarLayout.
    let local = CGRect(origin: .zero, size: out.toolbarFrame.size)
    let keepOut = out.toolbarKeepOutRects.map { $0.offsetBy(dx: -out.toolbarFrame.minX, dy: -out.toolbarFrame.minY) }
    let placement = ToolbarLayout.layout(items: ToolbarCommand.layoutItems, in: local, axis: out.axis, keepOut: keepOut)
    for command in ToolbarCommand.allCases {
        guard let f = placement.frames[command.rawValue] else { continue }
        let r = f.offsetBy(dx: out.toolbarFrame.minX, dy: out.toolbarFrame.minY)
        let fill: CGColor = command == .click ? CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
            : command == .disconnect ? CGColor(red: 0.55, green: 0.12, blue: 0.12, alpha: 1) : CGColor(gray: 0.24, alpha: 1)
        rounded(r, 10, fill: fill)
        text(command.title, in: r, size: min(15, r.height * 0.42), color: CGColor(gray: 1, alpha: 1))
    }
    for d in c.divisions {
        ctx.setFillColor(CGColor(red: 1, green: 0.75, blue: 0, alpha: 0.9)); ctx.fill(d)
    }
    ctx.restoreGState()
    if !placement.hidden.isEmpty {
        text("收进「更多」: \(placement.hidden.count) 个", in: CGRect(x: x, y: origin.y + c.size.height + 4, width: c.size.width, height: 22),
             size: 12, color: CGColor(gray: 0.3, alpha: 1))
    }
    print("\(c.title): desktop \(out.desktopFrame) toolbar \(out.toolbarFrame) axis \(out.axis) lanes \(placement.lanes) hidden \(placement.hidden)")
    x += c.size.width + gap
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "layout.png"
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
print(CGImageDestinationFinalize(dest) ? "wrote \(out)" : "failed")
