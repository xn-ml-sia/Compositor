import AppKit

// Watercolor fill ported from p5.brush `src/fill/fill.js` (MIT, Alejandro Campos Uribe),
// which follows Tyler Hobbs, "A Generative Approach to Simulating Watercolor Paints"
// (https://tylerxhobbs.com/essays/2017/a-generative-approach-to-simulating-watercolor-paints).
// A polygon grows, gets trimmed, and is redrawn in translucent layers; destination-out
// circles lift pigment the way the original erase step does. Layers composite with
// ordinary source-over so a transparent layer stays transparent — no spectral mixing.

/// Remembered settings for Edit > Watercolor Fill Selection, and the extra fields on a watercolor op.
struct WatercolorOptions: Equatable, Sendable {
    var bleed: CGFloat = 0.07
    var texture: CGFloat = 0.8
    var border: CGFloat = 0.5
    /// 0…255, matching p5.brush. 150 is the library default.
    var opacity: CGFloat = 150
    /// False bleeds inward.
    var outward: Bool = true
    /// Nil picks a random vertex to start the wash. A number is degrees.
    var angle: CGFloat? = nil
    var scatter: Bool = true
    /// When set, the wash is clipped to the polygon. Off lets the bleed leave the selection.
    var clip: Bool = false

    func clamped() -> WatercolorOptions {
        var copy = self
        copy.bleed = min(1, max(0, bleed.isFinite ? bleed : 0))
        copy.texture = min(1, max(0, texture.isFinite ? texture : 0))
        copy.border = min(1, max(0, border.isFinite ? border : 0))
        copy.opacity = min(255, max(0, opacity.isFinite ? opacity : 0))
        return copy
    }
}

struct WatercolorPass: Sendable {
    var polygons: [[CGPoint]]
    var fillAlpha: CGFloat
    var strokeAlpha: CGFloat
    var lineWidth: CGFloat
    var erases: [(center: CGPoint, radius: CGFloat, alpha: CGFloat)]
    /// The extra dark layer (`grow` of a random 0.15…0.7, painted at twice the intensity).
    var darker: [[CGPoint]] = []
    var darkerAlpha: CGFloat = 0
    var scatterPolygons: [[CGPoint]] = []
    var scatterAlpha: CGFloat = 0
}

enum SelectionContours {
    /// Closed outlines of a selection, curves flattened to line segments.
    static func make(from path: CGPath, flatness: CGFloat = 1.4) -> [[CGPoint]] {
        let builder = Builder()
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                builder.close()
                builder.current = [points[0]]
            case .addLineToPoint:
                builder.add(points[0])
            case .addQuadCurveToPoint:
                builder.flattenQuad(control: points[0], end: points[1], flatness: flatness)
            case .addCurveToPoint:
                builder.flattenCubic(control1: points[0], control2: points[1], end: points[2], flatness: flatness, depth: 0)
            case .closeSubpath:
                builder.close()
            @unknown default:
                break
            }
        }
        builder.close()
        return builder.contours.map { resample($0, maxCount: 160) }.filter { $0.count >= 3 }
    }

    private static func resample(_ points: [CGPoint], maxCount: Int) -> [CGPoint] {
        guard points.count > maxCount, maxCount >= 3 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(maxCount)
        let last = points.count - 1
        for index in 0..<maxCount {
            let source = Int((CGFloat(index) / CGFloat(maxCount - 1) * CGFloat(last)).rounded())
            result.append(points[min(last, source)])
        }
        return result
    }

    private final class Builder {
        var contours: [[CGPoint]] = []
        var current: [CGPoint] = []
        func add(_ point: CGPoint) {
            if let last = current.last, hypot(last.x - point.x, last.y - point.y) < 0.2 { return }
            current.append(point)
        }
        func close() {
            if current.count >= 3 { contours.append(current) }
            current = []
        }
        func flattenQuad(control: CGPoint, end: CGPoint, flatness: CGFloat) {
            guard let start = current.last else { add(end); return }
            let mid = CGPoint(x: start.x * 0.25 + control.x * 0.5 + end.x * 0.25, y: start.y * 0.25 + control.y * 0.5 + end.y * 0.25)
            let chord = hypot(end.x - start.x, end.y - start.y)
            if hypot(mid.x - (start.x + end.x) / 2, mid.y - (start.y + end.y) / 2) <= flatness || chord < 0.6 {
                add(end)
                return
            }
            flattenCubic(control1: CGPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3),
                         control2: CGPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3),
                         end: end, flatness: flatness, depth: 0)
        }
        func flattenCubic(control1: CGPoint, control2: CGPoint, end: CGPoint, flatness: CGFloat, depth: Int) {
            guard let start = current.last else { add(end); return }
            let deviation = max(distance(control1, from: start, to: end), distance(control2, from: start, to: end))
            if deviation <= flatness || depth >= 8 || hypot(end.x - start.x, end.y - start.y) < 0.6 {
                add(end)
                return
            }
            let a = midpoint(start, control1), b = midpoint(control1, control2), c = midpoint(control2, end)
            let d = midpoint(a, b), e = midpoint(b, c), f = midpoint(d, e)
            let left2 = d, leftEnd = f, right1 = e, right2 = c
            flattenCubic(control1: a, control2: left2, end: leftEnd, flatness: flatness, depth: depth + 1)
            flattenCubic(control1: right1, control2: right2, end: end, flatness: flatness, depth: depth + 1)
        }
        private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        private func distance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            if length < 1e-6 { return hypot(point.x - a.x, point.y - a.y) }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
        }
    }
}

enum WatercolorFill {
    private struct Poly {
        var v: [CGPoint]
        var m: [CGFloat]
        var dir: [Bool]
        var center: CGPoint
        var sizeX: CGFloat
        var sizeY: CGFloat
        /// The farthest one growth step may push a vertex off its side. fill.js pushes by a share of
        /// the side's own length, which is proportionate on a round blob but lets the long sides of a
        /// flat shape (a bowl's rim, a branch) haze far past its short dimension.
        var reach: CGFloat
    }

    /// Twenty washes, the count p5.brush paints. `bleed`, `texture`, and `border` keep the old argument names.
    static func passes(contours: [[CGPoint]], seed: UInt64, bleed: CGFloat = 0.07, texture: CGFloat = 0.8, border: CGFloat = 0.5, opacity: CGFloat = 150, outward: Bool = true, angle: CGFloat? = nil, scatter: Bool = true) -> [WatercolorPass] {
        let options = WatercolorOptions(bleed: bleed, texture: texture, border: border, opacity: opacity, outward: outward, angle: angle, scatter: scatter)
        return passes(contours: contours, seed: seed, options: options)
    }

    static func passes(contours: [[CGPoint]], seed: UInt64, options: WatercolorOptions) -> [WatercolorPass] {
        let options = options.clamped()
        guard let contour = contours.max(by: { abs(area($0)) < abs(area($1)) }), contour.count >= 3 else { return [] }
        var rng = NaturalRNG(seed: seed == 0 ? 1 : seed)
        var poolA: [CGFloat] = []
        var poolB: [CGFloat] = []
        poolA.reserveCapacity(128)
        poolB.reserveCapacity(128)
        for _ in 0..<128 {
            poolA.append(CGFloat(rng.gaussian(mean: 0.5, deviation: 0.2)))
            poolB.append(CGFloat(rng.gaussian(mean: 0, deviation: 0.02)))
        }
        let strength = options.bleed
        let wr = rng.uniform(0, 75)
        let band = wr < 5 ? 1.0 : (wr < 15 ? 2.0 : 3.0)
        let fluid = Int(Double(contour.count) * 0.25 * band)
        var modifiers: [CGFloat] = []
        modifiers.reserveCapacity(contour.count)
        for index in contour.indices {
            let scale = index > fluid ? 1.0 : 0.3
            modifiers.append(CGFloat(scale * rng.uniform(0.85, 1.4) * Double(strength)))
        }
        let shift = options.angle.map { startIndex(contour, angle: $0) } ?? Int(rng.uniform(0, Double(contour.count)))
        let n = contour.count
        var shifted: [CGPoint] = []
        shifted.reserveCapacity(n)
        for index in 0..<n { shifted.append(contour[(index + shift) % n]) }
        let center = centroid(shifted)
        let flags = outwardFlags(vertices: shifted, against: contour)
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for point in shifted {
            maxX = max(maxX, abs(center.x - point.x))
            maxY = max(maxY, abs(center.y - point.y))
        }
        guard max(maxX, maxY) > 0.5 else { return [] }
        let jittered = CGPoint(x: center.x + CGFloat(rng.uniform(-0.6, 0.6)) * maxX, y: center.y + CGFloat(rng.uniform(-0.6, 0.6)) * maxY)
        var poly = Poly(v: shifted, m: modifiers, dir: flags, center: jittered, sizeX: maxX, sizeY: maxY, reach: bleedReach(contour))
        let intensity = min(1, max(0, options.opacity / 255))
        let ink = 2 * intensity * (1 + options.texture / 2)
        let textureScale = options.texture * 3
        let darkerFactor = CGFloat(rng.uniform(0.15, 0.7))
        let base = poly
        poly = grow(poly, factor: 1, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)
        // fill.js scatters the ungrown polygon (`this.scatter`), not the first growth.
        let sparse: Poly? = options.scatter
            ? flip(scatter(grow(scatter(base, ratio: 0.1, rng: &rng), factor: 1, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward), ratio: 0.75, rng: &rng))
            : nil
        let layers = 20
        var passes: [WatercolorPass] = []
        var pols: [Poly] = []
        let size = max(maxX, maxY)
        for index in 0..<layers {
            if index % 4 == 0 { poly = grow(poly, factor: 1, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward) }
            if index % 2 == 0 {
                pols = [
                    grow(poly, factor: max(0.05, 1 - 0.0125 * CGFloat(index)), rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward),
                    grow(poly, factor: max(0.05, 0.7 - 0.0125 * CGFloat(index)), rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward),
                    grow(poly, factor: max(0.05, 0.4 - 0.0125 * CGFloat(index)), rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)
                ]
            }
            var polygons: [[CGPoint]] = []
            for item in pols {
                let grown = grow(grow(item, factor: 999, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward), factor: 997, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)
                polygons.append(grown.v)
            }
            var scatterPolygons: [[CGPoint]] = []
            if options.scatter, let sparse {
                let layer = grow(flip(grow(sparse, factor: 999, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)), factor: 997, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)
                scatterPolygons = [layer.v]
            }
            var darker: [[CGPoint]] = []
            if index % 2 == 0 {
                let dark = grow(grow(poly, factor: darkerFactor, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward), factor: 999, rng: &rng, poolA: poolA, poolB: poolB, bleed: strength, outward: options.outward)
                darker = [dark.v]
            }
            var erases: [(center: CGPoint, radius: CGFloat, alpha: CGFloat)] = []
            if options.texture > 0, index % 8 == 0 || index == layers - 1 {
                erases = erase(poly, texture: options.texture, opacity: options.opacity, rng: &rng)
            }
            let width = map(CGFloat(index), 0, 24, size / 25, size / 30, clamp: true) * options.border
            passes.append(WatercolorPass(polygons: polygons, fillAlpha: ink / 100, strokeAlpha: options.border * 0.010,
                                         lineWidth: max(0.4, width), erases: erases, darker: darker, darkerAlpha: ink * 2 / 100,
                                         scatterPolygons: scatterPolygons, scatterAlpha: ink * textureScale / 100))
        }
        return passes
    }

    static func draw(_ pass: WatercolorPass, red: CGFloat, green: CGFloat, blue: CGFloat, mask: Bool, in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(pass.lineWidth)
        func paint(_ polygons: [[CGPoint]], alpha: CGFloat) {
            guard alpha > 0 else { return }
            for polygon in polygons where polygon.count >= 3 {
                context.addPath(path(polygon))
                context.setFillColor(color(red: red, green: green, blue: blue, alpha: alpha, mask: mask))
                context.fillPath()
                if pass.strokeAlpha > 0 {
                    context.addPath(path(polygon))
                    context.setStrokeColor(color(red: red, green: green, blue: blue, alpha: pass.strokeAlpha, mask: mask))
                    context.strokePath()
                }
            }
        }
        paint(pass.polygons, alpha: pass.fillAlpha)
        paint(pass.darker, alpha: pass.darkerAlpha)
        paint(pass.scatterPolygons, alpha: pass.scatterAlpha)
        if !pass.erases.isEmpty {
            context.setBlendMode(.destinationOut)
            for erase in pass.erases {
                context.setFillColor(gray: 0, alpha: erase.alpha)
                context.fillEllipse(in: CGRect(x: erase.center.x - erase.radius, y: erase.center.y - erase.radius, width: erase.radius * 2, height: erase.radius * 2))
            }
        }
        context.restoreGState()
    }

    /// How far past the selection the wash should be allowed to paint. Zero when the wash is clipped.
    static func bleedMargin(bounds: CGRect, options: WatercolorOptions) -> CGFloat {
        guard !options.clip else { return 0 }
        let span = max(bounds.width, bounds.height)
        return max(24, span * (0.35 + options.bleed * 2))
    }

    private static func erase(_ poly: Poly, texture: CGFloat, opacity: CGFloat, rng: inout NaturalRNG) -> [(center: CGPoint, radius: CGFloat, alpha: CGFloat)] {
        let spread = map(texture, 0, 1, 2, 3.5, clamp: true)
        let count = Int(rng.uniform(80, 110) * Double(spread))
        let minSize = min(poly.sizeX, poly.sizeY) * 1.3
        let alpha = ((5 - map(opacity, 80, 100, 0.3, 0.7, clamp: true)) * texture * 3) / 255
        var marks: [(center: CGPoint, radius: CGFloat, alpha: CGFloat)] = []
        marks.reserveCapacity(count)
        for index in 0..<count {
            if index % 5 == 0 {
                _ = rng.gaussian(deviation: Double(poly.sizeX / 1.3))
                _ = rng.gaussian(deviation: Double(poly.sizeY / 1.3))
                _ = rng.uniform(Double(0.03 * minSize), Double(0.45 * minSize))
                continue
            }
            let x = poly.center.x + CGFloat(rng.gaussian(deviation: Double(poly.sizeX / 1.3)))
            let y = poly.center.y + CGFloat(rng.gaussian(deviation: Double(poly.sizeY / 1.3)))
            let radius = CGFloat(rng.uniform(Double(0.03 * minSize), Double(0.45 * minSize)))
            marks.append((CGPoint(x: x, y: y), max(0.5, radius), max(0, alpha)))
        }
        return marks
    }

    /// One growth step, after fill.js `grow`. Each side gets a new vertex pushed off it by a Gaussian
    /// share of the side's own length, so a long side makes a big tooth. fill.js leans on its inputs
    /// having similar sides; ours do not (an arc's chord, a trim bridge, the sparse layer's 30 wide
    /// sides), and a fixed polygon regrown twenty times at exact midpoints stacked the same tooth in
    /// the same place until it read as a row of triangles. So a long side with a big push becomes a
    /// rounded, lopsided lobe of the same height over several uneven pieces, the new vertex lands at a
    /// random point along its side, and the angle varies per vertex. The fringe comes out soft and
    /// irregular, and the wash still bleeds as far as fill.js's.
    private static func grow(_ poly: Poly, factor: CGFloat, rng: inout NaturalRNG, poolA: [CGFloat], poolB: [CGFloat], bleed: CGFloat, outward: Bool) -> Poly {
        let trimmed = trim(poly, factor: factor, rng: &rng)
        let len = trimmed.v.count
        guard len >= 3 else { return trimmed }
        let bleedDir: CGFloat = outward ? -90 : 90
        let maxSide = max(3, max(trimmed.sizeX, trimmed.sizeY) * 0.05)
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var dirs: [Bool] = []
        vertices.reserveCapacity(min(1200, len * 3))
        for index in 0..<len {
            let current = trimmed.v[index]
            let next = trimmed.v[(index + 1) % len]
            let mine = trimmed.m[index]
            let flag = trimmed.dir[index]
            var mod = factor == 999 ? CGFloat(rng.uniform(0.6, 0.8)) : bleed
            if factor < 997 { mod = mine }
            let fullX = next.x - current.x, fullY = next.y - current.y
            let fullLength = hypot(fullX, fullY)
            vertices.append(current)
            modifiers.append(mine)
            dirs.append(flag)
            if mod < 0.05 {
                vertices.append(CGPoint(x: current.x + fullX * 0.5, y: current.y + fullY * 0.5))
                modifiers.append(mine)
                dirs.append(flag)
                continue
            }
            let rot = (flag ? bleedDir : -bleedDir) + CGFloat(rng.uniform(-1, 1)) * 12
            let radians = rot * CGFloat.pi / 180
            let c = cos(radians), s = sin(radians)
            let sample = poolA[Int(rng.uniform(0, 1) * Double(poolA.count)) % poolA.count]
            var push = max(0, sample) * CGFloat(rng.uniform(0.65, 1.35)) * mod
            if push * fullLength > trimmed.reach { push = trimmed.reach / max(fullLength, 1e-6) }
            // Only the big pushes (999's 0.6…0.8, a trim bridge's 0.3…0.5) on long sides make teeth.
            // A bleed-sized push keeps fill.js's single vertex per side.
            let pieces = mod > 0.2 ? min(12, max(1, Int((fullLength / maxSide).rounded(.up)))) : 1
            if pieces == 1 {
                let dirX = c * fullX + s * fullY
                let dirY = c * fullY - s * fullX
                let along = CGFloat(rng.uniform(0.3, 0.7))
                let nextMod = mine + poolB[Int(rng.uniform(0, 1) * Double(poolB.count)) % poolB.count]
                vertices.append(CGPoint(x: current.x + fullX * along + dirX * push, y: current.y + fullY * along + dirY * push))
                modifiers.append(nextMod)
                dirs.append(flag)
                continue
            }
            // A long side keeps fill.js's full push (so the wash bleeds as far), but spread over a
            // rounded, lopsided lobe: every cut point and piece midpoint rides the same hump with its
            // own wobble, instead of one straight-sided triangle.
            let unitX = (c * fullX + s * fullY) / max(fullLength, 1e-6)
            let unitY = (c * fullY - s * fullX) / max(fullLength, 1e-6)
            let height = push * fullLength
            let peak = CGFloat(rng.uniform(0.25, 0.75))
            func hump(_ t: CGFloat) -> CGFloat {
                let u = t < peak ? t / peak : (1 - t) / (1 - peak)
                return sin(min(1, max(0, u)) * CGFloat.pi / 2)
            }
            var cuts: [CGFloat] = [0]
            for piece in 1..<pieces { cuts.append((CGFloat(piece) + CGFloat(rng.uniform(-0.35, 0.35))) / CGFloat(pieces)) }
            cuts.append(1)
            for piece in 0..<pieces {
                let t0 = cuts[piece], t1 = cuts[piece + 1]
                if piece > 0 {
                    let lift = height * hump(t0) * CGFloat(rng.uniform(0.8, 1.1))
                    vertices.append(CGPoint(x: current.x + fullX * t0 + unitX * lift, y: current.y + fullY * t0 + unitY * lift))
                    modifiers.append(mine + poolB[Int(rng.uniform(0, 1) * Double(poolB.count)) % poolB.count])
                    dirs.append(flag)
                }
                let t = t0 + (t1 - t0) * CGFloat(rng.uniform(0.3, 0.7))
                let wobble = (t1 - t0) * fullLength * CGFloat(rng.uniform(-0.15, 0.3))
                let lift = height * hump(t) * CGFloat(rng.uniform(0.85, 1.15)) + wobble
                vertices.append(CGPoint(x: current.x + fullX * t + unitX * lift, y: current.y + fullY * t + unitY * lift))
                modifiers.append(mine + poolB[Int(rng.uniform(0, 1) * Double(poolB.count)) % poolB.count])
                dirs.append(flag)
            }
        }
        return cap(Poly(v: vertices, m: modifiers, dir: dirs, center: trimmed.center, sizeX: trimmed.sizeX, sizeY: trimmed.sizeY, reach: trimmed.reach), limit: 480, rng: &rng)
    }

    private static func trim(_ poly: Poly, factor: CGFloat, rng: inout NaturalRNG) -> Poly {
        let count = poly.v.count
        guard factor < 1, factor >= 0, count > 8 else { return poly }
        let remove = Int((1 - factor) * CGFloat(count))
        guard remove >= 2, remove < count - 4 else { return poly }
        let start = count / 2 - remove / 2
        let end = start + remove
        let from = poly.v[(start - 1 + count) % count]
        let to = poly.v[end % count]
        let edge = hypot(to.x - from.x, to.y - from.y)
        let sample = start >= 2 ? Int(rng.uniform(0, Double(start - 1))) : 0
        let spacing = max(1, hypot(poly.v[(sample + 1) % count].x - poly.v[sample].x, poly.v[(sample + 1) % count].y - poly.v[sample].y))
        let insert = max(2, Int(ceil(edge / spacing * 0.05)))
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var dirs: [Bool] = []
        if start > 0 {
            vertices.append(contentsOf: poly.v[0..<start])
            modifiers.append(contentsOf: poly.m[0..<start])
            dirs.append(contentsOf: poly.dir[0..<start])
        }
        let jitter = min(edge * 0.06, poly.reach * 0.5)
        let flag = poly.dir[start % poly.dir.count]
        for step in 1...insert {
            let t = CGFloat(step) / CGFloat(insert + 1)
            vertices.append(CGPoint(x: from.x + (to.x - from.x) * t + CGFloat(rng.uniform(Double(-jitter), Double(jitter))),
                                    y: from.y + (to.y - from.y) * t + CGFloat(rng.uniform(Double(-jitter), Double(jitter)))))
            modifiers.append(CGFloat(rng.uniform(0.3, 0.5)))
            dirs.append(flag)
        }
        if end < count {
            vertices.append(contentsOf: poly.v[end...])
            modifiers.append(contentsOf: poly.m[end...])
            dirs.append(contentsOf: poly.dir[end...])
        }
        guard vertices.count >= 3 else { return poly }
        return Poly(v: vertices, m: modifiers, dir: dirs, center: poly.center, sizeX: poly.sizeX, sizeY: poly.sizeY, reach: poly.reach)
    }

    private static func scatter(_ poly: Poly, ratio: CGFloat, rng: inout NaturalRNG) -> Poly {
        let count = poly.v.count
        let keep = max(3, Int(CGFloat(count) * ratio))
        guard keep < count else { return poly }
        let step = CGFloat(count) / CGFloat(keep)
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var dirs: [Bool] = []
        for index in 0..<keep {
            let source = Int(CGFloat(index) * step + CGFloat(rng.uniform(0, Double(step * 0.8)))) % count
            var point = poly.v[source]
            if !contains(point, polygon: poly.v) {
                point = CGPoint(x: poly.center.x + (point.x - poly.center.x) * CGFloat(rng.uniform(0.3, 0.6)),
                                y: poly.center.y + (point.y - poly.center.y) * CGFloat(rng.uniform(0.3, 0.6)))
            }
            vertices.append(point)
            modifiers.append(poly.m[source])
            dirs.append(!poly.dir[source])
        }
        return Poly(v: vertices, m: modifiers, dir: dirs, center: poly.center, sizeX: poly.sizeX, sizeY: poly.sizeY, reach: poly.reach)
    }

    private static func flip(_ poly: Poly) -> Poly {
        var copy = poly
        copy.dir = poly.dir.map { !$0 }
        return copy
    }

    /// Thins a polygon to `limit` vertices. A fixed stride of 2 would keep only the even (old) vertices
    /// and throw away every grown one, so a dense outline would never grow at all. A jittered stride
    /// keeps a mix, in order.
    private static func cap(_ poly: Poly, limit: Int, rng: inout NaturalRNG) -> Poly {
        let count = poly.v.count
        guard count > limit, limit >= 3 else { return poly }
        let step = CGFloat(count) / CGFloat(limit)
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var dirs: [Bool] = []
        vertices.reserveCapacity(limit)
        var last = -1
        for index in 0..<limit {
            let source = min(count - 1, Int(CGFloat(index) * step + CGFloat(rng.uniform(0, Double(step * 0.9)))))
            guard source > last else { continue }
            last = source
            vertices.append(poly.v[source])
            modifiers.append(poly.m[source])
            dirs.append(poly.dir[source])
        }
        return Poly(v: vertices, m: modifiers, dir: dirs, center: poly.center, sizeX: poly.sizeX, sizeY: poly.sizeY, reach: poly.reach)
    }

    /// Ray-parity from each edge midpoint, the direction test in fill.js. Even means the bleed rotation is the outward one.
    private static func outwardFlags(vertices: [CGPoint], against sides: [CGPoint]) -> [Bool] {
        let sideCount = sides.count
        return vertices.indices.map { index in
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let sideX = next.x - current.x, sideY = next.y - current.y
            let midX = current.x + sideX / 2, midY = current.y + sideY / 2
            let rayX = -sideY, rayY = sideX
            let opposite = -(sideX * sideX + sideY * sideY)
            var hits = 0
            for side in 0..<sideCount {
                let a = sides[side], b = sides[(side + 1) % sideCount]
                let sdx = b.x - a.x, sdy = b.y - a.y
                let denom = sdy * rayX - sdx * rayY
                if denom == 0 { continue }
                let ub = (rayX * (midY - a.y) - rayY * (midX - a.x)) / denom
                if ub < 0 || ub > 1 { continue }
                let ua = (sdx * (midY - a.y) - sdy * (midX - a.x)) / denom
                if ua * opposite <= 0.01 { continue }
                hits += 1
            }
            return hits % 2 == 0
        }
    }

    private static func startIndex(_ points: [CGPoint], angle: CGFloat) -> Int {
        let radians = angle * CGFloat.pi / 180
        let dx = cos(radians), dy = -sin(radians)
        var best = 0
        var bestDot = CGFloat.infinity
        for (index, point) in points.enumerated() {
            let dot = point.x * dx + point.y * dy
            if dot < bestDot { bestDot = dot; best = index }
        }
        return best
    }

    private static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var hits = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) == (b.y > point.y) { continue }
            let t = (point.y - a.y) / (b.y - a.y)
            if point.x < a.x + t * (b.x - a.x) { hits += 1 }
        }
        return hits % 2 == 1
    }

    private static func map(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, clamp: Bool) -> CGFloat {
        let span = b - a
        let raw = span == 0 ? c : c + ((value - a) / span) * (d - c)
        guard clamp else { return raw }
        let low = min(c, d), high = max(c, d)
        return min(high, max(low, raw))
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func color(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, mask: Bool) -> CGColor {
        if mask { return CGColor(gray: red, alpha: alpha) }
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 8 else {
            let count = CGFloat(points.count)
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / count, y: sum.y / count)
        }
        var areaSum: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            let cross = points[index].x * next.y - next.x * points[index].y
            areaSum += cross
            cx += (points[index].x + next.x) * cross
            cy += (points[index].y + next.y) * cross
        }
        guard abs(areaSum) > 1e-4 else {
            let count = CGFloat(points.count)
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / count, y: sum.y / count)
        }
        return CGPoint(x: cx / (3 * areaSum), y: cy / (3 * areaSum))
    }

    /// The push limit for a shape: 0.6 × the smaller of its equivalent radius √(A/π) and its mean
    /// thickness 2A/P. Both equal r for a circle, so round and square washes bleed as fill.js does
    /// (its largest pushes are about half a hexagon side, near 0.5 r), while a 400 × 44 rim is
    /// limited by its 44 px thickness instead of its 400 px length.
    static func bleedReach(_ points: [CGPoint]) -> CGFloat {
        let a = abs(area(points))
        var perimeter: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            perimeter += hypot(next.x - points[index].x, next.y - points[index].y)
        }
        guard a > 0, perimeter > 0 else { return 2 }
        return max(2, 0.6 * min((a / CGFloat.pi).squareRoot(), 2 * a / perimeter))
    }

    private static func area(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            sum += points[index].x * next.y - next.x * points[index].y
        }
        return sum / 2
    }
}

