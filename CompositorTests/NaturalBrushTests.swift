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
        let light = NaturalBrushMath.presetPressure(unit: NaturalBrushMath.unitPressure(hardware: 0, from: nil, to: .zero, diameter: 40), preset: preset)
        let firm = NaturalBrushMath.presetPressure(unit: NaturalBrushMath.unitPressure(hardware: 1, from: nil, to: .zero, diameter: 40), preset: preset)
        #expect(light == min(preset.pressureMin, preset.pressureMax))
        #expect(firm == max(preset.pressureMin, preset.pressureMax))
        let slow = NaturalBrushMath.unitPressure(hardware: nil, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 0), diameter: 40)
        let fast = NaturalBrushMath.unitPressure(hardware: nil, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 0), diameter: 40)
        #expect(slow > 0.8)
        #expect(fast == 0)
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
        #expect(passes.count == 10)
        #expect(passes.count == replay.count)
        #expect(passes[1].polygons.first?.first == replay[1].polygons.first?.first)
        // A rectangle starts with four corners. Growing inserts a point on every edge.
        #expect((passes.first?.polygons.first?.count ?? 0) > 4)
        #expect(!(passes.last?.erases.isEmpty ?? true))
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
