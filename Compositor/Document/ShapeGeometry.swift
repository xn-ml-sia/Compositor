import CoreGraphics

// Shape paths from p5.brush `src/core/primitives.js` (MIT, Alejandro Campos Uribe).
// Curvature 0 is the polyline. A positive curvature fillets corners. Circles are four
// tangential steps, lengthened when `r` is set. The active flow field bends the result.

enum ShapeGeometry {
    static func build(_ geometry: StrokeGeometry, field: FlowField?, seed: UInt64) -> (samples: [StrokeSample], polygon: [CGPoint]) {
        let raw: [StrokeSample]
        let close: Bool
        switch geometry {
        case .spline(let points, let curvature):
            raw = spline(points, curvature: curvature, closed: false, seed: seed)
            close = false
        case .shape(let points, let curvature, let closed):
            raw = spline(points, curvature: curvature, closed: closed, seed: seed)
            close = closed
        case .circle(let x, let y, let radius, let irregularity):
            raw = circle(x: x, y: y, radius: radius, irregularity: irregularity, seed: seed)
            close = true
        case .rect(let x, let y, let width, let height, let centered):
            raw = rect(x: x, y: y, width: width, height: height, centered: centered)
            close = true
        case .arc(let x, let y, let radius, let start, let end):
            raw = arc(x: x, y: y, radius: radius, start: start, end: end)
            close = false
        case .polygon(let points):
            raw = points
            close = true
        case .plot(let x, let y, let segments, let endPressure):
            var traced = trace(from: CGPoint(x: x, y: y), segments: segments.map { ($0.angle, $0.length, $0.pressure) }, field: nil)
            if let last = traced.indices.last { traced[last].pressure = endPressure }
            raw = traced
            close = false
        }
        return steered(raw, field: field, close: close)
    }

    /// A curvature of 0 leaves the points in order. Closed shapes repeat the first point.
    static func spline(_ points: [StrokeSample], curvature: CGFloat, closed: Bool, seed: UInt64) -> [StrokeSample] {
        guard curvature > 0, points.count >= 3 else {
            var copy = points
            if closed, let first = points.first { copy.append(first) }
            return copy
        }
        var ring = points
        if closed { ring.append(points[0]) }
        if closed, points.count >= 2 { ring.append(points[1]) }
        var samples: [StrokeSample] = [ring[0]]
        let count = ring.count
        var index = 0
        while index < count - 2 {
            let a = ring[index], b = ring[index + 1], c = ring[index + 2]
            let d1 = hypot(b.x - a.x, b.y - a.y), d2 = hypot(c.x - b.x, c.y - b.y)
            let trim = curvature * min(d1, d2, 0.5 * min(d1, d2))
            let angle1 = atan2(b.y - a.y, b.x - a.x)
            let angle2 = atan2(c.y - b.y, c.x - b.x)
            if abs(angle1 - angle2) < 0.02 || trim < 0.4 {
                samples.append(b)
                index += 1
                continue
            }
            let before = CGPoint(x: b.x - CGFloat(cos(angle1)) * trim, y: b.y - CGFloat(sin(angle1)) * trim)
            let after = CGPoint(x: b.x + CGFloat(cos(angle2)) * trim, y: b.y + CGFloat(sin(angle2)) * trim)
            samples.append(StrokeSample(x: before.x, y: before.y, pressure: a.pressure, time: nil))
            for step in 1...5 {
                let t = CGFloat(step) / 6
                let point = quadratic(before, b.point, after, t)
                samples.append(StrokeSample(x: point.x, y: point.y, pressure: b.pressure, time: nil))
            }
            samples.append(StrokeSample(x: after.x, y: after.y, pressure: b.pressure, time: nil))
            index += 1
        }
        if let last = ring.last { samples.append(last) }
        _ = seed
        return samples
    }

    private static func steered(_ samples: [StrokeSample], field: FlowField?, close: Bool) -> (samples: [StrokeSample], polygon: [CGPoint]) {
        let bent = field?.steer(samples, step: 3) ?? samples
        var polygon = bent.map { CGPoint(x: $0.x, y: $0.y) }
        if close, let first = polygon.first, polygon.count >= 3 {
            if hypot(first.x - polygon[polygon.count - 1].x, first.y - polygon[polygon.count - 1].y) > 0.5 {
                polygon.append(first)
            }
        }
        return (bent, polygon)
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat, irregularity: CGFloat, seed: UInt64) -> [StrokeSample] {
        var rng = NaturalRNG(seed: seed == 0 ? 1 : seed)
        let offset = CGFloat(rng.uniform(0, 360))
        let arc = CGFloat.pi * radius
        var segments: [(CGFloat, CGFloat, CGFloat)] = []
        for index in 0..<4 {
            let angleScale = irregularity > 0 ? 1 + irregularity * 0.2 * CGFloat(rng.uniform(0, 1)) : 1
            let lengthScale = irregularity > 0 ? 1 + irregularity * 0.2 * CGFloat(rng.uniform(0, 1)) : 1
            segments.append(((-90 * CGFloat(index) + offset) * angleScale, (arc / 2) * lengthScale, 1))
        }
        if irregularity > 0 {
            let extra = irregularity * CGFloat(Int(rng.uniform(-5, 5)))
            segments.append((offset, abs(extra) * CGFloat.pi / 180 * radius, 1))
        }
        let origin = CGPoint(x: x - radius * sin(offset * .pi / 180), y: y - radius * cos(-offset * .pi / 180))
        return trace(from: origin, segments: segments, field: nil)
    }

    private static func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, centered: Bool) -> [StrokeSample] {
        var originX = x, originY = y
        if centered { originX -= width / 2; originY -= height / 2 }
        let corners = [
            CGPoint(x: originX, y: originY), CGPoint(x: originX + width, y: originY),
            CGPoint(x: originX + width, y: originY + height), CGPoint(x: originX, y: originY + height),
            CGPoint(x: originX, y: originY)
        ]
        return corners.map { StrokeSample(x: $0.x, y: $0.y, pressure: 1, time: nil) }
    }

    private static func arc(x: CGFloat, y: CGFloat, radius: CGFloat, start: CGFloat, end: CGFloat) -> [StrokeSample] {
        var sweep = (end - start).truncatingRemainder(dividingBy: 360)
        if sweep < 0 { sweep += 360 }
        if sweep == 0 { return [] }
        let pieces = max(1, Int((sweep / 90).rounded(.up)))
        let step = sweep / CGFloat(pieces)
        var samples: [StrokeSample] = []
        let count = pieces * 8
        for index in 0...count {
            let degrees = start + sweep * CGFloat(index) / CGFloat(count)
            let radians = degrees * .pi / 180
            samples.append(StrokeSample(x: x + radius * cos(radians), y: y - radius * sin(radians), pressure: 1, time: nil))
        }
        _ = step
        return samples
    }

    private static func trace(from origin: CGPoint, segments: [(CGFloat, CGFloat, CGFloat)], field: FlowField?) -> [StrokeSample] {
        var position = origin
        var samples = [StrokeSample(x: origin.x, y: origin.y, pressure: segments.first?.2, time: nil)]
        for segment in segments where segment.1 > 0 {
            var remain = segment.1
            let step = max(1.25, segment.1 / 16)
            while remain > 0.05 && samples.count < 4000 {
                let bit = min(step, remain)
                let heading = (segment.0 - (field?.angle(at: position) ?? 0)) * .pi / 180
                position.x += CGFloat(cos(heading)) * bit
                position.y += CGFloat(sin(heading)) * bit
                remain -= bit
                samples.append(StrokeSample(x: position.x, y: position.y, pressure: segment.2, time: nil))
            }
        }
        return samples
    }

    private static func quadratic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
    }
}

private extension StrokeSample {
    var point: CGPoint { CGPoint(x: x, y: y) }
}
