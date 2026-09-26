import AppKit
import Testing
@testable import Compositor

struct NaturalBrushTests {
    private func segment(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) { (a, b) }

    @Test func layoutMatchesTheMetalDab() {
        #expect(MemoryLayout<NaturalDab>.size == 16)
        #expect(MemoryLayout<NaturalDab>.stride == 16)
    }

    @Test func presetsKeepTheP5Numbers() throws {
        let hb = try #require(NaturalBrushKind.hb.preset)
        #expect(hb.weight == 0.3 && hb.scatter == 0.6 && hb.sharpness == 0.3)
        #expect(hb.grain == 0.7 && hb.opacity == 170 && hb.spacing == 0.1)
        #expect(hb.pressureMin == 1.1 && hb.pressureMax == 0.9 && hb.tip == .standard)
        let charcoal = try #require(NaturalBrushKind.charcoal.preset)
        #expect(charcoal.scatter == 1.5 && charcoal.grain == 2 && charcoal.spacing == 0.03)
        #expect(NaturalBrushKind.marker.preset?.tip == .marker)
        #expect(NaturalBrushKind.spray.preset?.tip == .spray && NaturalBrushKind.spray.preset?.grain == 40)
        #expect(NaturalBrushKind.pastel.preset?.noise == 1)
        #expect(NaturalBrushKind.round.preset == nil)
    }

    @Test func sameSeedReplaysTheSameDabs() {
        let line = [segment(CGPoint(x: 0, y: 0), CGPoint(x: 180, y: 12))]
        let first = NaturalBrushEngine.walk(segments: line, pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .hb, diameter: 24, seed: 42, gain: 1, wiggle: 0, ending: false)
        let second = NaturalBrushEngine.walk(segments: line, pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .hb, diameter: 24, seed: 42, gain: 1, wiggle: 0, ending: false)
        #expect(first.dabs == second.dabs)
        #expect(first.cursor == second.cursor)
        #expect(!first.dabs.isEmpty)
        let other = NaturalBrushEngine.walk(segments: line, pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .hb, diameter: 24, seed: 99, gain: 1, wiggle: 0, ending: false)
        #expect(other.dabs != first.dabs)
    }

    /// Walking a polyline in two pieces, carrying the cursor, matches walking it at once.
    /// The join is not stamped twice, and redrawing the second piece as a tail does not move the cursor.
    @Test func splitWalkMatchesTheWholeAndATailDoesNotDoubleCount() {
        let start = CGPoint(x: 10, y: 40)
        let mid = CGPoint(x: 90, y: 48)
        let end = CGPoint(x: 160, y: 36)
        let whole = NaturalBrushEngine.walk(segments: [segment(start, mid), segment(mid, end)], pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .charcoal, diameter: 28, seed: 7, gain: 1, wiggle: 0, ending: false)
        let first = NaturalBrushEngine.walk(segments: [segment(start, mid)], pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .charcoal, diameter: 28, seed: 7, gain: 1, wiggle: 0, ending: false)
        let second = NaturalBrushEngine.walk(segments: [segment(mid, end)], pressureStart: 1, pressureEnd: 1, cursor: first.cursor, kind: .charcoal, diameter: 28, seed: 7, gain: 1, wiggle: 0, ending: false)
        #expect(first.dabs + second.dabs == whole.dabs)
        #expect(second.cursor == whole.cursor)
        let tail = NaturalBrushEngine.walk(segments: [segment(mid, end)], pressureStart: 1, pressureEnd: 1, cursor: first.cursor, kind: .charcoal, diameter: 28, seed: 7, gain: 1, wiggle: 0, ending: false)
        let tailAgain = NaturalBrushEngine.walk(segments: [segment(mid, end)], pressureStart: 1, pressureEnd: 1, cursor: first.cursor, kind: .charcoal, diameter: 28, seed: 7, gain: 1, wiggle: 0, ending: false)
        #expect(tail.dabs == tailAgain.dabs)
        #expect(tail.dabs == second.dabs)
        // The committed cursor is the value we passed in; replaying the tail did not require consuming it.
        #expect(first.cursor.step < second.cursor.step)
        #expect(first.dabs.count + second.dabs.count == whole.dabs.count)
    }

    @Test func aClickLeavesOneDabAndAMarkerLeavesAHeel() {
        let click = NaturalBrushEngine.walk(segments: [segment(CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 4))], pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .hb, diameter: 20, seed: 3, gain: 1, wiggle: 0, ending: false)
        #expect(click.dabs.count == 1)
        #expect(click.cursor.step == 1)
        let marker = NaturalBrushEngine.walk(segments: [segment(CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 4))], pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .marker, diameter: 20, seed: 3, gain: 1, wiggle: 0, ending: false)
        // Nine heel stamps plus the body dab. The body stays visibly inked; the heel is darker.
        #expect(marker.dabs.count == 10)
        #expect((marker.dabs.last?.alpha ?? 0) > 0.4)
        #expect((marker.dabs.first?.alpha ?? 0) > (marker.dabs.last?.alpha ?? 0))
        let caps = NaturalBrushEngine.endCaps(at: CGPoint(x: 4, y: 4), pressure: 1, kind: .marker, diameter: 20, seed: 3, gain: 1)
        #expect(caps.count == 9)
        #expect(NaturalBrushEngine.endCaps(at: CGPoint(x: 4, y: 4), pressure: 1, kind: .hb, diameter: 20, seed: 3, gain: 1).isEmpty)
    }

    @Test func pressureMapsTabletToThePresetAndSpeedForAMouse() throws {
        let preset = try #require(NaturalBrushKind.marker.preset)
        let light = NaturalBrushMath.pressure(unit: 0, plotted: 80, span: nil, remain: 80, taperLength: 16, preset: preset, seed: 1, ending: false)
        let firmBody = NaturalBrushMath.pressure(unit: 1, plotted: 80, span: nil, remain: 80, taperLength: 16, preset: preset, seed: 1, ending: false)
        let firmEnd = NaturalBrushMath.pressure(unit: 1, plotted: 0, span: nil, remain: 0, taperLength: 16, preset: preset, seed: 1, ending: true)
        #expect(light == 0)
        #expect(abs(firmBody - preset.pressureMax) < 0.001)
        #expect(abs(firmEnd - preset.pressureMin) < 0.001)
        let slow = NaturalBrushMath.unitPressure(hardware: nil, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 0), diameter: 40)
        let fast = NaturalBrushMath.unitPressure(hardware: nil, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 0), diameter: 40)
        #expect(slow > 0.8)
        #expect(fast == 0)
    }

    @Test func scriptedPressureSitsOnThePlateauAndCrayonRamps() throws {
        let pen = try #require(NaturalBrushKind.pen.preset)
        let curve = NaturalBrushMath.curve(preset: pen, seed: 4)
        let start = NaturalBrushMath.envelope(plotted: 0, length: 200, preset: pen, curve: curve)
        let mid = NaturalBrushMath.envelope(plotted: 100, length: 200, preset: pen, curve: curve)
        let end = NaturalBrushMath.envelope(plotted: 200, length: 200, preset: pen, curve: curve)
        #expect(start > mid && end > mid)
        #expect(start > 1.05 && end > 1.05)
        #expect(mid < 1.05)
        let again = NaturalBrushMath.envelope(plotted: 0, length: 200, preset: pen, curve: NaturalBrushMath.curve(preset: pen, seed: 4))
        #expect(start == again)
        let crayon = try #require(NaturalBrushKind.crayon.preset)
        let ramp = NaturalBrushMath.curve(preset: crayon, seed: 9)
        let from = NaturalBrushMath.envelope(plotted: 0, length: 100, preset: crayon, curve: ramp)
        let to = NaturalBrushMath.envelope(plotted: 100, length: 100, preset: crayon, curve: ramp)
        #expect(from > to)
        #expect(from > 1.0 && to < 1.0)
        let line = [segment(CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0))]
        let known = NaturalBrushEngine.walk(segments: line, pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .pen, diameter: 12, seed: 4, gain: 1, wiggle: 0, ending: true, span: 200)
        let replay = NaturalBrushEngine.walk(segments: line, pressureStart: 1, pressureEnd: 1, cursor: .start, kind: .pen, diameter: 12, seed: 4, gain: 1, wiggle: 0, ending: true, span: 200)
        #expect(known.dabs == replay.dabs)
        #expect(!known.dabs.isEmpty)
    }

    @Test func stampingATailTwiceDoesNotChangeThePermanentCoverage() {
        var permanent = [Float](repeating: 0, count: 32 * 32)
        let settled = [NaturalDab(x: 16, y: 16, radius: 5, alpha: 0.45)]
        let tail = [NaturalDab(x: 20, y: 16, radius: 4, alpha: 0.5)]
        let canvas = CGSize(width: 32, height: 32)
        NaturalCoverage.stamp(settled, into: &permanent, width: 32, height: 32, origin: .zero, mapping: .identity, hardness: 1, canvas: canvas)
        let committed = permanent
        var preview = committed
        NaturalCoverage.stamp(tail, into: &preview, width: 32, height: 32, origin: .zero, mapping: .identity, hardness: 1, canvas: canvas)
        var again = committed
        NaturalCoverage.stamp(tail, into: &again, width: 32, height: 32, origin: .zero, mapping: .identity, hardness: 1, canvas: canvas)
        #expect(preview == again)
        #expect(permanent == committed)
        #expect(preview[16 * 32 + 16] >= committed[16 * 32 + 16])
        NaturalCoverage.stamp(settled, into: &permanent, width: 32, height: 32, origin: .zero, mapping: .identity, hardness: 1, canvas: canvas)
        #expect(permanent[16 * 32 + 16] > committed[16 * 32 + 16])
    }

    @Test func hatchLinesStayInsideARectangleAndReplay() {
        let square = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 80), CGPoint(x: 10, y: 80)]
        let lines = NaturalHatch.lines(contours: [square], angle: 45, spacing: 8, seed: 11, jitter: 0)
        let again = NaturalHatch.lines(contours: [square], angle: 45, spacing: 8, seed: 11, jitter: 0)
        #expect(lines == again)
        #expect(lines.count > 3)
        for line in lines {
            #expect(line.start.x >= 9 && line.start.x <= 111)
            #expect(line.end.x >= 9 && line.end.x <= 111)
            #expect(line.start.y >= 9 && line.start.y <= 81)
            #expect(line.end.y >= 9 && line.end.y <= 81)
        }
    }

    @Test func watercolorPassesAreStableAndGrowPastTheOutline() {
        let rect = [CGPoint(x: 20, y: 20), CGPoint(x: 140, y: 20), CGPoint(x: 140, y: 100), CGPoint(x: 20, y: 100)]
        let passes = WatercolorFill.passes(contours: [rect], seed: 5, bleed: 0.07, texture: 0.8, border: 0.5)
        let replay = WatercolorFill.passes(contours: [rect], seed: 5, bleed: 0.07, texture: 0.8, border: 0.5)
        #expect(passes.count == 20)
        #expect(passes.count == replay.count)
        #expect(passes[1].polygons.first?.first == replay[1].polygons.first?.first)
        // A rectangle starts with four corners. Growing inserts a point on every edge.
        #expect((passes.first?.polygons.first?.count ?? 0) > 4)
        #expect(!(passes.last?.erases.isEmpty ?? true))
        #expect(passes.contains { !$0.darker.isEmpty })
        let outside = passes.contains { pass in
            pass.polygons.contains { polygon in
                polygon.contains { $0.x < 19 || $0.x > 141 || $0.y < 19 || $0.y > 101 }
            }
        }
        #expect(outside)
        let clipped = WatercolorFill.passes(contours: [rect], seed: 5, options: WatercolorOptions(scatter: false, clip: true))
        #expect(clipped.count == 20)
        #expect(clipped.allSatisfy { $0.scatterPolygons.isEmpty })
    }

    @Test func denseCoverageDarkensThePigmentAndAFlatWashDoesNot() {
        let firm = NaturalShade.brushPigment(red: 1, green: 0.2, blue: 0.2, alpha: 1, opacity: 1)
        let light = NaturalShade.brushPigment(red: 1, green: 0.2, blue: 0.2, alpha: 0.4, opacity: 1)
        #expect(firm.red < 0.9)
        #expect(light.red == 1)
        #expect(abs(firm.alpha - 1) < 0.001)
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 32 * 8)
        for index in 0..<64 {
            pixels[index * 4] = 200
            pixels[index * 4 + 1] = 40
            pixels[index * 4 + 2] = 40
            pixels[index * 4 + 3] = 180
        }
        NaturalShade.cpuDarkenRims(in: context)
        #expect(pixels[3] == 180)
    }

    @Test func aFlowFieldBendsALineAndReplays() throws {
        let canvas = CGSize(width: 200, height: 160)
        let waves = try #require(FlowField.make(name: "waves", wiggle: 1, seed: 3, canvas: canvas))
        let again = try #require(FlowField.make(name: "waves", wiggle: 1, seed: 3, canvas: canvas))
        #expect(waves.angles == again.angles)
        #expect(waves.angles.contains { abs($0) > 1 })
        #expect(FlowField.make(name: "none", wiggle: 1, seed: 1, canvas: canvas) == nil)
        let bent = waves.flowLine(x: 20, y: 80, length: 100, direction: 0, pressure: 1)
        #expect(bent.contains { abs($0.y - 80) > 0.5 })
        let hand = try #require(FlowField.make(name: "hand", wiggle: 2, seed: 1, canvas: canvas))
        #expect(hand.wiggle == 2)
        // The hand field wobbles around zero like p5's simplex noise; it does not tilt every line one way.
        let mean = hand.angles.reduce(0, +) / Float(hand.angles.count)
        #expect(abs(mean) < 1.5)
        #expect(hand.angles.contains { $0 > 2 } && hand.angles.contains { $0 < -2 })
        let custom = try #require(FlowField.make(name: "custom", wiggle: 1, seed: 1, canvas: canvas, columns: 2, rows: 2, angles: [0, 90, 10, 20]))
        #expect(custom.angles.count == 4)
    }

    @Test func aWashFringeHasNoLongStraightTeeth() {
        // An arc (a long chord beside short arc sides) and a dense circle used to grow single
        // triangles on 35–80 px sides: the regular sawtooth along a fill's edge. Every drawn
        // polygon now stays in short, uneven pieces.
        var arc: [CGPoint] = []
        for index in 0...32 {
            let radians = (200 + 140 * CGFloat(index) / 32) * .pi / 180
            arc.append(CGPoint(x: 200 + 140 * cos(radians), y: 150 - 140 * sin(radians)))
        }
        var circle: [CGPoint] = []
        for index in 0..<160 {
            let radians = CGFloat(index) / 160 * 2 * .pi
            circle.append(CGPoint(x: 550 + 140 * cos(radians), y: 200 + 140 * sin(radians)))
        }
        for contour in [arc, circle] {
            for seed in [UInt64(1), 7, 62] {
                let passes = WatercolorFill.passes(contours: [contour], seed: seed, options: WatercolorOptions(bleed: 0.08))
                var longest: CGFloat = 0
                for pass in passes {
                    for polygon in pass.polygons + pass.darker + pass.scatterPolygons where polygon.count > 2 {
                        for index in polygon.indices {
                            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                            longest = max(longest, hypot(b.x - a.x, b.y - a.y))
                        }
                    }
                }
                #expect(longest < 42, "seed \(seed): longest side \(longest)")
            }
        }
    }

    @Test func aSplitWashSideStillBleedsOutward() {
        // Splitting long sides must not flatten the bleed: a 0.12 outward wash on a 200×150 rectangle
        // still reaches several pixels past the outline (splitting into flat pieces reached 2–4).
        let rect = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 150), CGPoint(x: 0, y: 150)]
        var total: CGFloat = 0
        let seeds: [UInt64] = [1, 7, 21, 44]
        for seed in seeds {
            var reach: CGFloat = 0
            for pass in WatercolorFill.passes(contours: [rect], seed: seed, options: WatercolorOptions(bleed: 0.12)) {
                for polygon in pass.polygons {
                    for point in polygon {
                        reach = max(reach, -point.x, point.x - 200, -point.y, point.y - 150)
                    }
                }
            }
            total += reach
        }
        #expect(total / CGFloat(seeds.count) > 5)
    }

    @Test func retintPutsAFaintWashBackOnItsInk() throws {
        let context = try BrushRaster.context(width: 4, height: 1, mask: false)
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 16)
        // Premultiplied (122, 122, 163) at alpha 25 has drifted far from the ink (0.2, 0.45, 0.8).
        for (index, value) in [12, 12, 16, 25, 0, 0, 0, 0, 40, 90, 160, 200, 1, 1, 1, 1].enumerated() { pixels[index] = UInt8(value) }
        NaturalShade.retint(context, red: 0.2, green: 0.45, blue: 0.8)
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 16)) == [5, 11, 20, 25, 0, 0, 0, 0, 40, 90, 160, 200, 0, 0, 1, 1])
    }

    @Test func continuousHatchAddsConnectorsAndGradientOpensTheGap() {
        let square = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 80), CGPoint(x: 10, y: 80)]
        let plain = NaturalHatch.lines(contours: [square], angle: 0, spacing: 8, seed: 2)
        let joined = NaturalHatch.lines(contours: [square], angle: 0, spacing: 8, seed: 2, continuous: true)
        #expect(plain.allSatisfy { $0.connector == false })
        #expect(joined.contains { $0.connector })
        #expect(joined.count > plain.count)
        let tight = NaturalHatch.lines(contours: [square], angle: 0, spacing: 6, seed: 2)
        let spread = NaturalHatch.lines(contours: [square], angle: 0, spacing: 6, seed: 2, gradient: 1)
        #expect(spread.count < tight.count)
    }

    @Test func aStraightSplineIsThePolylineAndACircleHasManySteps() {
        let points = [
            StrokeSample(x: 0, y: 0, pressure: 1, time: nil),
            StrokeSample(x: 40, y: 0, pressure: 1, time: nil),
            StrokeSample(x: 40, y: 30, pressure: 0.5, time: nil)
        ]
        let flat = ShapeGeometry.spline(points, curvature: 0, closed: false, seed: 1)
        #expect(flat == points)
        let bent = ShapeGeometry.spline(points, curvature: 0.8, closed: false, seed: 1)
        #expect(bent.count > flat.count)
        let round = ShapeGeometry.build(.circle(x: 50, y: 50, radius: 20, irregularity: 0.2), field: nil, seed: 4)
        #expect(round.samples.count > 10)
        // A circle stays centred on (x, y) at about its radius, not a square beside it.
        let distances = round.samples.map { hypot($0.x - 50, $0.y - 50) }
        #expect(distances.allSatisfy { $0 > 14 && $0 < 26 })
        let meanX = round.samples.map(\.x).reduce(0, +) / CGFloat(round.samples.count)
        #expect(abs(meanX - 50) < 4)
        let perfect = ShapeGeometry.build(.circle(x: 0, y: 0, radius: 30, irregularity: 0), field: nil, seed: 9)
        #expect(perfect.samples.allSatisfy { abs(hypot($0.x, $0.y) - 30) < 0.01 })
        // p5.brush's arc runs counter-clockwise on screen: 0° is right, 90° is up (smaller y).
        let quarter = ShapeGeometry.build(.arc(x: 0, y: 0, radius: 10, start: 0, end: 90), field: nil, seed: 1)
        #expect(abs(quarter.samples.first!.x - 10) < 0.01 && abs(quarter.samples.first!.y) < 0.01)
        #expect(abs(quarter.samples.last!.x) < 0.01 && abs(quarter.samples.last!.y + 10) < 0.01)
        let box = ShapeGeometry.build(.rect(x: 0, y: 0, width: 10, height: 8, centered: false), field: nil, seed: 1)
        #expect(box.samples.count == 5)
        #expect(box.samples[2].x == 10 && box.samples[2].y == 8)
    }

    @Test func contoursFlattenARectangle() {
        let path = CGPath(rect: CGRect(x: 4, y: 6, width: 30, height: 12), transform: nil)
        let contours = SelectionContours.make(from: path)
        #expect(contours.count == 1)
        #expect(contours[0].count >= 4)
    }

    @MainActor
    @Test func anHBStrokeCommitsUnderItsOwnNameAndReplaysFromTheSeed() async throws {
        func paint(seed: UInt64) async throws -> CGImage {
            let session = EditorSession()
            session.createDocument(width: 120, height: 80)
            session.addBlankLayer()
            session.selectTool(.brush)
            var settings = BrushSettings(diameter: 22, hardness: 1, red: 0.1, green: 0.2, blue: 0.9, opacity: 1)
            settings.natural = .hb
            settings.naturalSeed = seed
            session.brushSettings = settings
            session.beginBrush(at: CGPoint(x: 12, y: 40))
            session.continueBrush(at: CGPoint(x: 60, y: 42))
            session.continueBrush(at: CGPoint(x: 100, y: 38))
            session.finishBrushImmediately()
            #expect(session.history.undoName == "HB Stroke")
            #expect(session.brushError == nil)
            return try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        }
        let first = try await paint(seed: 42)
        let second = try await paint(seed: 42)
        let context = { (image: CGImage) -> CGContext in
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return ctx
        }
        let a = context(first), b = context(second)
        let left = a.data!.assumingMemoryBound(to: UInt8.self)
        let right = b.data!.assumingMemoryBound(to: UInt8.self)
        var painted = 0
        for y in 0..<first.height {
            for x in 0..<first.width {
                let index = (y * first.width + x) * 4
                #expect(left[index] == right[index] && left[index + 3] == right[index + 3])
                if left[index + 3] > 0 { painted += 1 }
            }
        }
        #expect(painted > 20)
    }
}
