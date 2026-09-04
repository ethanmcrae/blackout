import Foundation
import Metal
import QuartzCore
import CoreGraphics

// MARK: - GPU Types

/// Must match `Uniforms` in the shader source below.
struct IsometricUniforms {
    var viewportPx: SIMD2<Float>
    var scale: Float
    var halfWidth: Float
    var accent: SIMD4<Float>
}

// MARK: - Shader

/// Compiled at runtime with `makeLibrary(source:)`. This keeps the whole
/// project buildable with plain `swiftc` — no .metal file, no metallib step,
/// no dependency on a full Xcode install.
private let isometricShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Instance {
    uint  edge;
    float lit;
    float t0;
    float t1;
};

struct Uniforms {
    float2 viewportPx;
    float  scale;
    float  halfWidth;
    float4 accent;
};

struct VOut {
    float4 position [[position]];
    float  u;        // distance along the segment, in pixels, from its start
    float  v;        // perpendicular distance from the centre line, in pixels
    float  segLen;   // segment length in pixels
    float  lit;
    float  wPerp;    // half-width of the anti-aliasing ramp across the line
    float  wLong;    // half-width of the anti-aliasing ramp at the butt caps
};

vertex VOut iso_vertex(uint vid                       [[vertex_id]],
                       uint iid                       [[instance_id]],
                       const device Instance *insts   [[buffer(0)]],
                       const device float4   *edges   [[buffer(1)]],
                       constant Uniforms     &uni     [[buffer(2)]])
{
    Instance inst = insts[iid];
    float4 e = edges[inst.edge];

    // Points -> pixels.
    float2 A = e.xy * uni.scale;
    float2 B = e.zw * uni.scale;

    float2 d = B - A;
    float  L = length(d);
    float2 dir = (L > 1e-6) ? (d / L) : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);

    float2 P0 = A + d * inst.t0;
    float2 P1 = A + d * inst.t1;
    float  segLen = L * max(inst.t1 - inst.t0, 0.0);

    // 1px skirt on every side so the fragment shader can compute coverage.
    const float ext = 1.0;
    float along = (vid & 2) ? 1.0 : 0.0;
    float perp  = (vid & 1) ? 1.0 : -1.0;

    float2 base = mix(P0, P1, along);
    float  lon  = (along < 0.5) ? -ext : (segLen + ext);
    float  lat  = perp * (uni.halfWidth + ext);

    float2 px = base + dir * ((along < 0.5) ? -ext : ext) + nrm * lat;

    // Box-filter footprint of one pixel projected onto each axis of the
    // segment's own frame. For an axis-aligned line this is 0.5; for a 30-degree
    // isometric edge it is ~0.683, which is why a fixed 0.5 made diagonals
    // visibly thinner than CoreGraphics draws them.
    float wPerp = (abs(nrm.x) + abs(nrm.y)) * 0.5;
    float wLong = (abs(dir.x) + abs(dir.y)) * 0.5;

    VOut out;
    out.position = float4((px.x / uni.viewportPx.x) * 2.0 - 1.0,
                          (px.y / uni.viewportPx.y) * 2.0 - 1.0,
                          0.0, 1.0);
    out.u      = lon;
    out.v      = lat;
    out.segLen = segLen;
    out.lit    = inst.lit;
    out.wPerp  = wPerp;
    out.wLong  = wLong;
    return out;
}

fragment float4 iso_fragment(VOut in [[stage_in]],
                             constant Uniforms &uni [[buffer(0)]])
{
    // Analytic coverage, with the ramp width matched to the line's angle so
    // total ink matches an exact-area rasteriser.
    float across = clamp(uni.halfWidth + 0.5 - abs(in.v), 0.0, 1.0);
    float along  = clamp(min(in.u, in.segLen - in.u) + 0.5, 0.0, 1.0);
    float cov = across * along;
    if (cov <= 0.0) { discard_fragment(); }
    return float4(uni.accent.rgb, in.lit * cov);
}
"""

// MARK: - Renderer

/// GPU renderer for the isometric grid. Every lit segment is one instance of a
/// 4-vertex triangle strip; the whole frame is a single draw call.
final class IsometricMetalRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private var edgeBuffer: MTLBuffer?
    private var edgeCount: Int = 0
    private var generation: Int = -1

    /// Rotating instance buffers so the CPU never writes a buffer the GPU is reading.
    private static let bufferCount = 3
    private var instanceBuffers: [MTLBuffer?] = Array(repeating: nil, count: bufferCount)
    private var instanceCapacity: [Int] = Array(repeating: 0, count: bufferCount)
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: bufferCount)

    var name: String { "Metal (\(device.name))" }

    // MARK: Init

    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q

        do {
            let library = try dev.makeLibrary(source: isometricShaderSource, options: nil)
            guard let vfn = library.makeFunction(name: "iso_vertex"),
                  let ffn = library.makeFunction(name: "iso_fragment") else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("IsometricMetalRenderer: pipeline setup failed: \(error)")
            return nil
        }
    }

    // MARK: Geometry

    func setGeometry(_ endpoints: [SIMD4<Float>], generation newGeneration: Int) {
        guard newGeneration != generation else { return }
        generation = newGeneration
        edgeCount = endpoints.count
        guard !endpoints.isEmpty else { edgeBuffer = nil; return }
        edgeBuffer = endpoints.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    // MARK: Encoding

    private func uniforms(_ params: IsometricRenderParams) -> IsometricUniforms {
        IsometricUniforms(
            viewportPx: SIMD2<Float>(Float(params.size.width * params.scale),
                                     Float(params.size.height * params.scale)),
            scale: Float(params.scale),
            halfWidth: Float(params.lineWidth * params.scale / 2.0),
            accent: SIMD4<Float>(Float(params.accentR), Float(params.accentG),
                                 Float(params.accentB), 1.0)
        )
    }

    private func instanceBuffer(for count: Int) -> MTLBuffer? {
        let idx = bufferIndex
        if instanceCapacity[idx] < count || instanceBuffers[idx] == nil {
            let capacity = max(count, 4096)
            instanceBuffers[idx] = device.makeBuffer(
                length: capacity * MemoryLayout<IsometricInstance>.stride,
                options: .storageModeShared)
            instanceCapacity[idx] = capacity
        }
        return instanceBuffers[idx]
    }

    private func clearColor(_ params: IsometricRenderParams) -> MTLClearColor {
        params.lightMode ? MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
                         : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    /// Encode one frame into an existing render pass. Sets up load/clear itself.
    private func encode(frame: IsometricFrame,
                        params: IsometricRenderParams,
                        texture: MTLTexture,
                        commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor(params)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let count = frame.instances.count
        if count > 0, let edges = edgeBuffer, let instBuf = instanceBuffer(for: count) {
            frame.instances.withUnsafeBytes { raw in
                instBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            var uni = uniforms(params)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(instBuf, offset: 0, index: 0)
            encoder.setVertexBuffer(edges, offset: 0, index: 1)
            encoder.setVertexBytes(&uni, length: MemoryLayout<IsometricUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uni, length: MemoryLayout<IsometricUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
    }

    // MARK: Live presentation

    /// Render straight into a CAMetalLayer's next drawable.
    func render(frame: IsometricFrame, params: IsometricRenderParams, layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        inFlight.wait()
        bufferIndex = (bufferIndex + 1) % Self.bufferCount
        encode(frame: frame, params: params, texture: drawable.texture, commandBuffer: commandBuffer)

        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Offscreen (verification harness)

    private var offscreenTexture: MTLTexture?

    /// Encode and commit one frame to an offscreen texture without waiting for
    /// the GPU or reading anything back. This is the CPU-side cost the live
    /// path actually pays each frame; `renderOffscreen` adds a full stall and a
    /// framebuffer copy on top and is only for verification.
    func encodeOnlyForBenchmark(frame: IsometricFrame, params: IsometricRenderParams) {
        let w = Int((params.size.width * params.scale).rounded())
        let h = Int((params.size.height * params.scale).rounded())
        guard w > 0, h > 0 else { return }
        if offscreenTexture?.width != w || offscreenTexture?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = device.hasUnifiedMemory ? .shared : .managed
            offscreenTexture = device.makeTexture(descriptor: td)
        }
        guard let texture = offscreenTexture,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        inFlight.wait()
        bufferIndex = (bufferIndex + 1) % Self.bufferCount
        encode(frame: frame, params: params, texture: texture, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commandBuffer.commit()
    }

    /// Render one frame to an offscreen texture and read it back as a CGImage.
    /// Used by Harness/ to diff GPU output against the Core Graphics reference.
    func renderOffscreen(frame: IsometricFrame, params: IsometricRenderParams) -> CGImage? {
        let w = Int((params.size.width * params.scale).rounded())
        let h = Int((params.size.height * params.scale).rounded())
        guard w > 0, h > 0 else { return nil }

        if offscreenTexture?.width != w || offscreenTexture?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = device.hasUnifiedMemory ? .shared : .managed
            offscreenTexture = device.makeTexture(descriptor: td)
        }
        guard let texture = offscreenTexture,
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        bufferIndex = (bufferIndex + 1) % Self.bufferCount
        encode(frame: frame, params: params, texture: texture, commandBuffer: commandBuffer)

        if !device.hasUnifiedMemory, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = w * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * h)
        bgra.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        // No row flip: the vertex shader maps y-up points straight to clip space,
        // so texture row 0 is already the top row -- the same order a
        // CGBitmapContext stores its rows in.
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue:
                           CGImageAlphaInfo.premultipliedFirst.rawValue |
                           CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
