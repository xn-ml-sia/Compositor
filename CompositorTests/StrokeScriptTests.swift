import AppKit
import Testing
@testable import Compositor

@MainActor
struct StrokeScriptTests {
    private let clearInk = "{\"op\":\"clear\",\"layer\":\"Ink\"}\n"
    private let clearPetal = "{\"op\":\"clear\",\"layer\":\"Petal\"}\n"

    @Test func parsesTheOpsAScriptWrites() throws {
        let line = """
        {"op":"brush","preset":"cpencil","diameter":18,"color":[0.2,0.4,0.9,1],"opacity":0.8,"hardness":0.4,"wiggle":0.5,"erase":false,"layer":"Petals"}
        """
        let brush = try #require(StrokeScriptReader.parse(line))
        guard case .brush(let settings) = brush else { Issue.record("expected a brush"); return }
        #expect(settings.preset == .coloredPencil)
        #expect(settings.diameter == 18)
        #expect(abs(settings.red - 0.2) < 0.0001 && abs(settings.blue - 0.9) < 0.0001)
        #expect(abs(settings.opacity - 0.8) < 0.0001 && abs(settings.hardness - 0.4) < 0.0001 && settings.wiggle == 0.5)
        #expect(settings.layer == "Petals" && settings.erase == false)
        let stroke = try #require(StrokeScriptReader.parse("{\"op\":\"stroke\",\"layer\":\"Petals\",\"seed\":\"42\",\"pace\":\"fast\",\"points\":[[1,2],[3,4,0.5,1.5]]}"))
        guard case .stroke(let draw) = stroke else { Issue.record("expected a stroke"); return }
        #expect(draw.seed == 42 && draw.pace == .fast && draw.points.count == 2)
        #expect(draw.points[0].pressure == nil && draw.points[1].pressure == 0.5 && draw.points[1].time == 1.5)
        let hatch = try #require(StrokeScriptReader.parse("{\"op\":\"hatch\",\"layer\":\"Petals\",\"polygon\":[[0,0],[10,0],[10,8]],\"angle\":30,\"spacing\":6}"))
        guard case .hatch(let lines) = hatch else { Issue.record("expected a hatch"); return }
        #expect(lines.angle == 30 && lines.spacing == 6 && lines.red == nil)
        #expect(StrokeScriptReader.parse("{\"op\":\"nope\"}") == nil)
        let field = try #require(StrokeScriptReader.parse("{\"op\":\"field\",\"name\":\"waves\",\"wiggle\":1.5,\"seed\":3}"))
        guard case .field(let waves) = field else { Issue.record("expected a field"); return }
        #expect(waves.name == "waves" && waves.wiggle == 1.5 && waves.seed == 3)
        #expect(StrokeScriptReader.parse("{\"op\":\"field\",\"name\":\"none\"}") != nil)
        let spline = try #require(StrokeScriptReader.parse("{\"op\":\"spline\",\"layer\":\"Petals\",\"curvature\":0,\"points\":[[0,0],[12,4,0.5]],\"outline\":true}"))
        guard case .figure(let shape) = spline else { Issue.record("expected a spline"); return }
        #expect(shape.outline && shape.fill == nil)
        guard case .spline(let samples, let curvature) = shape.geometry else { Issue.record("expected spline geometry"); return }
        #expect(curvature == 0 && samples.count == 2 && samples[1].pressure == 0.5)
        let wash = try #require(StrokeScriptReader.parse("{\"op\":\"watercolor\",\"layer\":\"Petals\",\"polygon\":[[0,0],[8,0],[4,6]],\"color\":[0.2,0.3,0.4],\"bleed\":0.2,\"direction\":\"in\",\"clip\":true,\"scatter\":false,\"opacity\":180}"))
        guard case .watercolor(let fill) = wash else { Issue.record("expected a watercolor"); return }
        #expect(fill.options.bleed == 0.2 && fill.options.outward == false && fill.options.clip && fill.options.scatter == false)
        #expect(fill.options.opacity == 180)
        #expect(StrokeScriptReader.kind(named: "2B") == .pencil2B)
        #expect(StrokeScriptReader.kind(named: "Charcoal") == .charcoal)
    }

    @Test func timesFollowDistanceAndAnExplicitClock() {
        let points = [
            StrokeSample(x: 0, y: 0, pressure: nil, time: nil),
            StrokeSample(x: 640, y: 0, pressure: nil, time: nil)
        ]
        let live = StrokeTiming.times(points, pace: .live)
        let fast = StrokeTiming.times(points, pace: .fast)
        #expect(live[0] == 0)
        #expect(abs(live[1] - 1) < 0.0001)
        #expect(abs(fast[1] - 0.125) < 0.0001)
        let timed = [
            StrokeSample(x: 0, y: 0, pressure: nil, time: 0),
            StrokeSample(x: 10, y: 0, pressure: nil, time: 2)
        ]
        #expect(StrokeTiming.times(timed, pace: .live)[1] == 2)
        #expect(abs(StrokeTiming.times(timed, pace: .fast)[1] - 0.25) < 0.0001)
    }

    @Test func aPartialLineStaysUnconsumedAndAFinishedTailIsNotReadTwice() {
        let partial = Data((clearInk + "{\"op\":\"clear\"").utf8)
        let first = StrokeScriptReader.pull(partial, from: 0)
        #expect(first.items.count == 1)
        #expect(first.items[0].op == .clear(layer: "Ink"))
        #expect(first.offset < partial.count)
        let held = StrokeScriptReader.pull(partial, from: first.offset)
        #expect(held.items.isEmpty && held.offset == first.offset)
        let finished = Data((clearInk + clearPetal).utf8)
        let second = StrokeScriptReader.pull(finished, from: first.offset)
        #expect(second.items.count == 1)
        #expect(second.items[0].op == .clear(layer: "Petal"))
        let replay = StrokeScriptReader.pull(finished, from: second.offset)
        #expect(replay.items.isEmpty && replay.offset == second.offset)
    }

    @Test func theCursorSkipsLinesAlreadyPlayedAndAShorterFileDoesNotRepaint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorStrokeScript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent(StrokeScriptReader.scriptName)
        try Data((clearInk + clearPetal).utf8).write(to: script)
        let played = StrokeScriptReader.readNew(in: root)
        #expect(played.items.count == 2)
        StrokeScriptReader.storeCursor(played.offset, in: root)
        #expect(StrokeScriptReader.readNew(in: root).items.isEmpty)
        try Data(clearInk.utf8).write(to: script)
        #expect(StrokeScriptReader.readNew(in: root).items.isEmpty)
        #expect(StrokeScriptReader.rawCursor(in: root) == Data(clearInk.utf8).count)
        let extra = clearInk + "{\"op\":\"clear\",\"layer\":\"Leaf\"}\n"
        try Data(extra.utf8).write(to: script)
        let added = StrokeScriptReader.readNew(in: root)
        #expect(added.items.count == 1 && added.items[0].op == .clear(layer: "Leaf"))
    }

    @Test func appendingTheScriptDoesNotChangeThePackageDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorStrokeDigest-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Demo.comp", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"format\":\"com.compositor.project\"}\n".utf8).write(to: package.appendingPathComponent("manifest.json"))
        let before = try ProjectDigest.compute(for: package)
        try Data(clearInk.utf8).write(to: package.appendingPathComponent(StrokeScriptReader.scriptName))
        StrokeScriptReader.storeCursor(Data(clearInk.utf8).count, in: package)
        #expect(try ProjectDigest.compute(for: package) == before)
    }

    @Test func savingThePackageKeepsTheStrokeScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorStrokeSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("Kept.comp", isDirectory: true)
        let session = EditorSession()
        session.createDocument(width: 32, height: 32, emptyLayer: true)
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        let script = Data(clearInk.utf8)
        let cursor = Data("4\n".utf8)
        try script.write(to: package.appendingPathComponent(StrokeScriptReader.scriptName))
        try cursor.write(to: package.appendingPathComponent(StrokeScriptReader.cursorName))
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        #expect(try Data(contentsOf: package.appendingPathComponent(StrokeScriptReader.scriptName)) == script)
        #expect(try Data(contentsOf: package.appendingPathComponent(StrokeScriptReader.cursorName)) == cursor)
    }

    @Test func theSameSeedPaintsTheSamePixelsAndEachStrokeIsItsOwnUndo() async throws {
        let ops = flowerStroke(seed: 42)
        let first = try await paint(ops)
        let second = try await paint(ops)
        #expect(first.name == "HB Stroke")
        #expect(first.undoCount >= 2)
        #expect(first.image.width == second.image.width && first.painted == second.painted)
        #expect(first.pixels == second.pixels)
        #expect(first.painted > 20)
    }

    @Test func aWatercolorOpFillsThePolygonAndReplaysFromTheSeed() async throws {
        let polygon = [CGPoint(x: 16, y: 12), CGPoint(x: 100, y: 14), CGPoint(x: 96, y: 64), CGPoint(x: 18, y: 60)]
        let ops = [StrokeOp.watercolor(StrokeFill(layer: "Layer 1", polygon: polygon, red: 0.15, green: 0.35, blue: 0.8, seed: 5))]
        let first = try await paint(ops, createLayer: false)
        let second = try await paint(ops, createLayer: false)
        #expect(first.name == "Watercolor Fill")
        #expect(first.pixels == second.pixels)
        #expect(first.painted > 20)
    }

    private func flowerStroke(seed: UInt64) -> [StrokeOp] {
        let brush = StrokeScriptBrush(preset: .hb, diameter: 22, red: 0.1, green: 0.2, blue: 0.9, opacity: 1, hardness: 1, wiggle: 0, erase: false, layer: nil)
        let draw = StrokeDraw(layer: "Flower", seed: seed, pace: .fast, points: [
            StrokeSample(x: 12, y: 40, pressure: 1, time: nil),
            StrokeSample(x: 60, y: 42, pressure: 1, time: nil),
            StrokeSample(x: 100, y: 38, pressure: 1, time: nil)
        ])
        return [.layer(name: "Flower", id: nil), .brush(brush), .stroke(draw)]
    }

    private struct Painted {
        var image: CGImage
        var pixels: [UInt8]
        var painted: Int
        var name: String
        var undoCount: Int
    }

    private func paint(_ ops: [StrokeOp], createLayer: Bool = true) async throws -> Painted {
        let session = EditorSession()
        session.createDocument(width: 120, height: 80, emptyLayer: !createLayer)
        if createLayer { session.addBlankLayer() }
        await session.playStrokeScript(ops, instant: true)
        #expect(session.brushError == nil)
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        var painted = 0
        for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 0 { painted += 1 }
        return Painted(image: image, pixels: bytes, painted: painted, name: session.history.undoName, undoCount: session.history.undoCount)
    }
}
