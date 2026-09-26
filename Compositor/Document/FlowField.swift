import CoreGraphics

// Flow fields from p5.brush `src/core/flowfield.js` (MIT, Alejandro Campos Uribe).
// The grid is one percent of the canvas wide and covers half a canvas past each edge.
// Each cell holds an angle in degrees. A step headed `dir` actually moves along `dir - field`,
// which is how `Position.movePos` steers a stroke. `wiggle` scales the stored angle.
// Custom fields are a numeric grid: JavaScript callbacks are not run.

struct FlowField: Equatable, Sendable {
    var name: String
    var wiggle: CGFloat
    var resolution: CGFloat
    var left: CGFloat
    var top: CGFloat
    var columns: Int
    var rows: Int
    /// Column-major degrees, index `column * rows + row`, before `wiggle`.
    var angles: [Float]

    func angle(at point: CGPoint) -> CGFloat {
        guard resolution > 0, columns > 0, rows > 0 else { return 0 }
        let column = Int(((point.x - left) / resolution).rounded())
        let row = Int(((point.y - top) / resolution).rounded())
        guard column >= 0, row >= 0, column < columns, row < rows else { return 0 }
        return CGFloat(angles[column * rows + row]) * wiggle
    }

    /// Points of a stroke after the field has bent each step. A nil field leaves the samples alone.
    func steer(_ samples: [StrokeSample], step: CGFloat) -> [StrokeSample] {
        guard samples.count >= 2, abs(wiggle) > 1e-4 else { return samples }
        var result: [StrokeSample] = [samples[0]]
        var position = CGPoint(x: samples[0].x, y: samples[0].y)
        let stride = max(0.75, step)
        for sample in samples.dropFirst() {
            let target = CGPoint(x: sample.x, y: sample.y)
            var remain = hypot(target.x - position.x, target.y - position.y)
            let direction = atan2(target.y - position.y, target.x - position.x) * 180 / CGFloat.pi
            while remain > 0.05 && result.count < 6000 {
                let length = min(stride, remain)
                let heading = (direction - angle(at: position)) * CGFloat.pi / 180
                position.x += cos(heading) * length
                position.y += sin(heading) * length
                remain -= length
                result.append(StrokeSample(x: position.x, y: position.y, pressure: sample.pressure, time: nil))
            }
        }
        return result
    }

    func steer(_ lines: [HatchLine], step: CGFloat) -> [HatchLine] {
        guard abs(wiggle) > 1e-4 else { return lines }
        var steered: [HatchLine] = []
        for line in lines {
            let samples = steer([
                StrokeSample(x: line.start.x, y: line.start.y, pressure: nil, time: nil),
                StrokeSample(x: line.end.x, y: line.end.y, pressure: nil, time: nil)
            ], step: step)
            guard samples.count >= 2 else { continue }
            for index in 1..<samples.count {
                steered.append(HatchLine(start: CGPoint(x: samples[index - 1].x, y: samples[index - 1].y),
                                         end: CGPoint(x: samples[index].x, y: samples[index].y), connector: line.connector))
            }
        }
        return steered
    }

    /// `flowLine`: `length` points from `(x, y)` headed `direction` degrees, bent by the field.
    func flowLine(x: CGFloat, y: CGFloat, length: CGFloat, direction: CGFloat, pressure: CGFloat?) -> [StrokeSample] {
        let step = max(1.25, length / 400)
        var samples = [StrokeSample(x: x, y: y, pressure: pressure, time: nil)]
        var position = CGPoint(x: x, y: y)
        var traveled: CGFloat = 0
        while traveled < length && samples.count < 6000 {
            let bit = min(step, length - traveled)
            let heading = (direction - angle(at: position)) * CGFloat.pi / 180
            position.x += cos(heading) * bit
            position.y += sin(heading) * bit
            traveled += bit
            samples.append(StrokeSample(x: position.x, y: position.y, pressure: pressure, time: nil))
        }
        return samples
    }

    /// Built-in names, plus `custom` when `angles` is a row-major grid. `none` returns nil.
    static func make(name: String, wiggle: CGFloat, seed: UInt64, canvas: CGSize, columns customColumns: Int? = nil, rows customRows: Int? = nil, angles customAngles: [CGFloat]? = nil) -> FlowField? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        if key == "none" || key == "off" || key == "nofield" { return nil }
        let width = max(canvas.width, 1), height = max(canvas.height, 1)
        let resolution = width * 0.01
        var columns = max(1, Int((2 * width / resolution).rounded()))
        var rows = max(1, Int((2 * height / resolution).rounded()))
        if key == "custom", let customAngles, !customAngles.isEmpty {
            if let customColumns, customColumns > 0 { columns = customColumns }
            if let customRows, customRows > 0 { rows = customRows }
            if customColumns == nil, customRows == nil, let side = Int(Double(customAngles.count).squareRoot()), side * side == customAngles.count {
                columns = side
                rows = side
            }
        }
        var field = FlowField(name: key, wiggle: wiggle, resolution: resolution, left: -0.5 * width, top: -0.5 * height,
                              columns: columns, rows: rows, angles: Array(repeating: 0, count: columns * rows))
        if key == "custom", let customAngles {
            let count = min(customAngles.count, field.angles.count)
            for index in 0..<count {
                let row = index / columns
                let column = index % columns
                guard row < rows else { break }
                field.angles[column * rows + row] = Float(customAngles[index])
            }
            field.name = "custom"
            return field
        }
        var rng = NaturalRNG(seed: seed == 0 ? 1 : seed)
        switch key {
        case "hand": fillHand(&field, rng: &rng, time: 0)
        case "curved": fillCurved(&field, rng: &rng, time: 0)
        case "zigzag": fillZigzag(&field, rng: &rng, time: 0)
        case "waves": fillWaves(&field, rng: &rng, time: 0)
        case "seabed": fillSeabed(&field, rng: &rng, time: 0)
        case "spiral": fillSpiral(&field, rng: &rng)
        case "columns": fillColumns(&field, rng: &rng)
        default: return nil
        }
        return field
    }

    static let builtInNames = ["hand", "curved", "zigzag", "waves", "seabed", "spiral", "columns"]
}

private func sind(_ degrees: Double) -> Double { sin(degrees * Double.pi / 180) }
private func cosd(_ degrees: Double) -> Double { cos(degrees * Double.pi / 180) }

private func randInt(_ rng: inout NaturalRNG, _ low: Double, _ high: Double) -> Int {
    Int(rng.uniform(low, high))
}

private func fillHand(_ field: inout FlowField, rng: inout NaturalRNG, time: Double) {
    let spread = rng.uniform(0.2, 0.8)
    let amount = Double(randInt(&rng, 5, 10))
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            let phase = Double(randInt(&rng, 15, 25))
            let angle = 0.5 * amount * sind(spread * Double(row * column) + phase)
            let value = 0.2 * angle * cosd(time) + Double(FlowNoise.value(CGFloat(column), seed: UInt64(bitPattern: Int64(row)) &+ 99)) * amount * 0.7
            field.angles[column * field.rows + row] = Float(value)
        }
    }
}

private func fillCurved(_ field: inout FlowField, rng: inout NaturalRNG, time: Double) {
    var reach = Double(randInt(&rng, -10, 10))
    if randInt(&rng, 0, 100) % 2 == 0 { reach *= -1 }
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            let sample = Double(FlowNoise.value(CGFloat(Double(column) * 0.02 + time * 0.03), seed: UInt64(row)))
            let value = 3 * (sample * (reach - (-reach)) + (-reach))
            field.angles[column * field.rows + row] = Float(value)
        }
    }
}

private func fillZigzag(_ field: inout FlowField, rng: inout NaturalRNG, time: Double) {
    var reach = Double(randInt(&rng, -30, -15)) + abs(44 * sind(time))
    if randInt(&rng, 0, 100) % 2 == 0 { reach *= -1 }
    var step = reach
    var angle = 0.0
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            field.angles[column * field.rows + row] = Float(angle)
            angle += step
            step *= -1
        }
        angle += step
        step *= -1
    }
}

private func fillWaves(_ field: inout FlowField, rng: inout NaturalRNG, time: Double) {
    let rowFrequency = Double(randInt(&rng, 10, 15)) + 5 * sind(time)
    let columnFrequency = Double(randInt(&rng, 3, 6)) + 3 * cosd(time)
    let amount = Double(randInt(&rng, 20, 35))
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            let wobble = Double(randInt(&rng, -3, 3))
            let value = sind(rowFrequency * Double(column)) * amount * cosd(Double(row) * columnFrequency) + wobble
            field.angles[column * field.rows + row] = Float(value)
        }
    }
}

private func fillSeabed(_ field: inout FlowField, rng: inout NaturalRNG, time: Double) {
    let spread = rng.uniform(0.4, 0.8)
    let amount = Double(randInt(&rng, 18, 26))
    let phase = Double(randInt(&rng, 15, 20))
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            let value = 1.1 * amount * sind(spread * Double(row * column) + phase) * cosd(time)
            field.angles[column * field.rows + row] = Float(value)
        }
    }
}

private func fillSpiral(_ field: inout FlowField, rng: inout NaturalRNG) {
    let count = max(1, randInt(&rng, 5, 10))
    let direction = Double(randInt(&rng, 0, 2) * 2 - 1)
    let offset = Double(randInt(&rng, 65, 80))
    var attractors: [(Double, Double)] = []
    for _ in 0..<count {
        attractors.append((rng.uniform(0.1, 0.9) * Double(field.columns), rng.uniform(0.1, 0.9) * Double(field.rows)))
    }
    for column in 0..<field.columns {
        for row in 0..<field.rows {
            var weightX = 0.0, weightY = 0.0
            for attractor in attractors {
                let dx = Double(column) - attractor.0, dy = Double(row) - attractor.1
                let weight = 1 / (dx * dx + dy * dy + 1)
                let bearing = atan2(dy, dx) * 180 / Double.pi
                let angle = direction * (bearing + offset) * Double.pi / 180
                weightX += weight * cos(angle)
                weightY += weight * sin(angle)
            }
            field.angles[column * field.rows + row] = Float(atan2(weightY, weightX) * 180 / Double.pi)
        }
    }
}

private func fillColumns(_ field: inout FlowField, rng: inout NaturalRNG) {
    let frequency = Double(randInt(&rng, 3, 8))
    let amount = Double(randInt(&rng, 25, 45))
    for column in 0..<field.columns {
        let value = Float(sind(Double(column) * frequency) * amount)
        for row in 0..<field.rows { field.angles[column * field.rows + row] = value }
    }
}
