import UIKit
import CoreGraphics
import RFBCore
import DuoVNCKit

/// The locally drawn pointer: the remote cursor image when the server sent one (Cursor pseudo-
/// encoding), otherwise a built-in arrow. Its hotspot sits exactly on the engine's cursor pixel.
final class CursorOverlayView: UIView {
    private let imageView: UIImageView = UIImageView()
    /// Hotspot in image points (built-in) or remote pixels (remote cursor).
    private var hotspot: CGPoint = .zero
    /// Image size in the same unit as `hotspot`.
    private var imageUnitSize: CGSize = .zero
    private var isRemoteImage: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        imageView.layer.magnificationFilter = .nearest
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        useBuiltInArrow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Uses the server's cursor; an invisible or malformed one falls back to the built-in arrow
    /// (aiming needs a visible pointer).
    func setRemoteCursor(_ cursor: RFBCursor) {
        if CursorImage.isInvisible(cursor.bgra, width: cursor.width, height: cursor.height) {
            useBuiltInArrow()
            return
        }
        guard let premultiplied = CursorImage.premultipliedBGRA(cursor.bgra, width: cursor.width, height: cursor.height),
              let provider = CGDataProvider(data: premultiplied as CFData) else {
            useBuiltInArrow()
            return
        }
        let info: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: cursor.width, height: cursor.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: cursor.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            useBuiltInArrow()
            return
        }
        imageView.image = UIImage(cgImage: cg)
        hotspot = CGPoint(x: CGFloat(cursor.hotspotX), y: CGFloat(cursor.hotspotY))
        imageUnitSize = CGSize(width: CGFloat(cursor.width), height: CGFloat(cursor.height))
        isRemoteImage = true
    }

    func useBuiltInArrow() {
        imageView.image = CursorOverlayView.arrowImage
        hotspot = CGPoint(x: 1, y: 1)
        imageUnitSize = CursorOverlayView.arrowSize
        isRemoteImage = false
    }

    /// Places the hotspot at `point` (desktop view coordinates). `viewportScale` = points per remote pixel.
    func place(at point: CGPoint, viewportScale: CGFloat) {
        let unit: CGFloat
        if isRemoteImage {
            // Remote pixels → points; never smaller than ~18 pt tall so it stays visible when fitted.
            let minimum: CGFloat = 18.0 / max(1.0, imageUnitSize.height)
            unit = min(max(viewportScale, minimum), 4.0)
        } else {
            unit = 1.0
        }
        imageView.frame = CGRect(x: point.x - hotspot.x * unit, y: point.y - hotspot.y * unit,
                                 width: imageUnitSize.width * unit, height: imageUnitSize.height * unit)
    }

    private static let arrowSize: CGSize = CGSize(width: 14, height: 21)

    /// A black-outlined white arrow with its tip at (1, 1).
    private static let arrowImage: UIImage = {
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(size: arrowSize)
        return renderer.image { (context: UIGraphicsImageRendererContext) in
            let path: UIBezierPath = UIBezierPath()
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 1, y: 17))
            path.addLine(to: CGPoint(x: 5, y: 13.5))
            path.addLine(to: CGPoint(x: 8, y: 20))
            path.addLine(to: CGPoint(x: 10.5, y: 19))
            path.addLine(to: CGPoint(x: 7.5, y: 12.5))
            path.addLine(to: CGPoint(x: 12.5, y: 12.5))
            path.close()
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.lineWidth = 1.2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }()
}
