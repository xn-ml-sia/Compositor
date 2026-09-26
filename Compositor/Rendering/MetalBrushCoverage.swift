import AppKit
import Metal

/// Shared pipeline, with stroke-local tile storage. No full-canvas GPU allocation.
final class MetalBrushCoverage {
    static let shared: MetalBrushCoverage? = try? MetalBrushCoverage()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// Nil when the natural-media kernel failed to compile. The continuous brush does not depend on it.
    private let naturalPipeline: MTLComputePipelineState?
    private let shadePipeline: MTLComputePipelineState?
    private let rimPipeline: MTLComputePipelineState?
    var supportsNaturalDabs: Bool { naturalPipeline != nil }

    struct Tile {
        let permanent: MTLBuffer
        let preview: MTLBuffer
    }
    private struct Uniforms {
        var mapping: SIMD4<Float>
        var geometry: SIMD4<Float>
        var canvas: SIMD4<Float>
        var counts: SIMD4<UInt32>
    }
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "continuousBrush") else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
        naturalPipeline = Self.makeNaturalPipeline(device: device)
        shadePipeline = Self.makeFunctionPipeline(device: device, name: "shadeBrush")
        rimPipeline = Self.makeFunctionPipeline(device: device, name: "shadeFillRim")
    }
    func tile(width: Int, height: Int) throws -> Tile {
        guard let permanent = device.makeBuffer(length: width * height * MemoryLayout<Float>.stride, options: .storageModeShared),
              let preview = device.makeBuffer(length: width * height, options: .storageModeShared) else { throw ExportError.render }
        memset(permanent.contents(), 0, width * height * MemoryLayout<Float>.stride)
        return Tile(permanent: permanent, preview: preview)
    }
    func render(_ tiles: [(Tile, CGRect, CGContext)], settled: [SIMD4<Float>], tail: [SIMD4<Float>],
                mapping: CGAffineTransform, settings: BrushSettings, canvas: CGSize) throws {
        guard !tiles.isEmpty else { return }
        // A dummy segment supplies a valid buffer for tail removal with no new geometry.
        let segments = settled + tail
        let storage = segments.isEmpty ? [SIMD4<Float>(repeating: 0)] : segments
        guard let buffer = storage.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }), let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 3)
        for (tile, rect, _) in tiles {
            let origin = rect.origin.applying(mapping)
            var uniforms = Uniforms(
                mapping: SIMD4(Float(mapping.a), Float(mapping.b), Float(mapping.c), Float(mapping.d)),
                geometry: SIMD4(Float(origin.x), Float(origin.y), Float(settings.diameter / 2), Float(settings.hardness)),
                canvas: SIMD4(Float(canvas.width), Float(canvas.height), Float(max(0.001, min(hypot(mapping.a, mapping.b), hypot(mapping.c, mapping.d)))), Float(max(0.25, settings.diameter * BrushStroke.spacingFraction(settings.hardness)))),
                counts: SIMD4(UInt32(rect.width), UInt32(rect.height), UInt32(settled.count), UInt32(segments.count)))
            encoder.setBuffer(tile.permanent, offset: 0, index: 0)
            encoder.setBuffer(tile.preview, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ExportError.render }
        for (tile, rect, context) in tiles {
            // CGContext owns its memory so makeImage's copy-on-write snapshots stay immutable.
            guard let destination = context.data else { throw ExportError.render }
            memcpy(destination, tile.preview.contents(), Int(rect.width * rect.height))
        }
    }

    /// Stamps natural-media dabs into the same permanent/preview split as `render`.
    /// Settled dabs fold into permanent once. Tail dabs are preview only, so replacing
    /// a tail cannot leave the previous tail behind or count it twice.
    func renderDabs(_ batches: [(Tile, CGRect, CGContext, [NaturalDab], [NaturalDab])], mapping: CGAffineTransform, hardness: CGFloat, canvas: CGSize) throws {
        guard !batches.isEmpty else { return }
        guard let naturalPipeline else { throw ExportError.render }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        encoder.setComputePipelineState(naturalPipeline)
        // Held until the command buffer finishes. Releasing a dab buffer at the end of the loop
        // would let the GPU read freed memory.
        var dabBuffers: [MTLBuffer] = []
        for (tile, rect, _, settled, tail) in batches {
            let combined = settled + tail
            let storage = combined.isEmpty ? [NaturalDab(x: 0, y: 0, radius: 0, alpha: 0)] : combined
            guard let buffer = storage.withUnsafeBytes({ bytes -> MTLBuffer? in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }) else { throw ExportError.render }
            dabBuffers.append(buffer)
            let origin = rect.origin.applying(mapping)
            var uniforms = Uniforms(
                mapping: SIMD4(Float(mapping.a), Float(mapping.b), Float(mapping.c), Float(mapping.d)),
                geometry: SIMD4(Float(origin.x), Float(origin.y), Float(hardness), 0),
                canvas: SIMD4(Float(canvas.width), Float(canvas.height), 0, 0),
                counts: SIMD4(UInt32(rect.width), UInt32(rect.height), UInt32(settled.count), UInt32(combined.count)))
            encoder.setBuffer(tile.permanent, offset: 0, index: 0)
            encoder.setBuffer(tile.preview, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setBuffer(buffer, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        // The dab buffers have to outlive the command buffer. The last formal use is the encode loop.
        _ = dabBuffers
        guard command.status == .completed else { throw command.error ?? ExportError.render }
        for (tile, rect, context, _, _) in batches {
            guard let destination = context.data else { throw ExportError.render }
            copyCoverage(from: tile.preview.contents(), to: destination, width: Int(rect.width), height: Int(rect.height), bytesPerRow: context.bytesPerRow)
        }
    }

    /// Compiled apart from the continuous brush, so a mistake here cannot turn that pipeline off.
    private static func makeNaturalPipeline(device: MTLDevice) -> MTLComputePipelineState? {
        makeFunctionPipeline(device: device, name: "naturalBrush")
    }

    private static func makeFunctionPipeline(device: MTLDevice, name: String) -> MTLComputePipelineState? {
        guard let library = try? device.makeLibrary(source: naturalSource, options: nil),
              let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    /// GPU twin of `NaturalShade.cpuBrush`. Nil sends the caller to the CPU walk.
    func shadeBrush(coverage: CGContext, red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat) -> CGImage? {
        guard let shadePipeline, let source = coverage.data else { return nil }
        let width = coverage.width, height = coverage.height
        guard width > 0, height > 0 else { return nil }
        let tight = packed(source, width: width, height: height, bytesPerRow: coverage.bytesPerRow, pixel: 1)
        guard let bytes = shade(pipeline: shadePipeline, bytes: tight, width: width, height: height,
                                color: SIMD4(Float(red), Float(green), Float(blue), Float(opacity))) else { return nil }
        return image(bytes, width: width, height: height)
    }

    /// GPU twin of `NaturalShade.cpuDarkenRims`. False leaves the buffer for the CPU walk.
    func darkenFillRims(in context: CGContext) -> Bool {
        guard let rimPipeline, context.bitsPerPixel >= 32, let source = context.data else { return false }
        let width = context.width, height = context.height
        guard width > 1, height > 1 else { return false }
        let tight = packed(source, width: width, height: height, bytesPerRow: context.bytesPerRow, pixel: 4)
        guard let bytes = shade(pipeline: rimPipeline, bytes: tight, width: width, height: height, color: SIMD4(repeating: 0)) else { return false }
        let destination = source.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        let row = context.bytesPerRow
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for y in 0..<height {
                memcpy(destination.advanced(by: y * row), base.advanced(by: y * width * 4), width * 4)
            }
        }
        return true
    }

    private func packed(_ source: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, pixel: Int) -> [UInt8] {
        let tight = width * pixel
        if bytesPerRow == tight {
            return Array(UnsafeBufferPointer(start: source.bindMemory(to: UInt8.self, capacity: tight * height), count: tight * height))
        }
        var bytes = [UInt8](repeating: 0, count: tight * height)
        let raw = source.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<(tight) { bytes[y * tight + x] = raw[y * bytesPerRow + x] }
        }
        return bytes
    }

    private func shade(pipeline: MTLComputePipelineState, bytes: [UInt8], width: Int, height: Int, color: SIMD4<Float>) -> [UInt8]? {
        let outLength = width * height * 4
        guard !bytes.isEmpty, let input = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let output = device.makeBuffer(length: outLength, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
        var uniforms = ShadeUniforms(color: color, size: SIMD4(UInt32(width), UInt32(height), 0, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<ShadeUniforms>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let pointer = output.contents().bindMemory(to: UInt8.self, capacity: outLength)
        return Array(UnsafeBufferPointer(start: pointer, count: outLength))
    }

    private func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let image = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let destination = image.data else { return nil }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(destination, base, width * height * 4) }
        }
        return image.makeImage()
    }

    private struct ShadeUniforms {
        var color: SIMD4<Float>
        var size: SIMD4<UInt32>
    }

    /// The continuous kernel writes a packed buffer and the context row stride matches it.
    /// Natural dabs use the same packing when the stride is tight, and honor a padded row otherwise.
    private func copyCoverage(from source: UnsafeMutableRawPointer, to destination: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        if bytesPerRow == width {
            memcpy(destination, source, width * height)
            return
        }
        for y in 0..<height {
            memcpy(destination.advanced(by: y * bytesPerRow), source.advanced(by: y * width), width)
        }
    }

    // Compile once with the system Metal compiler; no optional Xcode Metal toolchain required.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct BrushUniforms {
    float4 mapping; // a, b, c, d
    float4 geometry; // document origin of tile, radius, hardness
    float4 canvas; // width, height, antialias width, deposition spacing
    uint4 counts; // tile width, height, committed segment count, total segment count
};

float segmentDistanceSquared(float2 p, float4 segment) {
    float2 v = segment.zw - segment.xy;
    float t = clamp(dot(p - segment.xy, v) / max(dot(v, v), 1e-12f), 0.0f, 1.0f);
    float2 delta = p - (segment.xy + t * v);
    return dot(delta, delta);
}

float brushCoverage(float distanceSquared, constant BrushUniforms &u) {
    float distance = sqrt(distanceSquared);
    float radius = u.geometry.z;
    if (u.geometry.w >= 1.0f) {
        return clamp((radius - distance) / u.canvas.z + 0.5f, 0.0f, 1.0f);
    }
    float t = clamp((distance / radius - u.geometry.w) / (1.0f - u.geometry.w), 0.0f, 1.0f);
    return max(0.0f, (exp(-2.5f * t * t) - exp(-2.5f)) / (1.0f - exp(-2.5f)));
}

// Integrate paint deposition by distance travelled, not pointer-event count or
// spline subdivision count. Optical density adds; coverage is 1 - exp(-density).
// This is the continuous form of source-over soft dabs at the shared deposition spacing.
float tipDensity(float distanceSquared, constant BrushUniforms &u) {
    return -log(max(1.0f - brushCoverage(distanceSquared, u), 0.001f));
}

float segmentDensity(float2 p, float4 segment, constant BrushUniforms &u) {
    float2 v = segment.zw - segment.xy;
    float length = metal::length(v);
    if (length < 1e-6f) return tipDensity(dot(p - segment.xy, p - segment.xy), u); // initial click
    float2 direction = v / length;
    float projection = dot(p - segment.xy, direction);
    float2 perpendicular = p - segment.xy - projection * direction;
    float perpendicularSquared = dot(perpendicular, perpendicular);
    float radiusSquared = u.geometry.z * u.geometry.z;
    if (perpendicularSquared >= radiusSquared) return 0.0f;
    float reach = sqrt(radiusSquared - perpendicularSquared);
    float lo = max(0.0f, projection - reach), hi = min(length, projection + reach);
    if (hi <= lo) return 0.0f;
    float midpoint = (lo + hi) * 0.5f, halfLength = (hi - lo) * 0.5f;
    // Eight-point Gauss-Legendre quadrature, clipped to the tip's support.
    // Long sparse events and short dense events produce the same paint coverage.
    constexpr float nodes[4] = {0.1834346425f, 0.5255324099f, 0.7966664774f, 0.9602898565f};
    constexpr float weights[4] = {0.3626837834f, 0.3137066459f, 0.2223810345f, 0.1012285363f};
    float integral = 0.0f;
    for (uint i = 0; i < 4; ++i) {
        float a = midpoint - halfLength * nodes[i] - projection;
        float b = midpoint + halfLength * nodes[i] - projection;
        integral += weights[i] * (tipDensity(perpendicularSquared + a * a, u)
                                + tipDensity(perpendicularSquared + b * b, u));
    }
    return integral * halfLength / u.canvas.w;
}

// Permanent paint and the replaceable tail are separate. Tail previews are never
// accumulated into permanent paint, including at self-intersections.
kernel void continuousBrush(device float *permanent [[buffer(0)]],
                            device uchar *preview [[buffer(1)]],
                            constant BrushUniforms &u [[buffer(2)]],
                            device const float4 *segments [[buffer(3)]],
                            uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.counts.x || pixel.y >= u.counts.y) return;
    uint index = pixel.y * u.counts.x + pixel.x;
    float2 local = float2(pixel) + 0.5f;
    float2 p = u.geometry.xy + local.x * u.mapping.xy + local.y * u.mapping.zw;
    if (any(p < 0.0f) || any(p >= u.canvas.xy)) { preview[index] = 0; return; }
    if (u.geometry.w >= 1.0f) {
        // Hard tips already have a solid interior. Preserve pixel-edge antialiasing.
        float settled = INFINITY, tail = INFINITY;
        for (uint i = 0; i < u.counts.z; ++i) settled = min(settled, segmentDistanceSquared(p, segments[i]));
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail = min(tail, segmentDistanceSquared(p, segments[i]));
        float value = max(permanent[index], brushCoverage(settled, u));
        permanent[index] = value;
        preview[index] = uchar(round(255.0f * max(value, brushCoverage(tail, u))));
    } else {
        float value = permanent[index], tail = 0.0f;
        for (uint i = 0; i < u.counts.z; ++i) value += segmentDensity(p, segments[i], u);
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail += segmentDensity(p, segments[i], u);
        permanent[index] = min(value, 20.0f);
        preview[index] = uchar(round(255.0f * (1.0f - exp(-min(value + tail, 20.0f)))));
    }
}
"""

    /// Separate library from `source`. geometry.z is hardness here; in the continuous kernel it is radius.
    private static let naturalSource = """
#include <metal_stdlib>
using namespace metal;

struct BrushUniforms {
    float4 mapping; // a, b, c, d
    float4 geometry; // document origin of tile, hardness, unused
    float4 canvas; // width, height
    uint4 counts; // tile width, height, settled dab count, settled plus tail
};

// Natural-media dabs. Must match NaturalCoverage.stamp: source-over of a hard
// antialiased disc (p5.brush's point shader), or a Gaussian when hardness is below 1.
// geometry.z is hardness. dabs are (x, y, radius, alpha) in document points.
// counts.z is the settled prefix, which is folded into permanent exactly once.
float naturalDisc(float distance, float radius) {
    float t = saturate((distance - (radius - 0.75f)) / 1.5f);
    return 1.0f - t * t * (3.0f - 2.0f * t);
}

float naturalMask(float distance, float radius, float hardness) {
    if (radius <= 0.0f) return 0.0f;
    float hard = naturalDisc(distance, radius);
    if (hardness >= 1.0f) return hard;
    float u = saturate(distance / radius);
    float feather = max(0.0f, (exp(-2.5f * u * u) - exp(-2.5f)) / (1.0f - exp(-2.5f)));
    return mix(feather, hard, saturate(hardness));
}

float naturalOver(float dst, float2 p, float4 dab, float hardness) {
    float src = dab.w * naturalMask(length(p - dab.xy), dab.z, hardness);
    return dst + src * (1.0f - dst);
}

kernel void naturalBrush(device float *permanent [[buffer(0)]],
                         device uchar *preview [[buffer(1)]],
                         constant BrushUniforms &u [[buffer(2)]],
                         device const float4 *dabs [[buffer(3)]],
                         uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.counts.x || pixel.y >= u.counts.y) return;
    uint index = pixel.y * u.counts.x + pixel.x;
    float2 local = float2(pixel) + 0.5f;
    float2 p = u.geometry.xy + local.x * u.mapping.xy + local.y * u.mapping.zw;
    if (any(p < 0.0f) || any(p >= u.canvas.xy)) { preview[index] = 0; return; }
    float value = permanent[index];
    for (uint i = 0; i < u.counts.z; ++i) value = naturalOver(value, p, dabs[i], u.geometry.z);
    value = min(value, 1.0f);
    permanent[index] = value;
    float shown = value;
    for (uint i = u.counts.z; i < u.counts.w; ++i) shown = naturalOver(shown, p, dabs[i], u.geometry.z);
    preview[index] = uchar(round(255.0f * saturate(shown)));
}

// Colouring pass from p5.brush shader.frag. Brush: darken pigment where coverage exceeds 0.7.
// Fill: raise and darken the rim where the scaled alpha gradient is steep. No spectral mix.
struct ShadeUniforms {
    float4 color;
    uint4 size; // width, height, bytes per pixel, unused
};

float shadeStep(float edge0, float edge1, float value) {
    float t = saturate((value - edge0) / (edge1 - edge0));
    return t * t * (3.0f - 2.0f * t);
}

float3 shadePigment(float3 color, float alpha) {
    if (alpha > 0.7f) {
        float blacken = 0.5f * (min(alpha, 1.0f) - 0.7f);
        return max(color * (1.0f - blacken) - 0.5f * blacken, float3(0.0f));
    }
    return color;
}

kernel void shadeBrush(device const uchar *coverage [[buffer(0)]],
                       device uchar4 *out [[buffer(1)]],
                       constant ShadeUniforms &u [[buffer(2)]],
                       uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.size.x || pixel.y >= u.size.y) return;
    uint index = pixel.y * u.size.x + pixel.x;
    float alpha = float(coverage[index]) / 255.0f;
    float3 pigment = shadePigment(u.color.rgb, alpha);
    float paint = min(alpha, 1.0f) * saturate(u.color.a);
    out[index] = uchar4(uchar(round(255.0f * pigment.r * paint)),
                        uchar(round(255.0f * pigment.g * paint)),
                        uchar(round(255.0f * pigment.b * paint)),
                        uchar(round(255.0f * paint)));
}

kernel void shadeFillRim(device const uchar4 *source [[buffer(0)]],
                         device uchar4 *out [[buffer(1)]],
                         constant ShadeUniforms &u [[buffer(2)]],
                         uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.size.x || pixel.y >= u.size.y) return;
    int width = int(u.size.x), height = int(u.size.y);
    uint index = pixel.y * u.size.x + pixel.x;
    float coverage = float(source[index].a) / 255.0f;
    if (coverage <= 0.0f) { out[index] = source[index]; return; }
    float blur = 0.0f;
    for (int oy = -2; oy <= 2; oy += 2) {
        for (int ox = -2; ox <= 2; ox += 2) {
            int nx = clamp(int(pixel.x) + ox, 0, width - 1);
            int ny = clamp(int(pixel.y) + oy, 0, height - 1);
            int lx = clamp(nx - 1, 0, width - 1), rx = clamp(nx + 1, 0, width - 1);
            int uy = clamp(ny - 1, 0, height - 1), dy = clamp(ny + 1, 0, height - 1);
            float dx = (float(source[ny * width + rx].a) - float(source[ny * width + lx].a)) / 255.0f * 15.0f;
            float dyv = (float(source[dy * width + nx].a) - float(source[uy * width + nx].a)) / 255.0f * 15.0f;
            blur += shadeStep(0.05f, 0.35f, length(float2(dx, dyv)));
        }
    }
    blur /= 9.0f;
    float paint = min(1.0f, coverage + blur * 0.1f);
    float dark = 1.0f - 0.45f * blur;
    float scale = coverage > 0.0f ? paint / coverage * dark : 0.0f;
    uchar4 pixelIn = source[index];
    out[index] = uchar4(uchar(round(float(pixelIn.r) * scale)),
                        uchar(round(float(pixelIn.g) * scale)),
                        uchar(round(float(pixelIn.b) * scale)),
                        uchar(round(255.0f * paint)));
}
"""
}
