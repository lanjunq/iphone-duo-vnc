import UIKit
import CoreGraphics
import QuartzCore
import RFBCore
import DuoVNCKit

/// Magnifier shown while aiming: a crop of the framebuffer around the cursor, drawn with nearest-
/// neighbour scaling, with a crosshair and the outline of the exact remote pixel that will be clicked.
final class LoupeView: UIView {
    private let imageLayer: CALayer = CALayer()
    private let crosshairLayer: CAShapeLayer = CAShapeLayer()
    private let pixelLayer: CAShapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.cornerRadius = 14
        layer.masksToBounds = true
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .linear
        imageLayer.contentsGravity = .resize
        layer.addSublayer(imageLayer)
        crosshairLayer.strokeColor = UIColor.systemRed.cgColor
        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairLayer.lineWidth = 1.5
        layer.addSublayer(crosshairLayer)
        pixelLayer.strokeColor = UIColor.systemYellow.cgColor
        pixelLayer.fillColor = UIColor.clear.cgColor
        pixelLayer.lineWidth = 1
        layer.addSublayer(pixelLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `source` (remote pixels) of `framebuffer`, with the crosshair on `cursorPixel`.
    func update(framebuffer: Framebuffer?, source: CGRect, cursorPixel: (x: Int, y: Int)) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageLayer.frame = bounds
        guard let framebuffer = framebuffer, source.width >= 1, source.height >= 1 else {
            imageLayer.contents = nil
            crosshairLayer.path = nil
            pixelLayer.path = nil
            return
        }
        let rect: RFBRect = RFBRect(x: Int(source.minX), y: Int(source.minY), width: Int(source.width), height: Int(source.height))
        if let image = LoupeView.makeImage(framebuffer: framebuffer, rect: rect) {
            imageLayer.contents = image
        }
        let size: CGSize = bounds.size
        let center: CGPoint = LoupeGeometry.crosshairPoint(cursorPixel: cursorPixel, source: source, loupeSize: size)
        let pixelW: CGFloat = size.width / source.width
        let pixelH: CGFloat = size.height / source.height
        let gap: CGFloat = max(4, max(pixelW, pixelH))
        let path: UIBezierPath = UIBezierPath()
        path.move(to: CGPoint(x: center.x, y: 0))
        path.addLine(to: CGPoint(x: center.x, y: center.y - gap))
        path.move(to: CGPoint(x: center.x, y: center.y + gap))
        path.addLine(to: CGPoint(x: center.x, y: size.height))
        path.move(to: CGPoint(x: 0, y: center.y))
        path.addLine(to: CGPoint(x: center.x - gap, y: center.y))
        path.move(to: CGPoint(x: center.x + gap, y: center.y))
        path.addLine(to: CGPoint(x: size.width, y: center.y))
        crosshairLayer.path = path.cgPath
        crosshairLayer.frame = bounds
        let pixelRect: CGRect = CGRect(x: center.x - pixelW / 2, y: center.y - pixelH / 2, width: pixelW, height: pixelH)
        pixelLayer.path = UIBezierPath(rect: pixelRect).cgPath
        pixelLayer.frame = bounds
    }

    private static func makeImage(framebuffer: Framebuffer, rect: RFBRect) -> CGImage? {
        guard let bytes = try? framebuffer.copyPixels(rect), !bytes.isEmpty else { return nil }
        let data: Data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: rect.width, height: rect.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rect.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
