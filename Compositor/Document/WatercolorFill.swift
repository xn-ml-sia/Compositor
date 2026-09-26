import AppKit

// Watercolor fill ported from p5.brush `src/fill/fill.js` (MIT, Alejandro Campos Uribe),
// which follows Tyler Hobbs, "A Generative Approach to Simulating Watercolor Paints"
// (https://tylerxhobbs.com/essays/2017/a-generative-approach-to-simulating-watercolor-paints).
// A polygon grows, gets trimmed, and is redrawn in translucent layers; destination-out
// circles lift pigment the way the original erase step does. Layers composite with
// ordinary source-over so a transparent layer stays transparent — no spectral mixing.

struct WatercolorPass: Sendable {
    var polygons: [[CGPoint]]
    var fillAlpha: CGFloat
    var strokeAlpha: CGFloat
    var lineWidth: CGFloat
    var erases: [(center: CGPoint, radius: CGFloat, alpha: CGFloat)]
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
        var vertices: [CGPoint]
        var modifiers: [CGFloat]
        var outward: [Bool]
        var center: CGPoint
        var size: CGFloat
    }

    /// Ten washes rather than p5's twenty. Each one is a frame the canvas can show before the next.
    static func passes(contours: [[CGPoint]], seed: UInt64, bleed: CGFloat = 0.07, texture: CGFloat = 0.8, border: CGFloat = 0.5) -> [WatercolorPass] {
        guard let contour = contours.max(by: { abs(area($0)) < abs(area($1)) }), contour.count >= 3 else { return [] }
        var rng = NaturalRNG(seed: seed == 0 ? 1 : seed)
        var gaussians: [CGFloat] = []
        gaussians.reserveCapacity(256)
        for _ in 0..<256 { gaussians.append(CGFloat(rng.gaussian(mean: 0.5, deviation: 0.2))) }
        let center = centroid(contour)
        let size = contour.reduce(CGFloat(0)) { max($0, hypot($1.x - center.x, $1.y - center.y)) }
        guard size > 0.5 else { return [] }
        let strength = min(1, max(0, bleed))
        let fluid = contour.count / 4
        var modifiers: [CGFloat] = []
        var outward: [Bool] = []
        for index in contour.indices {
            let scale: CGFloat = index > fluid ? 1 : 0.3
            modifiers.append(scale * CGFloat(rng.uniform(0.85, 1.4)) * strength)
            outward.append(true)
        }
        var poly = Poly(vertices: contour, modifiers: modifiers, outward: outward, center: jittered(center, size: size, rng: &rng), size: size)
        poly = grow(poly, factor: 1, rng: &rng, gaussians: gaussians, strength: strength)
        let layers = 10
        var passes: [WatercolorPass] = []
        for index in 0..<layers {
            if index % 3 == 0 { poly = grow(poly, factor: 1, rng: &rng, gaussians: gaussians, strength: strength) }
            let fade = 1 - CGFloat(index) / CGFloat(layers)
            let main = grow(poly, factor: max(0.25, 1 - 0.04 * CGFloat(index)), rng: &rng, gaussians: gaussians, strength: strength)
            let mid = grow(poly, factor: max(0.18, 0.62 - 0.03 * CGFloat(index)), rng: &rng, gaussians: gaussians, strength: strength)
            let inner = grow(poly, factor: max(0.12, 0.34 - 0.02 * CGFloat(index)), rng: &rng, gaussians: gaussians, strength: strength)
            var polygons = [main.vertices, mid.vertices, inner.vertices]
            if texture > 0 {
                polygons.append(scatter(grow(poly, factor: 1, rng: &rng, gaussians: gaussians, strength: strength), ratio: 0.34, rng: &rng).vertices)
            }
            var erases: [(center: CGPoint, radius: CGFloat, alpha: CGFloat)] = []
            if texture > 0, index % 4 == 3 || index == layers - 1 {
                let count = Int(rng.uniform(18, 36) * Double(max(0.4, texture)))
                for _ in 0..<count {
                    let spreadX = CGFloat(rng.gaussian(deviation: Double(size / 2.2)))
                    let spreadY = CGFloat(rng.gaussian(deviation: Double(size / 2.2)))
                    let radius = CGFloat(rng.uniform(Double(size * 0.04), Double(size * 0.28)))
                    erases.append((CGPoint(x: poly.center.x + spreadX, y: poly.center.y + spreadY), radius, 0.12 + 0.1 * texture))
                }
            }
            passes.append(WatercolorPass(polygons: polygons, fillAlpha: 0.045 * fade + 0.018, strokeAlpha: 0.03 * border * fade,
                                         lineWidth: max(0.6, size / 28 * border), erases: erases))
        }
        return passes
    }

    static func draw(_ pass: WatercolorPass, red: CGFloat, green: CGFloat, blue: CGFloat, mask: Bool, in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(pass.lineWidth)
        for polygon in pass.polygons where polygon.count >= 3 {
            context.addPath(path(polygon))
            context.setFillColor(paint(red: red, green: green, blue: blue, alpha: pass.fillAlpha, mask: mask))
            context.fillPath()
            if pass.strokeAlpha > 0 {
                context.addPath(path(polygon))
                context.setStrokeColor(paint(red: red, green: green, blue: blue, alpha: pass.strokeAlpha, mask: mask))
                context.strokePath()
            }
        }
        if !pass.erases.isEmpty {
            context.setBlendMode(.destinationOut)
            for erase in pass.erases {
                context.setFillColor(gray: 0, alpha: erase.alpha)
                context.fillEllipse(in: CGRect(x: erase.center.x - erase.radius, y: erase.center.y - erase.radius, width: erase.radius * 2, height: erase.radius * 2))
            }
        }
        context.restoreGState()
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func paint(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, mask: Bool) -> CGColor {
        if mask { return CGColor(gray: red, alpha: alpha) }
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func grow(_ poly: Poly, factor: CGFloat, rng: inout NaturalRNG, gaussians: [CGFloat], strength: CGFloat) -> Poly {
        let trimmed = trim(poly, factor: factor, rng: &rng)
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var outward: [Bool] = []
        let count = trimmed.vertices.count
        vertices.reserveCapacity(count * 2)
        for index in 0..<count {
            let current = trimmed.vertices[index]
            let next = trimmed.vertices[(index + 1) % count]
            var modifier = trimmed.modifiers[index]
            if factor < 0.98 { modifier = min(modifier, factor * strength + modifier * 0.35) }
            vertices.append(current)
            modifiers.append(trimmed.modifiers[index])
            outward.append(trimmed.outward[index])
            let sideX = next.x - current.x, sideY = next.y - current.y
            let mid = CGPoint(x: current.x + sideX * 0.5, y: current.y + sideY * 0.5)
            if modifier < 0.01 {
                vertices.append(mid)
                modifiers.append(trimmed.modifiers[index])
                outward.append(trimmed.outward[index])
                continue
            }
            // Rotate the edge about ±90° and step along it, the grow() in fill.js.
            // Outward is away from the centroid, so either winding of a selection bleeds out.
            let awayX = mid.x - trimmed.center.x, awayY = mid.y - trimmed.center.y
            let away = max(0.001, hypot(awayX, awayY))
            let sign: CGFloat = trimmed.outward[index] ? 1 : -1
            let gauss = gaussians[Int(rng.uniform(0, Double(gaussians.count - 1)))]
            let distance = gauss * CGFloat(rng.uniform(0.65, 1.35)) * modifier * hypot(sideX, sideY)
            let wobble = CGFloat(rng.uniform(-1, 1)) * 0.08
            let nx = sign * awayX / away + wobble * (-sideY)
            let ny = sign * awayY / away + wobble * sideX
            let normal = max(0.001, hypot(nx, ny))
            vertices.append(CGPoint(x: mid.x + nx / normal * distance, y: mid.y + ny / normal * distance))
            modifiers.append(max(0, trimmed.modifiers[index] + CGFloat(rng.gaussian(deviation: 0.02))))
            outward.append(trimmed.outward[index])
        }
        return downsample(Poly(vertices: vertices, modifiers: modifiers, outward: outward, center: trimmed.center, size: trimmed.size), cap: 480)
    }

    /// Drops a span of vertices and bridges the gap, so a wash edge is not a copy of the selection.
    private static func trim(_ poly: Poly, factor: CGFloat, rng: inout NaturalRNG) -> Poly {
        let count = poly.vertices.count
        guard factor < 0.98, count > 8 else { return poly }
        let remove = Int((1 - factor) * CGFloat(count))
        guard remove >= 2, remove < count - 4 else { return poly }
        let start = count / 2 - remove / 2
        let end = min(count, start + remove)
        let from = poly.vertices[(start - 1 + count) % count]
        let to = poly.vertices[end % count]
        let bridge = hypot(to.x - from.x, to.y - from.y)
        let insert = max(2, Int(bridge / 12))
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var outward: [Bool] = []
        if start > 0 {
            vertices.append(contentsOf: poly.vertices[0..<start])
            modifiers.append(contentsOf: poly.modifiers[0..<start])
            outward.append(contentsOf: poly.outward[0..<start])
        }
        let jitter = bridge * 0.06
        for step in 1...insert {
            let t = CGFloat(step) / CGFloat(insert + 1)
            vertices.append(CGPoint(x: from.x + (to.x - from.x) * t + CGFloat(rng.uniform(Double(-jitter), Double(jitter))),
                                    y: from.y + (to.y - from.y) * t + CGFloat(rng.uniform(Double(-jitter), Double(jitter)))))
            modifiers.append(CGFloat(rng.uniform(0.3, 0.5)) * (poly.modifiers.first ?? 0.05))
            outward.append(poly.outward[start % poly.outward.count])
        }
        if end < count {
            vertices.append(contentsOf: poly.vertices[end...])
            modifiers.append(contentsOf: poly.modifiers[end...])
            outward.append(contentsOf: poly.outward[end...])
        }
        return Poly(vertices: vertices, modifiers: modifiers, outward: outward, center: poly.center, size: poly.size)
    }

    private static func scatter(_ poly: Poly, ratio: CGFloat, rng: inout NaturalRNG) -> Poly {
        let count = poly.vertices.count
        let keep = max(3, Int(CGFloat(count) * ratio))
        guard keep < count else { return poly }
        let step = CGFloat(count) / CGFloat(keep)
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var outward: [Bool] = []
        for index in 0..<keep {
            let source = min(count - 1, Int(CGFloat(index) * step + CGFloat(rng.uniform(0, Double(step * 0.8)))))
            vertices.append(poly.vertices[source])
            modifiers.append(poly.modifiers[source])
            outward.append(!poly.outward[source])
        }
        return Poly(vertices: vertices, modifiers: modifiers, outward: outward, center: poly.center, size: poly.size)
    }

    private static func downsample(_ poly: Poly, cap: Int) -> Poly {
        guard poly.vertices.count > cap else { return poly }
        let step = Int((CGFloat(poly.vertices.count) / CGFloat(cap)).rounded(.up))
        var vertices: [CGPoint] = []
        var modifiers: [CGFloat] = []
        var outward: [Bool] = []
        var index = 0
        while index < poly.vertices.count {
            vertices.append(poly.vertices[index])
            modifiers.append(poly.modifiers[index])
            outward.append(poly.outward[index])
            index += step
        }
        return Poly(vertices: vertices, modifiers: modifiers, outward: outward, center: poly.center, size: poly.size)
    }

    private static func jittered(_ center: CGPoint, size: CGFloat, rng: inout NaturalRNG) -> CGPoint {
        CGPoint(x: center.x + CGFloat(rng.uniform(-0.6, 0.6)) * size, y: center.y + CGFloat(rng.uniform(-0.6, 0.6)) * size)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / count, y: sum.y / count)
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
