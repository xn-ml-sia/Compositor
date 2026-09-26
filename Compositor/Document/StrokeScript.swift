import CoreGraphics
import Foundation

// A stroke script is `strokes.jsonl` in the project package: one JSON object per line, append-only.
// The open app tails it and paints through the same brush a drag uses. `strokes.cursor` is the byte
// offset already played, so reopening the project does not paint those lines again.
//
// The package digest covers the manifest and `images/` only, so appending here does not reload the
// document or clear undo. See docs/stroke-playback.md.

/// How fast a scripted stroke is played. `1` matches a hand at `StrokeTiming.livePixelsPerSecond`.
struct StrokePace: Equatable, Sendable {
    var multiplier: CGFloat
    static let live = StrokePace(multiplier: 1)
    static let fast = StrokePace(multiplier: 8)
    static func clamped(_ value: CGFloat) -> StrokePace {
        StrokePace(multiplier: min(100, max(0.05, value.isFinite ? value : 1)))
    }
}

struct StrokeSample: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    /// 0 is a light touch, 1 is firm. Nil lets the brush use speed, the same fallback a mouse has.
    var pressure: CGFloat?
    /// Seconds from the start of this stroke. Nil spaces the point by distance instead.
    var time: CGFloat?
}

struct StrokeScriptBrush: Equatable, Sendable {
    var preset: NaturalBrushKind
    var diameter: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var opacity: CGFloat
    var hardness: CGFloat
    var wiggle: CGFloat
    var erase: Bool
    var layer: String?

    init(preset: NaturalBrushKind, diameter: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat, hardness: CGFloat, wiggle: CGFloat, erase: Bool, layer: String?) {
        self.preset = preset
        self.diameter = min(2000, max(1, diameter))
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.opacity = min(1, max(0.01, opacity))
        self.hardness = min(1, max(0, hardness))
        self.wiggle = min(2, max(0, wiggle))
        self.erase = erase
        self.layer = layer
    }

    init(settings: BrushSettings, erase: Bool) {
        self.init(preset: settings.natural, diameter: settings.diameter, red: settings.red, green: settings.green, blue: settings.blue,
                  opacity: settings.opacity, hardness: settings.hardness, wiggle: settings.wiggle, erase: erase, layer: nil)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value.isFinite ? value : 0)) }
}

struct StrokeDraw: Equatable, Sendable {
    var layer: String?
    var seed: UInt64?
    var pace: StrokePace
    var points: [StrokeSample]
}

struct StrokeFill: Equatable, Sendable {
    var layer: String
    var polygon: [CGPoint]
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var seed: UInt64?
}

struct StrokeHatch: Equatable, Sendable {
    var layer: String
    var polygon: [CGPoint]
    var angle: CGFloat
    var spacing: CGFloat?
    var seed: UInt64?
    /// Nil keeps the brush color already set.
    var red: CGFloat?
    var green: CGFloat?
    var blue: CGFloat?
}

enum StrokeOp: Equatable, Sendable {
    case layer(name: String, id: UUID?)
    case brush(StrokeScriptBrush)
    case stroke(StrokeDraw)
    case watercolor(StrokeFill)
    case hatch(StrokeHatch)
    case clear(layer: String)
}

struct StrokeScriptItem: Equatable, Sendable {
    var op: StrokeOp?
    /// Byte offset just past this line, including its newline.
    var endOffset: Int
    var error: String?
}

enum StrokeTiming {
    /// A comfortable hand, used when a point does not carry its own time.
    static let livePixelsPerSecond: CGFloat = 640

    /// Seconds from the start of the stroke, already scaled by the pace.
    static func times(_ points: [StrokeSample], pace: StrokePace) -> [CGFloat] {
        let speed = livePixelsPerSecond * pace.multiplier
        var elapsed: CGFloat = 0
        var previous: StrokeSample?
        return points.map { point in
            if let time = point.time {
                elapsed = time / pace.multiplier
            } else if let previous {
                elapsed += hypot(point.x - previous.x, point.y - previous.y) / speed
            }
            previous = point
            return elapsed
        }
    }
}

enum StrokeScriptReader {
    static let scriptName = "strokes.jsonl"
    static let cursorName = "strokes.cursor"

    /// Complete lines after `offset`. A trailing line with no newline stays unconsumed, so a writer
    /// can be mid-append. `offset` comes back at the end of the last complete line.
    static func pull(_ data: Data, from offset: Int) -> (items: [StrokeScriptItem], offset: Int) {
        let start = min(max(0, offset), data.count)
        var cursor = start
        var items: [StrokeScriptItem] = []
        while cursor < data.count {
            guard let newline = data[cursor..<data.count].firstIndex(of: 0x0A) else { break }
            let end = newline + 1
            var line = data[cursor..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            cursor = end
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if let op = parse(text) {
                items.append(StrokeScriptItem(op: op, endOffset: end, error: nil))
            } else {
                items.append(StrokeScriptItem(op: nil, endOffset: end, error: "Skipped a stroke line that is not a known op."))
            }
        }
        return (items, cursor)
    }

    static func parse(_ line: String) -> StrokeOp? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["op"] as? String else { return nil }
        switch name {
        case "layer":
            guard let layerName = string(object["name"]), !layerName.isEmpty else { return nil }
            return .layer(name: layerName, id: uuid(object["id"]))
        case "brush":
            guard let brush = brush(object) else { return nil }
            return .brush(brush)
        case "stroke":
            guard let points = points(object["points"]), !points.isEmpty else { return nil }
            return .stroke(StrokeDraw(layer: string(object["layer"]), seed: seed(object["seed"]), pace: pace(object["pace"]), points: points))
        case "watercolor":
            guard let fill = fill(object) else { return nil }
            return .watercolor(fill)
        case "hatch":
            guard let layer = string(object["layer"]), let polygon = polygon(object["polygon"]), polygon.count >= 3 else { return nil }
            let spacing = double(object["spacing"]).map { CGFloat(max(1, $0)) }
            let angle = CGFloat(double(object["angle"]) ?? 45)
            let ink = color(object["color"])
            return .hatch(StrokeHatch(layer: layer, polygon: polygon, angle: angle.isFinite ? angle : 45, spacing: spacing, seed: seed(object["seed"]), red: ink?.0, green: ink?.1, blue: ink?.2))
        case "clear":
            guard let layer = string(object["layer"]), !layer.isEmpty else { return nil }
            return .clear(layer: layer)
        default:
            return nil
        }
    }

    /// New ops after the cursor, and the offset at the end of the last complete line (comments included).
    /// A cursor past the end of a shortened file is pulled back to the end and saved, so a later append
    /// is still seen and the old lines are not painted again.
    static func readNew(in package: URL) -> (items: [StrokeScriptItem], offset: Int) {
        let url = package.appendingPathComponent(scriptName)
        guard let data = try? Data(contentsOf: url) else { return ([], rawCursor(in: package)) }
        let stored = rawCursor(in: package)
        if stored > data.count {
            storeCursor(data.count, in: package)
            return ([], data.count)
        }
        return pull(data, from: stored)
    }

    static func rawCursor(in package: URL) -> Int {
        let url = package.appendingPathComponent(cursorName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return 0 }
        return value
    }

    static func storeCursor(_ offset: Int, in package: URL) {
        let url = package.appendingPathComponent(cursorName)
        let body = Data("\(max(0, offset))\n".utf8)
        try? body.write(to: url, options: .atomic)
    }

    static func kind(named value: String) -> NaturalBrushKind? {
        if let exact = NaturalBrushKind(rawValue: value) { return exact }
        switch value.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") {
        case "round": return .round
        case "hb": return .hb
        case "2b": return .pencil2B
        case "2h": return .pencil2H
        case "cpencil", "coloredpencil", "colouredpencil": return .coloredPencil
        case "charcoal": return .charcoal
        case "pastel": return .pastel
        case "crayon": return .crayon
        case "marker": return .marker
        case "pen": return .pen
        case "rotring": return .rotring
        case "spray": return .spray
        default: return nil
        }
    }

    private static func brush(_ object: [String: Any]) -> StrokeScriptBrush? {
        guard let presetName = string(object["preset"]), let preset = kind(named: presetName) else { return nil }
        let color = color(object["color"]) ?? (0, 0, 0, 1)
        let opacity = double(object["opacity"]).map { CGFloat($0) } ?? color.3
        return StrokeScriptBrush(preset: preset, diameter: CGFloat(double(object["diameter"]) ?? 40),
                                  red: color.0, green: color.1, blue: color.2, opacity: opacity,
                                  hardness: CGFloat(double(object["hardness"]) ?? 1),
                                  wiggle: CGFloat(double(object["wiggle"]) ?? 0),
                                  erase: bool(object["erase"]) ?? false, layer: string(object["layer"]))
    }

    private static func fill(_ object: [String: Any]) -> StrokeFill? {
        guard let layer = string(object["layer"]), !layer.isEmpty, let polygon = polygon(object["polygon"]), polygon.count >= 3,
              let color = color(object["color"]) else { return nil }
        return StrokeFill(layer: layer, polygon: polygon, red: color.0, green: color.1, blue: color.2, seed: seed(object["seed"]))
    }

    private static func pace(_ value: Any?) -> StrokePace {
        if let text = value as? String {
            if text.lowercased() == "fast" { return .fast }
            return .live
        }
        if let number = double(value) { return .clamped(CGFloat(number)) }
        return .live
    }

    private static func points(_ value: Any?) -> [StrokeSample]? {
        guard let list = value as? [Any] else { return nil }
        var samples: [StrokeSample] = []
        for item in list {
            guard let coords = item as? [Any], coords.count >= 2, let x = double(coords[0]), let y = double(coords[1]),
                  x.isFinite, y.isFinite else { return nil }
            let pressure = coords.count >= 3 ? optionalDouble(coords[2]).map { CGFloat(min(1, max(0, $0))) } : nil
            let time = coords.count >= 4 ? optionalDouble(coords[3]).map { CGFloat(max(0, $0)) } : nil
            samples.append(StrokeSample(x: CGFloat(x), y: CGFloat(y), pressure: pressure, time: time))
        }
        return samples
    }

    private static func polygon(_ value: Any?) -> [CGPoint]? {
        guard let list = value as? [Any] else { return nil }
        var points: [CGPoint] = []
        for item in list {
            guard let coords = item as? [Any], coords.count >= 2, let x = double(coords[0]), let y = double(coords[1]),
                  x.isFinite, y.isFinite else { return nil }
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    static func polygonPath(_ points: [CGPoint]) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func color(_ value: Any?) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let list = value as? [Any], list.count >= 3, let red = double(list[0]), let green = double(list[1]), let blue = double(list[2]) else { return nil }
        let alpha = list.count >= 4 ? (double(list[3]) ?? 1) : 1
        func unit(_ channel: Double) -> CGFloat { CGFloat(min(1, max(0, channel.isFinite ? channel : 0))) }
        return (unit(red), unit(green), unit(blue), unit(alpha))
    }

    private static func seed(_ value: Any?) -> UInt64? {
        if value is NSNull { return nil }
        if let text = value as? String { return UInt64(text) }
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value >= 0, value <= Double(UInt64(1) << 53), value.rounded() == value else { return nil }
        return UInt64(value)
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let text = string(value) else { return nil }
        return UUID(uuidString: text)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if value is NSNull || value == nil { return nil }
        if value is String { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func optionalDouble(_ value: Any?) -> Double? {
        if value is NSNull { return nil }
        return double(value)
    }
}
