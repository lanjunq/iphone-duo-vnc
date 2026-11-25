import UIKit
import Metal
import MetalKit
import simd
import RFBCore
import DuoVNCKit

/// Shows the remote framebuffer with Metal.
///
/// - One `.bgra8Unorm` texture (with mipmaps, so the 4K desktop downscales without shimmering),
///   updated per dirty rect straight from `Framebuffer.withPixels` (same byte layout, no conversion).
/// - The viewport transform (scale + offset, in points) is a uniform; the quad is generated in the
///   vertex shader from `vertex_id`, so there is no vertex buffer.
/// - Draws on demand only (`isPaused = true`, `enableSetNeedsDisplay = true`).
/// - The shader is compiled at runtime from `FramebufferRenderer.shaderSource` (no .metal build step).
/// The last texture stays on screen until a new frame arrives, so a reconnect keeps the last image.
final class FramebufferMetalView: UIView {
    private let metalView: MTKView?
    private let renderer: FramebufferRenderer?
    private let fallbackLabel: UILabel = UILabel()

    override init(frame: CGRect) {
        let device: MTLDevice? = MTLCreateSystemDefaultDevice()
        var created: FramebufferRenderer? = nil
        var view: MTKView? = nil
        if let device = device {
            let mtk: MTKView = MTKView(frame: CGRect(origin: .zero, size: frame.size), device: device)
            mtk.colorPixelFormat = .bgra8Unorm
            mtk.framebufferOnly = true
            mtk.isPaused = true
            mtk.enableSetNeedsDisplay = true
            mtk.autoResizeDrawable = true
            mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            mtk.isUserInteractionEnabled = false
            mtk.isOpaque = true
            created = FramebufferRenderer(device: device, pixelFormat: mtk.colorPixelFormat)
            if created != nil {
                view = mtk
            }
        }
        self.metalView = view
        self.renderer = created
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        if let mtk = metalView, let renderer = renderer {
            mtk.delegate = renderer
            addSubview(mtk)
        } else {
            fallbackLabel.text = "这台设备无法使用 Metal，不能显示画面"
            fallbackLabel.textColor = .white
            fallbackLabel.textAlignment = .center
            fallbackLabel.numberOfLines = 0
            addSubview(fallbackLabel)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView?.frame = bounds
        fallbackLabel.frame = bounds.insetBy(dx: 16, dy: 16)
        metalView?.setNeedsDisplay()
    }

    /// Sets the transform; redraws only when it changed.
    func setViewport(_ viewport: Viewport) {
        guard let renderer = renderer else { return }
        if renderer.viewport != viewport {
            renderer.viewport = viewport
            metalView?.setNeedsDisplay()
        }
    }

    /// Copies the dirty rects of `framebuffer` into the texture and schedules a redraw.
    /// A different framebuffer object or size (reconnect, DesktopSize) uploads the whole frame.
    func update(from framebuffer: Framebuffer, rects: [RFBRect]) {
        guard let renderer = renderer else { return }
        renderer.upload(from: framebuffer, rects: rects)
        metalView?.setNeedsDisplay()
    }
}

/// Uniform block shared with the shader. Three float2 = 24 bytes, 8-byte aligned, same as MSL.
struct FramebufferUniforms {
    var viewSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

final class FramebufferRenderer: NSObject, MTKViewDelegate {
    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct DuoUniforms {
        float2 viewSize;
        float2 origin;
        float2 size;
    };

    struct DuoVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex DuoVertexOut duo_vertex(uint vid [[vertex_id]],
                                   constant DuoUniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
        float2 c = corners[vid];
        float2 p = u.origin + c * u.size;
        float2 ndc = float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
        DuoVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = c;
        return out;
    }

    fragment float4 duo_fragment(DuoVertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.uv);
    }
    """

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let smoothSampler: MTLSamplerState
    private let pixelSampler: MTLSamplerState
    private var texture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private weak var source: Framebuffer?
    private var mipmapsDirty: Bool = false
    /// The last committed frame. `upload` waits for it before writing the shared texture, so the CPU
    /// never overwrites pixels (or level 0 during mipmap generation) the GPU is still reading.
    private var lastCommandBuffer: MTLCommandBuffer?

    var viewport: Viewport?

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: FramebufferRenderer.shaderSource, options: nil)
        } catch {
            return nil
        }
        guard let vertexFunction = library.makeFunction(name: "duo_vertex"),
              let fragmentFunction = library.makeFunction(name: "duo_fragment") else { return nil }
        let descriptor: MTLRenderPipelineDescriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let pipelineState: MTLRenderPipelineState
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        let smooth: MTLSamplerDescriptor = MTLSamplerDescriptor()
        smooth.minFilter = .linear
        smooth.magFilter = .linear
        smooth.mipFilter = .linear
        smooth.sAddressMode = .clampToEdge
        smooth.tAddressMode = .clampToEdge
        let pixel: MTLSamplerDescriptor = MTLSamplerDescriptor()
        pixel.minFilter = .linear
        pixel.magFilter = .nearest
        pixel.mipFilter = .linear
        pixel.sAddressMode = .clampToEdge
        pixel.tAddressMode = .clampToEdge
        guard let smoothState = device.makeSamplerState(descriptor: smooth),
              let pixelState = device.makeSamplerState(descriptor: pixel) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipelineState
        self.smoothSampler = smoothState
        self.pixelSampler = pixelState
        super.init()
    }

    /// Main thread only (called from the session delegate).
    func upload(from framebuffer: Framebuffer, rects: [RFBRect]) {
        let switched: Bool = source !== framebuffer
        source = framebuffer
        if let inFlight = lastCommandBuffer {
            inFlight.waitUntilCompleted()
            lastCommandBuffer = nil
        }
        framebuffer.withPixels { (buffer: UnsafeRawBufferPointer, width: Int, height: Int) -> Void in
            guard width > 0, height > 0, width <= 16384, height <= 16384, let base = buffer.baseAddress else { return }
            var full: Bool = switched
            if texture == nil || textureWidth != width || textureHeight != height {
                let td: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
                td.usage = [.shaderRead, .renderTarget]
                td.storageMode = .shared
                guard let t = device.makeTexture(descriptor: td) else { return }
                texture = t
                textureWidth = width
                textureHeight = height
                full = true
            }
            guard let t = texture else { return }
            let bytesPerRow: Int = width * 4
            let list: [RFBRect] = full ? [RFBRect(x: 0, y: 0, width: width, height: height)] : rects
            for r in list {
                let x0: Int = max(0, r.x)
                let y0: Int = max(0, r.y)
                let x1: Int = min(width, r.x + r.width)
                let y1: Int = min(height, r.y + r.height)
                guard x1 > x0, y1 > y0 else { continue }
                let region: MTLRegion = MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0)
                let start: UnsafeRawPointer = base.advanced(by: (y0 * width + x0) * 4)
                t.replace(region: region, mipmapLevel: 0, withBytes: start, bytesPerRow: bytesPerRow)
            }
            mipmapsDirty = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        if mipmapsDirty, let t = texture, t.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            mipmapsDirty = false
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        if let t = texture, let vp = viewport, vp.isValid, vp.scale > 0 {
            var uniforms: FramebufferUniforms = FramebufferUniforms(
                viewSize: SIMD2<Float>(Float(vp.viewSize.width), Float(vp.viewSize.height)),
                origin: SIMD2<Float>(Float(vp.offset.x), Float(vp.offset.y)),
                size: SIMD2<Float>(Float(vp.remoteSize.width * vp.scale), Float(vp.remoteSize.height * vp.scale)))
            // Crisp pixels once a remote pixel covers 3+ device pixels; smooth below that.
            let devicePixelsPerRemotePixel: CGFloat = vp.scale * view.contentScaleFactor
            let sampler: MTLSamplerState = devicePixelsPerRemotePixel >= 3 ? pixelSampler : smoothSampler
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FramebufferUniforms>.stride, index: 0)
            encoder.setFragmentTexture(t, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
    }
}
