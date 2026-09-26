import AppKit

// Natural-media brushes ported from p5.brush (MIT) by Alejandro Campos Uribe.
// https://github.com/acamposuribe/p5.brush
// Preset numbers come from src/stroke/stroke.js. Dabs are hard antialiased discs,
// the same shape as that library's point shader, accumulated with source-over
// (its ONE_MINUS_DST_ALPHA, ONE blend). Spectral Kubelka–Munk mixing is not used:
// it assumes opaque white paper, and layers here are transparent.
//
// Randomness is a function of (stroke seed, step index, channel), never of how
// many times a tail was redrawn. The same step always produces the same dab.

/// One stamped disc in document points. Radius and alpha are the p5 circle after `/ 255`.
struct NaturalDab: Equatable, Sendable {
    var x: Float
    var y: Float
    var radius: Float
    var alpha: Float
}

/// How far a natural stroke has been laid down. Copy it to redraw a tail; only the
/// committed copy advances, so a tail cannot be counted twice.
struct NaturalCursor: Equatable, Sendable {
    var anchor: CGPoint?
    var leftover: CGFloat
    var step: Int
    var traveled: CGFloat
    static let start = NaturalCursor(anchor: nil, leftover: 0, step: 0, traveled: 0)
}

enum NaturalTip: Sendable, Equatable {
    /// Pencil, pen, pastel, crayon, charcoal: scattered discs, sometimes skipped by grain.
    case standard
    /// Many tiny discs on a ring around the point. `grain` is the particle count.
    case spray
    /// A broad disc. Extra dabs mark the start and the end of the stroke.
    case marker
}

struct NaturalBrushPreset: Sendable, Equatable {
    var weight: CGFloat
    var scatter: CGFloat
    var sharpness: CGFloat
    var grain: CGFloat
    /// p5's 0–255-style opacity (a marker's `1` is not 100%).
    var opacity: CGFloat
    var spacing: CGFloat
    /// p5 `min_max[0]`: the pressure at both ends of a gaussian stroke, before tablet pressure.
    var pressureMin: CGFloat
    /// p5 `min_max[1]`: the pressure on the broad plateau. Not sorted against `pressureMin`.
    var pressureMax: CGFloat
    /// Gaussian curve pair from the preset. Ignored when `linearPressure` is set.
    var curve0: CGFloat = 0.15
    var curve1: CGFloat = 0.2
    /// Crayon: a linear start-to-end ramp (`normalizePressure` of `[pressureMin, pressureMax]`).
    var linearPressure: Bool = false
    var tip: NaturalTip
    /// Stroke-wide alpha wobble. p5 defaults this to 0.3 when a preset omits it.
    var noise: CGFloat
}

/// Round is the existing continuous tip. Every other case is a p5.brush preset.
enum NaturalBrushKind: String, CaseIterable, Sendable, Hashable {
    case round = "Round"
    case hb = "HB"
    case pencil2B = "2B"
    case pencil2H = "2H"
    case coloredPencil = "Colored Pencil"
    case charcoal = "Charcoal"
    case pastel = "Pastel"
    case crayon = "Crayon"
    case marker = "Marker"
    case pen = "Pen"
    case rotring = "Rotring"
    case spray = "Spray"

    var preset: NaturalBrushPreset? {
        switch self {
        case .round: return nil
        case .pen: return NaturalBrushPreset(weight: 0.3, scatter: 0.15, sharpness: 0.9, grain: 0.7, opacity: 150, spacing: 0.1, pressureMin: 1.2, pressureMax: 1, curve0: 0.15, curve1: 0.2, tip: .standard, noise: 0.3)
        case .rotring: return NaturalBrushPreset(weight: 0.15, scatter: 0.05, sharpness: 0.7, grain: 0.9, opacity: 210, spacing: 0.1, pressureMin: 1.3, pressureMax: 1, curve0: 0.35, curve1: 0.2, tip: .standard, noise: 0.3)
        case .pencil2B: return NaturalBrushPreset(weight: 0.3, scatter: 0.75, sharpness: 0.45, grain: 0.8, opacity: 180, spacing: 0.1, pressureMin: 1.1, pressureMax: 0.9, curve0: 0.1, curve1: 0.3, tip: .standard, noise: 0.3)
        case .hb: return NaturalBrushPreset(weight: 0.3, scatter: 0.6, sharpness: 0.3, grain: 0.7, opacity: 170, spacing: 0.1, pressureMin: 1.1, pressureMax: 0.9, curve0: 0.15, curve1: 0.2, tip: .standard, noise: 0.3)
        case .pencil2H: return NaturalBrushPreset(weight: 0.2, scatter: 0.6, sharpness: 0.3, grain: 0.75, opacity: 120, spacing: 0.1, pressureMin: 1.1, pressureMax: 0.9, curve0: 0.15, curve1: 0.2, tip: .standard, noise: 0.3)
        case .coloredPencil: return NaturalBrushPreset(weight: 0.35, scatter: 0.55, sharpness: 0.8, grain: 0.7, opacity: 75, spacing: 0.1, pressureMin: 0.95, pressureMax: 1.1, curve0: 0.15, curve1: 0.2, tip: .standard, noise: 0.3)
        case .pastel: return NaturalBrushPreset(weight: 0.7, scatter: 5, sharpness: 0.91, grain: 1, opacity: 30, spacing: 0.085 / 3, pressureMin: 1.09, pressureMax: 0.93, curve0: 0.4, curve1: 0.05, tip: .standard, noise: 1)
        case .crayon: return NaturalBrushPreset(weight: 0.33, scatter: 1.9, sharpness: 0.75, grain: 2, opacity: 159, spacing: 0.07, pressureMin: 1.1, pressureMax: 0.9, curve0: 1.1, curve1: 0.9, linearPressure: true, tip: .standard, noise: 1)
        case .charcoal: return NaturalBrushPreset(weight: 0.35, scatter: 1.5, sharpness: 0.68, grain: 2, opacity: 120, spacing: 0.03, pressureMin: 1.1, pressureMax: 0.95, curve0: 0.15, curve1: 0.4, tip: .standard, noise: 0.3)
        case .spray: return NaturalBrushPreset(weight: 0.2, scatter: 6, sharpness: 15, grain: 40, opacity: 90, spacing: 0.5, pressureMin: 0.7, pressureMax: 1, curve0: 0.2, curve1: 0.35, tip: .spray, noise: 0.3)
        case .marker: return NaturalBrushPreset(weight: 2, scatter: 0.2, sharpness: 0, grain: 1, opacity: 1, spacing: 0.03, pressureMin: 1.2, pressureMax: 0.85, curve0: 0.35, curve1: 0.25, tip: .marker, noise: 0.3)
        }
    }
}

/// Mulberry32, the generator p5.brush uses. Wrapping arithmetic matches `Math.imul`.
struct NaturalRNG: Sendable {
    private var state: UInt32
    init(seed: UInt64) {
        var x = seed == 0 ? 1 : seed
        x ^= x >> 30
        x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27
        x &*= 0x94D049BB133111EB
        x ^= x >> 31
        state = UInt32(truncatingIfNeeded: x)
        if state == 0 { state = 1 }
    }
    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (state | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) * 2.3283064365386963e-10
    }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }
    /// One Box–Muller sample. The second deviate is discarded so each call consumes two uniforms.
    mutating func gaussian(mean: Double = 0, deviation: Double = 1) -> Double {
        let u = max(1e-12, 1 - next())
        let v = next()
        let radius = sqrt(-2 * log(u))
        return radius * cos(2 * Double.pi * v) * deviation + mean
    }
}

/// A fresh generator per step, so redrawing step 40 never depends on steps 0...39 having run.
struct NaturalStepRNG: Sendable {
    private var rng: NaturalRNG
    init(seed: UInt64, step: Int, channel: Int) {
        var mixed = seed &+ UInt64(bitPattern: Int64(step)) &* 0x9E3779B97F4A7C15
        mixed ^= UInt64(bitPattern: Int64(channel)) &* 0xBF58476D1CE4E5B9
        mixed ^= mixed >> 33
        rng = NaturalRNG(seed: mixed == 0 ? 1 : mixed)
    }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { rng.uniform(low, high) }
    mutating func gaussian(mean: Double = 0, deviation: Double = 1) -> Double { rng.gaussian(mean: mean, deviation: deviation) }
}

/// Randoms p5.brush draws once per stroke in `saveState` (`current.a`, `current.b`, `current.cp`).
/// Channel 17, step 0, so a tail redraw matches the stroke it belongs to.
struct NaturalPressureCurve: Equatable, Sendable {
    var a: CGFloat
    var b: CGFloat
    var exponent: CGFloat
    var warp: CGFloat
    var scale: CGFloat
    var tilt: CGFloat
}

enum NaturalBrushMath {
    /// 0 is a light touch, 1 is a firm one. A mouse has no pressure, so speed stands in:
    /// a slow hand reads as firm, a fast flick as light.
    static func unitPressure(hardware: CGFloat?, from previous: CGPoint?, to point: CGPoint, diameter: CGFloat) -> CGFloat {
        if let hardware { return min(1, max(0, hardware)) }
        guard let previous else { return 0.82 }
        let speed = hypot(point.x - previous.x, point.y - previous.y)
        let fast = max(6, diameter * 0.65)
        return 1 - min(1, speed / fast)
    }

    static func curve(preset: NaturalBrushPreset, seed: UInt64) -> NaturalPressureCurve {
        var rng = NaturalStepRNG(seed: seed, step: 0, channel: 17)
        if preset.linearPressure {
            // 8 percent variation: offset 0.08, scale 0.08, warp 0.06, tilt 0.06.
            return NaturalPressureCurve(a: 0, b: 0, exponent: CGFloat(rng.uniform(-0.08, 0.08)),
                                         warp: CGFloat(rng.uniform(-0.06, 0.06)), scale: CGFloat(rng.uniform(0.92, 1.08)),
                                         tilt: CGFloat(rng.uniform(-0.06, 0.06)))
        }
        return NaturalPressureCurve(a: CGFloat(rng.uniform(-1, 1)), b: CGFloat(rng.uniform(1, 1.5)),
                                     exponent: CGFloat(rng.uniform(3, 3.5)), warp: 0, scale: 1, tilt: 0)
    }

    /// p5 `gauss` / `simPressure`. `pressureMin` is the value near the ends, `pressureMax` the plateau.
    /// A known `length` is the whole stroke. Crayon ramps from `pressureMin` at the start to `pressureMax` at the end.
    static func envelope(plotted: CGFloat, length: CGFloat, preset: NaturalBrushPreset, curve: NaturalPressureCurve) -> CGFloat {
        let length = max(length, 1e-4)
        let t = min(1, max(0, plotted / length))
        if preset.linearPressure { return linearEnvelope(t: t, preset: preset, curve: curve) }
        let a = 0.5 + preset.curve0 * curve.a
        let b = 1 - preset.curve1 * curve.b
        let peak = a * length
        let half = (plotted < peak ? b * 1.2 : b * 0.8) * (length / 2)
        let width = abs(half) < 1e-6 ? 1e-6 : half
        let ratio = abs((plotted - peak) / width)
        let value = 1 / (1 + pow(ratio, 2 * curve.exponent))
        return preset.pressureMin + (preset.pressureMax - preset.pressureMin) * value
    }

    /// Live drag: taper toward `pressureMin` at both ends, sit on `pressureMax` in the body, then times the unit pressure.
    static func liveTaper(traveled: CGFloat, remain: CGFloat, taperLength: CGFloat, preset: NaturalBrushPreset, ending: Bool) -> CGFloat {
        let ends = preset.pressureMin
        let body = preset.pressureMax
        let span = max(taperLength, 0.001)
        let enter = min(1, max(0, traveled) / span)
        var pressure = ends + (body - ends) * enter
        if ending {
            let leave = min(1, max(0, remain) / span)
            pressure = ends + (pressure - ends) * leave
        }
        return pressure
    }

    /// Envelope (known span) or live taper, times a 0…1 touch. Unit 0 lays down nothing.
    static func pressure(unit: CGFloat, plotted: CGFloat, span: CGFloat?, remain: CGFloat, taperLength: CGFloat, preset: NaturalBrushPreset, seed: UInt64, ending: Bool) -> CGFloat {
        let touch = min(1, max(0, unit))
        let shape: CGFloat
        if let span, span > 1e-3 {
            shape = envelope(plotted: plotted, length: span, preset: preset, curve: curve(preset: preset, seed: seed))
        } else {
            shape = liveTaper(traveled: plotted, remain: remain, taperLength: taperLength, preset: preset, ending: ending)
        }
        return shape * touch
    }

    private static func linearEnvelope(t: CGFloat, preset: NaturalBrushPreset, curve: NaturalPressureCurve) -> CGFloat {
        let start = preset.pressureMin
        let end = preset.pressureMax
        let mid = (start + end) / 2
        let low = min(start, mid, end)
        let high = max(start, mid, end)
        let range = high - low
        let ns = range > 1e-6 ? (start - low) / range : 0
        let nm = range > 1e-6 ? (mid - low) / range : 0.5
        let ne = range > 1e-6 ? (end - low) / range : 1
        let warped = min(1, max(0, 0.5 + (t - 0.5 + curve.warp) * curve.scale))
        let shaped = warped < 0.5 ? ns + (nm - ns) * warped * 2 : nm + (ne - nm) * (warped - 0.5) * 2
        let raw = shaped + curve.exponent + curve.tilt * (t - 0.5)
        let mapped = low + (high - low) * raw
        return min(high, max(low, mapped))
    }
}

enum NaturalBrushEngine {
    /// Whole-stroke alpha wobble. Computed once from the seed and reused for every dab.
    static func strokeGain(kind: NaturalBrushKind, seed: UInt64) -> CGFloat {
        guard let preset = kind.preset else { return 1 }
        let strength = 0.1 * preset.noise
        guard strength > 0 else { return 1 }
        var rng = NaturalStepRNG(seed: seed, step: 0, channel: 99)
        return max(0, 1 + CGFloat(rng.gaussian(deviation: Double(strength))))
    }

    /// `pressureStart` and `pressureEnd` are unit touches (0 light, 1 firm), not preset min/max.
    /// `span` is the whole stroke when its length is known (a script, a hatch line). Nil is a live drag:
    /// the tip tapers toward `pressureMin` at both ends and sits on `pressureMax` in between.
    static func walk(segments: [(CGPoint, CGPoint)], pressureStart: CGFloat, pressureEnd: CGFloat, cursor: NaturalCursor, kind: NaturalBrushKind, diameter: CGFloat, seed: UInt64, gain: CGFloat, wiggle: CGFloat, ending: Bool, span: CGFloat? = nil) -> (dabs: [NaturalDab], cursor: NaturalCursor) {
        guard let preset = kind.preset, diameter > 0 else { return ([], cursor) }
        guard !segments.isEmpty else { return ([], cursor) }
        let spacing = spacing(preset, diameter: diameter)
        let taperLength = max(6, diameter * 0.4)
        var cursor = cursor
        var dabs: [NaturalDab] = []
        func touch(at traveled: CGFloat, unit: CGFloat, remain: CGFloat, ending: Bool) -> CGFloat {
            NaturalBrushMath.pressure(unit: unit, plotted: traveled, span: span, remain: remain, taperLength: taperLength, preset: preset, seed: seed, ending: ending)
        }
        if cursor.anchor == nil, let start = segments.first?.0 {
            let startPressure = touch(at: 0, unit: pressureStart, remain: taperLength, ending: false)
            if preset.tip == .marker {
                dabs += caps(at: start, pressure: startPressure, preset: preset, diameter: diameter, seed: seed, gain: gain, channel: 2)
            }
            // A click has to leave a mark even when grain would have skipped that one step.
            dabs += dab(at: start, pressure: startPressure, step: cursor.step, traveled: 0, direction: CGPoint(x: 1, y: 0), preset: preset, diameter: diameter, seed: seed, gain: gain, wiggle: wiggle, force: true)
            cursor.anchor = start
            cursor.leftover = spacing
            cursor.step += 1
        }
        let total = segments.reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        var covered: CGFloat = 0
        var traveled = cursor.traveled
        var leftover = cursor.leftover
        var step = cursor.step
        var anchor = cursor.anchor ?? segments[0].0
        for segment in segments {
            let delta = CGPoint(x: segment.1.x - segment.0.x, y: segment.1.y - segment.0.y)
            let length = hypot(delta.x, delta.y)
            if length < 1e-4 { continue }
            let direction = CGPoint(x: delta.x / length, y: delta.y / length)
            var distance = leftover
            while distance <= length && dabs.count < 8000 {
                let along = covered + distance
                let batch = total > 1e-4 ? along / total : 0
                let unit = pressureStart + (pressureEnd - pressureStart) * min(1, max(0, batch))
                let remain = max(0, total - along)
                let at = CGPoint(x: segment.0.x + delta.x * distance / length, y: segment.0.y + delta.y * distance / length)
                let here = traveled + distance
                dabs += dab(at: at, pressure: touch(at: here, unit: unit, remain: remain, ending: ending), step: step, traveled: here, direction: direction, preset: preset, diameter: diameter, seed: seed, gain: gain, wiggle: wiggle)
                step += 1
                distance += spacing
            }
            leftover = distance - length
            traveled += length
            covered += length
            anchor = segment.1
        }
        cursor.anchor = anchor
        cursor.leftover = leftover
        cursor.step = step
        cursor.traveled = traveled
        return (dabs, cursor)
    }

    /// The marker's heel, stamped at the start (channel 2) and again when the stroke ends (channel 3).
    static func endCaps(at point: CGPoint?, pressure: CGFloat, kind: NaturalBrushKind, diameter: CGFloat, seed: UInt64, gain: CGFloat) -> [NaturalDab] {
        guard let point, let preset = kind.preset, preset.tip == .marker else { return [] }
        return caps(at: point, pressure: pressure, preset: preset, diameter: diameter, seed: seed, gain: gain, channel: 3)
    }

    private static func spacing(_ preset: NaturalBrushPreset, diameter: CGFloat) -> CGFloat {
        // p5 keeps spacing in absolute units unless `scaleBrushes` is called. Scaling it
        // with Size keeps the same dab density at 12 px and at 80 px; an absolute 0.1 px
        // spacing would lay hundreds of dabs per pointer move.
        switch preset.tip {
        case .spray:
            // Size is the cloud diameter for spray, so the steps sit inside that cloud.
            return min(48, max(1.25, diameter * 0.12))
        case .standard, .marker:
            return min(max(0.35, diameter * 0.9), max(0.35, preset.spacing * diameter))
        }
    }

    private static func caps(at point: CGPoint, pressure: CGFloat, preset: NaturalBrushPreset, diameter: CGFloat, seed: UInt64, gain: CGFloat, channel: Int) -> [NaturalDab] {
        var dabs: [NaturalDab] = []
        for stamp in 1..<10 {
            let scaled = pressure * CGFloat(stamp) / 10
            dabs += markerDab(at: point, pressure: scaled, step: stamp, preset: preset, diameter: diameter, seed: seed, gain: gain, channel: channel, alphaScale: 8)
        }
        return dabs
    }

    private static func dab(at point: CGPoint, pressure: CGFloat, step: Int, traveled: CGFloat, direction: CGPoint, preset: NaturalBrushPreset, diameter: CGFloat, seed: UInt64, gain: CGFloat, wiggle: CGFloat, force: Bool = false) -> [NaturalDab] {
        switch preset.tip {
        case .marker:
            return markerDab(at: point, pressure: pressure, step: step, preset: preset, diameter: diameter, seed: seed, gain: gain, channel: 0, alphaScale: 1)
        case .spray:
            return sprayDabs(at: point, pressure: pressure, step: step, preset: preset, diameter: diameter, seed: seed, gain: gain)
        case .standard:
            return standardDab(at: point, pressure: pressure, step: step, traveled: traveled, direction: direction, preset: preset, diameter: diameter, seed: seed, gain: gain, wiggle: wiggle, force: force)
        }
    }

    private static func standardDab(at point: CGPoint, pressure: CGFloat, step: Int, traveled: CGFloat, direction: CGPoint, preset: NaturalBrushPreset, diameter: CGFloat, seed: UInt64, gain: CGFloat, wiggle: CGFloat, force: Bool) -> [NaturalDab] {
        var rng = NaturalStepRNG(seed: seed, step: step, channel: force ? 5 : 0)
        let safe = max(0.05, pressure)
        // Grain above 1 (charcoal, crayon) always lands; below 1 it skips some steps.
        if !force, rng.uniform(0, 1) >= Double(preset.grain * safe) { return [] }
        let gauss = rng.gaussian()
        let mix = preset.sharpness + ((1 - preset.sharpness) * CGFloat(gauss)) / safe
        let vibration = diameter * preset.scatter * mix
        let perpendicular = vibration * CGFloat(rng.uniform(-1, 1))
        let along = 0.3 * vibration * CGFloat(rng.uniform(-1, 1))
        var offset = CGPoint(x: -direction.y * perpendicular + direction.x * along, y: direction.x * perpendicular + direction.y * along)
        if wiggle > 0 {
            let amount = min(2, max(0, wiggle))
            let noise = FlowNoise.value(traveled / max(8, diameter), seed: seed)
            let push = diameter * 0.16 * amount * (noise * 2 - 1)
            offset.x += -direction.y * push
            offset.y += direction.x * push
        }
        let width = safe * safe * preset.weight * CGFloat(rng.uniform(0.85, 1.15)) * diameter
        let alpha = min(1, max(0, max(0.9, safe) * baseAlpha(preset, diameter: diameter) * gain * CGFloat(rng.uniform(0.75, 1.1)) / 255))
        guard width > 0.05, alpha > 0 else { return [] }
        return [NaturalDab(x: Float(point.x + offset.x), y: Float(point.y + offset.y), radius: Float(width / 2), alpha: Float(alpha))]
    }

    private static func markerDab(at point: CGPoint, pressure: CGFloat, step: Int, preset: NaturalBrushPreset, diameter: CGFloat, seed: UInt64, gain: CGFloat, channel: Int, alphaScale: CGFloat) -> [NaturalDab] {
        var rng = NaturalStepRNG(seed: seed, step: step, channel: channel)
        let vibration = diameter * preset.scatter
        let dx = vibration * CGFloat(rng.uniform(-1, 1))
        let dy = vibration * CGFloat(rng.uniform(-1, 1))
        let width = diameter * preset.weight * max(0.05, pressure)
        // Marker ends now press past 1 (pressureMin 1.2). That widens the tip; it should not
        // push the body to full opacity, or the heel stops reading darker.
        let alpha = min(1, max(0, min(1, max(0.8, pressure)) * baseAlpha(preset, diameter: diameter) * gain * alphaScale * CGFloat(rng.uniform(0.9, 1.1)) / 255))
        guard width > 0.05, alpha > 0 else { return [] }
        return [NaturalDab(x: Float(point.x + dx), y: Float(point.y + dy), radius: Float(width / 2), alpha: Float(alpha))]
    }

    private static func sprayDabs(at point: CGPoint, pressure: CGFloat, step: Int, preset: NaturalBrushPreset, diameter: CGFloat, seed: UInt64, gain: CGFloat) -> [NaturalDab] {
        var rng = NaturalStepRNG(seed: seed, step: step, channel: 0)
        let safe = max(0.05, pressure)
        // Size is the cloud diameter. p5's scatter of 6 would otherwise be several times
        // the Size number, because there the cloud grows with stroke weight and the dots do not.
        let cloud = (diameter / 2) * safe
        let gauss = CGFloat(rng.gaussian())
        let vibration = max(0.5, cloud + (cloud * gauss) / 3)
        let particle = max(0.6, diameter * 0.018) * CGFloat(rng.uniform(0.9, 1.1))
        let alpha = min(1, max(0, baseAlpha(preset, diameter: diameter) * gain / 255))
        let count = min(28, max(1, Int((preset.grain / safe).rounded(.up))))
        var dabs: [NaturalDab] = []
        dabs.reserveCapacity(count)
        for _ in 0..<count {
            let ring = CGFloat(rng.uniform(0.9, 1.1)) * vibration
            let rx = ring * CGFloat(rng.uniform(-1, 1))
            let room = max(0, ring * ring - rx * rx)
            let ry = CGFloat(rng.uniform(-1, 1)) * sqrt(room)
            dabs.append(NaturalDab(x: Float(point.x + rx), y: Float(point.y + ry), radius: Float(particle / 2), alpha: Float(alpha)))
        }
        return dabs
    }

    /// Value on p5.brush's 0–255 scale, which `circle()` then divides by 255.
    /// Pencils store that scale directly. The marker stores `1` and thins it with
    /// `min(strokeWeight, 1.3)`. Leaving that fraction on the 0–1 scale and also
    /// dividing by 255 would make the marker nearly invisible, including the heel's ×8.
    private static func baseAlpha(_ preset: NaturalBrushPreset, diameter: CGFloat) -> CGFloat {
        switch preset.tip {
        case .standard, .spray: return preset.opacity
        case .marker:
            let thinned = preset.opacity / min(max(diameter, 0.01), 1.3)
            return thinned * 255
        }
    }
}

/// Seeded smooth noise along the stroke. This is the live stand-in for p5.brush's flow field:
/// `brush.wiggle` deflects a stroke by a noise field, and a perpendicular push is that deflection
/// while the pointer is still moving.
enum FlowNoise {
    static func value(_ x: CGFloat, seed: UInt64) -> CGFloat {
        let base = floor(x)
        let t = x - base
        let smooth = t * t * (3 - 2 * t)
        let left = hash(Int(base), seed: seed)
        let right = hash(Int(base) + 1, seed: seed)
        return left + (right - left) * smooth
    }
    private static func hash(_ index: Int, seed: UInt64) -> CGFloat {
        var n = UInt64(bitPattern: Int64(index)) &+ seed &* 0x9E3779B97F4A7C15
        n ^= n >> 30
        n &*= 0xBF58476D1CE4E5B9
        n ^= n >> 27
        return CGFloat(n % 10_000) / 10_000
    }
}

/// Source-over coverage, the CPU twin of the `naturalBrush` Metal kernel.
enum NaturalCoverage {
    static func mask(distance: Float, radius: Float, hardness: Float) -> Float {
        guard radius > 0 else { return 0 }
        let hard = hardDisc(distance: distance, radius: radius)
        if hardness >= 1 { return hard }
        let u = min(1, max(0, distance / radius))
        let k: Float = 2.5
        let feather = max(0, (exp(-k * u * u) - exp(-k)) / (1 - exp(-k)))
        let blend = min(1, max(0, hardness))
        return feather + (hard - feather) * blend
    }

    static func stamp(_ dabs: [NaturalDab], into buffer: inout [Float], width: Int, height: Int, origin: CGPoint, mapping: CGAffineTransform, hardness: CGFloat, canvas: CGSize) {
        guard width > 0, height > 0, buffer.count >= width * height else { return }
        let det = mapping.a * mapping.d - mapping.b * mapping.c
        guard abs(det) > 1e-8 else { return }
        let inverseA = mapping.d / det, inverseB = -mapping.b / det, inverseC = -mapping.c / det, inverseD = mapping.a / det
        let scale = max(0.001, min(hypot(mapping.a, mapping.b), hypot(mapping.c, mapping.d)))
        let hard = Float(hardness)
        for dab in dabs where dab.radius > 0 && dab.alpha > 0 {
            let dx = CGFloat(dab.x) - origin.x, dy = CGFloat(dab.y) - origin.y
            let localX = inverseA * dx + inverseC * dy
            let localY = inverseB * dx + inverseD * dy
            let reach = CGFloat(dab.radius) / scale + 2
            let minX = max(0, Int(floor(localX - reach)))
            let maxX = min(width - 1, Int(ceil(localX + reach)))
            let minY = max(0, Int(floor(localY - reach)))
            let maxY = min(height - 1, Int(ceil(localY + reach)))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let px = origin.x + (CGFloat(x) + 0.5) * mapping.a + (CGFloat(y) + 0.5) * mapping.c
                    let py = origin.y + (CGFloat(x) + 0.5) * mapping.b + (CGFloat(y) + 0.5) * mapping.d
                    guard px >= 0, py >= 0, px < canvas.width, py < canvas.height else { continue }
                    let dist = hypot(px - CGFloat(dab.x), py - CGFloat(dab.y))
                    let src = dab.alpha * mask(distance: Float(dist), radius: dab.radius, hardness: hard)
                    guard src > 0 else { continue }
                    let index = y * width + x
                    buffer[index] += src * (1 - buffer[index])
                }
            }
        }
    }

    static func bytes(_ buffer: [Float]) -> [UInt8] {
        buffer.map { UInt8(clamping: Int((min(1, max(0, $0)) * 255).rounded())) }
    }

    /// The hard disc p5's point shader draws: solid inside, a ~0.75 px smooth edge.
    private static func hardDisc(distance: Float, radius: Float) -> Float {
        let aa: Float = 0.75
        let t = (distance - (radius - aa)) / (2 * aa)
        let x = min(1, max(0, t))
        return 1 - x * x * (3 - 2 * x)
    }
}

struct HatchLine: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
    /// Joins the previous line to this one when hatch is continuous.
    var connector: Bool = false
}

/// Remembered settings for Edit > Hatch Selection, and the extra fields on a hatch op.
struct HatchOptions: Equatable, Sendable {
    var angle: CGFloat = 45
    var spacing: CGFloat? = nil
    var rand: CGFloat = 0
    var continuous: Bool = false
    var gradient: CGFloat = 0
    /// Nil keeps the brush already chosen. A preset is hatch-only and jitters size by 10 percent per line.
    var brush: NaturalBrushKind? = nil
    var diameter: CGFloat? = nil
    var red: CGFloat? = nil
    var green: CGFloat? = nil
    var blue: CGFloat? = nil
}

/// Classic scanline hatch from p5.brush `src/hatch/hatch.js`: rotate the contour, cut it with
/// horizontal lines, rotate the chords back. Crossings pair up, so a hole stays open.
enum NaturalHatch {
    static func lines(contours: [[CGPoint]], angle: CGFloat, spacing: CGFloat, seed: UInt64, jitter: CGFloat = 0, continuous: Bool = false, gradient: CGFloat = 0) -> [HatchLine] {
        let gap = max(1, spacing)
        let rad = angle * CGFloat.pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        struct Edge { var y1, x1, y2, x2: CGFloat }
        var edges: [Edge] = []
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for contour in contours where contour.count >= 3 {
            var rotated: [(CGFloat, CGFloat)] = []
            rotated.reserveCapacity(contour.count)
            for point in contour {
                let x = point.x * cosA - point.y * sinA
                let y = point.x * sinA + point.y * cosA
                rotated.append((x, y))
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
            for index in rotated.indices {
                let next = rotated[(index + 1) % rotated.count]
                let current = rotated[index]
                if current.1 != next.1 { edges.append(Edge(y1: current.1, x1: current.0, y2: next.1, x2: next.0)) }
            }
        }
        guard !edges.isEmpty, maxY > minY else { return [] }
        var lines: [HatchLine] = []
        var y = minY + gap * 0.5
        var step = gap
        let growth = gradient > 0 ? min(1.1, max(1, 1 + min(1, gradient) * 0.1)) : 1
        var rng = NaturalRNG(seed: seed == 0 ? 1 : seed)
        var scan = 0
        while y < maxY && lines.count < 4000 {
            var crossings: [CGFloat] = []
            for edge in edges where (edge.y1 <= y) != (edge.y2 <= y) {
                crossings.append(edge.x1 + ((y - edge.y1) / (edge.y2 - edge.y1)) * (edge.x2 - edge.x1))
            }
            crossings.sort()
            var index = 0
            while index + 1 < crossings.count {
                var x1 = crossings[index], x2 = crossings[index + 1]
                var y1 = y, y2 = y
                if jitter > 0 {
                    let reach = 2 * jitter * gap
                    x1 += CGFloat(rng.uniform(Double(-reach), Double(reach)))
                    y1 += CGFloat(rng.uniform(Double(-reach), Double(reach)))
                    x2 += CGFloat(rng.uniform(Double(-reach), Double(reach)))
                    y2 += CGFloat(rng.uniform(Double(-reach), Double(reach)))
                }
                let start = CGPoint(x: x1 * cosA + y1 * sinA, y: -x1 * sinA + y1 * cosA)
                var end = CGPoint(x: x2 * cosA + y2 * sinA, y: -x2 * sinA + y2 * cosA)
                var lineStart = start
                if continuous, scan % 2 == 1 { swap(&lineStart, &end) }
                if hypot(end.x - lineStart.x, end.y - lineStart.y) >= 0.5 {
                    if continuous, let previous = lines.last {
                        lines.append(HatchLine(start: previous.end, end: lineStart, connector: true))
                    }
                    lines.append(HatchLine(start: lineStart, end: end))
                }
                index += 2
            }
            y += step
            step *= growth
            scan += 1
        }
        return lines
    }
}
