import AppKit

// Final colouring pass from p5.brush `src/core/gl/shader.frag` (the block after the spectral mixer).
// Dense brush coverage (mask alpha above 0.7) darkens the pigment. A watercolor mask picks up a
// darker rim where the alpha gradient is steep. There is no spectral mix: the result is ordinary
// source-over on the coverage that is already in the tile.

enum NaturalShade {
    /// Brush pigment after the density darken, and the alpha it should be painted at.
    /// `alpha` and the returned alpha are 0…1. Opacity is the stroke cap.
    static func brushPigment(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, opacity: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let coverage = min(1, max(0, alpha))
        var channels = (red, green, blue)
        if coverage > 0.7 {
            let blacken = 0.5 * (min(coverage, 1) - 0.7)
            channels.0 = max(0, channels.0 * (1 - blacken) - 0.5 * blacken)
            channels.1 = max(0, channels.1 * (1 - blacken) - 0.5 * blacken)
            channels.2 = max(0, channels.2 * (1 - blacken) - 0.5 * blacken)
        }
        let paint = min(coverage, 1) * min(1, max(0, opacity))
        return (channels.0, channels.1, channels.2, paint)
    }

    /// Premultiplied image of a grayscale coverage buffer, darkened where the mask is dense.
    /// Metal does this when the natural kernel compiled; otherwise the CPU walks the bytes.
    static func brushImage(from coverage: CGContext, red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat) -> CGImage? {
        if let image = MetalBrushCoverage.shared?.shadeBrush(coverage: coverage, red: red, green: green, blue: blue, opacity: opacity) {
            return image
        }
        return cpuBrush(coverage: coverage, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// Edge darkening for a watercolor buffer. Flat interiors stay put; a steep alpha edge gets a darker, slightly heavier rim.
    static func darkenRims(in context: CGContext) {
        guard context.bitsPerPixel >= 32 else { return }
        if MetalBrushCoverage.shared?.darkenFillRims(in: context) == true { return }
        cpuDarkenRims(in: context)
    }

    static func cpuBrush(coverage: CGContext, red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat) -> CGImage? {
        let width = coverage.width, height = coverage.height
        guard width > 0, height > 0, let source = coverage.data else { return nil }
        guard let image = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let destination = image.data else { return nil }
        let src = source.bindMemory(to: UInt8.self, capacity: coverage.bytesPerRow * height)
        let dst = destination.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sample = CGFloat(src[y * coverage.bytesPerRow + x]) / 255
                let pigment = brushPigment(red: red, green: green, blue: blue, alpha: sample, opacity: opacity)
                let index = (y * width + x) * 4
                dst[index] = byte(pigment.red * pigment.alpha)
                dst[index + 1] = byte(pigment.green * pigment.alpha)
                dst[index + 2] = byte(pigment.blue * pigment.alpha)
                dst[index + 3] = byte(pigment.alpha)
            }
        }
        return image.makeImage()
    }

    static func cpuDarkenRims(in context: CGContext) {
        let width = context.width, height = context.height, row = context.bytesPerRow
        guard width > 1, height > 1, let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: row * height)
        var alpha = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                alpha[y * width + x] = Float(pixels[y * row + x * 4 + 3]) / 255
            }
        }
        func sample(_ x: Int, _ y: Int) -> Float {
            let cx = min(width - 1, max(0, x))
            let cy = min(height - 1, max(0, y))
            return alpha[cy * width + cx]
        }
        for y in 0..<height {
            for x in 0..<width {
                let coverage = alpha[y * width + x]
                guard coverage > 0 else { continue }
                var blur: Float = 0
                var oy = -2
                while oy <= 2 {
                    var ox = -2
                    while ox <= 2 {
                        let nx = x + ox, ny = y + oy
                        let dx = sample(nx + 1, ny) * 15 - sample(nx - 1, ny) * 15
                        let dy = sample(nx, ny + 1) * 15 - sample(nx, ny - 1) * 15
                        blur += smoothstep(0.05, 0.35, hypot(dx, dy))
                        ox += 2
                    }
                    oy += 2
                }
                blur /= 9
                guard blur > 0 else { continue }
                let index = y * row + x * 4
                let paint = min(1, coverage + blur * 0.1)
                let dark = 1 - 0.45 * blur
                let scale = paint / coverage * dark
                pixels[index] = byte(CGFloat(pixels[index]) / 255 * CGFloat(scale))
                pixels[index + 1] = byte(CGFloat(pixels[index + 1]) / 255 * CGFloat(scale))
                pixels[index + 2] = byte(CGFloat(pixels[index + 2]) / 255 * CGFloat(scale))
                pixels[index + 3] = byte(CGFloat(paint))
            }
        }
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int((min(1, max(0, value)) * 255).rounded()))
    }
}
