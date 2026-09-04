import Foundation
import MazzyCore
import AppKit
import Metal

/// Owns the window + CAMetalLayer and presents decoded frames.
/// Zero-copy: CVPixelBuffer IOSurfaces are sampled directly by the shader.
final class MetalRenderer {
    let device: MTLDevice
    private let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    // YUV -> RGB conversion done in shader from two planes (NV12)
    private var texLuma: MTLTexture?
    private var texChroma: MTLTexture?

    // current frame (retained so IOSurface stays alive while GPU reads it)
    private var currentPixelBuffer: CVPixelBuffer?
    private let uiQueue = DispatchQueue.main

    // stats for HUD
    var hudLines: (() -> [String])?

    init?(config: ReceiverConfig) {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        device = dev
        queue = dev.makeCommandQueue()!
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        _ = config.upscale // MetalFX spatial/temporal hooks land in the next change
        buildPipeline()
        makeWindow()
    }

    private func buildPipeline() {
        let lib: MTLLibrary
        do { lib = try device.makeDefaultLibrary()! }
        catch { fatalError("shader library missing: \(error)") }
        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float2
        vdesc.attributes[0].offset = 0
        vdesc.attributes[0].bufferIndex = 0
        vdesc.layouts[0].stride = MemoryLayout<Float>.stride * 4
        vdesc.layouts[0].stepFunction = .perVertex
        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
        pdesc.fragmentFunction = lib.makeFunction(name: "yuv_fragment")
        pdesc.vertexDescriptor = vdesc
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sdesc)
        pipeline = try? device.makeRenderPipelineState(descriptor: pdesc)
    }

    private func makeWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "MazzyReceiver"
        win.contentView?.wantsLayer = true
        win.contentView?.layer = layer
        win.makeKeyAndOrderFront(nil)
        win.center()
        app.activate(ignoringOtherApps: true)
    }

    /// Upload a decoded frame and render it. Called from the decode callback.
    func present(frame: CVPixelBuffer) {
        currentPixelBuffer = frame
        render()
    }

    private var textureCache: CVMetalTextureCache?

    private func render() {
        guard let buf = currentPixelBuffer else { return }
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)

        func makeTex(_ plane: Int, format: MTLPixelFormat) -> MTLTexture? {
            var tex: CVMetalTexture?
            let st = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buf, nil, format,
                w >> (plane == 0 ? 0 : 1), h >> (plane == 0 ? 0 : 1), plane, &tex)
            guard st == kCVReturnSuccess else { return nil }
            return CVMetalTextureGetTexture(tex!)
        }
        guard let luma = makeTex(0, format: .r8Unorm),
              let chroma = makeTex(1, format: .rg8Unorm) else { return }

        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer(),
              let pipe = pipeline else { return }

        let pdesc = MTLRenderPassDescriptor()
        pdesc.colorAttachments[0].texture = drawable.texture
        pdesc.colorAttachments[0].loadAction = .clear
        pdesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pdesc) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
