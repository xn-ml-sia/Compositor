import AppKit
import Testing
@testable import Compositor

@MainActor
struct SeiShinTemplateTests {
    @Test func theSampleProjectExportsAStemAndAFlowerAndIgnoresTheCursorAndMacGuides() async throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/SeiShinSample.comp", isDirectory: true)
        let script = try Data(contentsOf: package.appendingPathComponent(StrokeScriptReader.scriptName))
        // The cursor sits past the file, so playback has nothing left. Export still reads every line.
        // pull, not readNew: readNew would rewrite the fixture's cursor.
        #expect(StrokeScriptReader.rawCursor(in: package) > script.count)
        #expect(StrokeScriptReader.pull(script, from: StrokeScriptReader.rawCursor(in: package)).items.isEmpty)
        let snapshot = try await ProjectStore.shared.load(from: package)
        #expect(snapshot.manifest.guides?.contains { $0.axis == .horizontal } == true)
        let destination = try temporary("Camellia.ikebana")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let exported = try SeiShinTemplateExporter.export(snapshot: snapshot, script: script, to: destination)
        #expect(exported.warnings.isEmpty)
        let manifest = try object(destination.appendingPathComponent("manifest.json"))
        #expect(manifest["format"] as? String == "com.seiandshin.template")
        #expect((manifest["version"] as? NSNumber)?.intValue == 1)
        #expect(manifest["id"] as? String == "camellia")
        #expect(manifest["name"] as? String == "Camellia")
        #expect(manifest["guides"] == nil)
        let body = try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!body.contains("horizontal"))
        #expect(!body.contains("D4E5F6A7-B8C9-4D0E-8F2A-3B4C5D6E7F80"))
        let canvas = try #require(manifest["canvas"] as? [String: Any])
        #expect((canvas["width"] as? NSNumber)?.intValue == 40)
        #expect((canvas["height"] as? NSNumber)?.intValue == 60)
        let elements = try #require(manifest["elements"] as? [[String: Any]])
        #expect(elements.count == 2)
        let stem = elements[0], flower = elements[1]
        #expect(stem["id"] as? String == "stem-main" && stem["kind"] as? String == "stem")
        #expect(isJSONNull(stem["parent"]))
        #expect((stem["z"] as? NSNumber)?.intValue == 0)
        #expect((stem["flipX"] as? NSNumber)?.boolValue == false)
        expectPoint(stem["anchor"], 1, 26)
        expectPoint(stem["center"], 15, 38)
        #expect(near(stem["rotation"], 0) && near(stem["scale"], 1))
        let centerline = try #require(stem["centerline"] as? [Any])
        #expect(centerline.count == 2)
        expectPoint(centerline[0], 1, 26)
        expectPoint(centerline[1], 1, 0)
        #expect(stem["image"] as? String == "stem-main.png")
        #expect(try pngSize(destination.appendingPathComponent("images/stem-main.png")) == (2, 26))

        #expect(flower["id"] as? String == "camellia" && flower["kind"] as? String == "flower")
        #expect(flower["parent"] as? String == "stem-main")
        #expect((flower["z"] as? NSNumber)?.intValue == 1)
        #expect(near(flower["attach"], 1))
        expectPoint(flower["offset"], 0, 9)
        #expect(near(flower["localRotation"], 90) && near(flower["localScale"], 1))
        expectPoint(flower["anchor"], 4, 4)
        #expect((flower["flipX"] as? NSNumber)?.boolValue == false)
        #expect(flower["center"] == nil && flower["centerline"] == nil && flower["rotation"] == nil)
        #expect(try pngSize(destination.appendingPathComponent("images/camellia.png")) == (8, 8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("images/paper.png").path))
    }

    @Test func reexportKeepsGuidesAndABrokenGuidesObjectIsLeftAlone() async throws {
        let snapshot = try vessel(side: 8)
        let destination = try temporary("Kept.ikebana")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try SeiShinTemplateExporter.export(snapshot: snapshot.project, script: snapshot.script, to: destination)
        var manifest = try object(destination.appendingPathComponent("manifest.json"))
        manifest["guides"] = [
            "origin": [640, 1580],
            "shinLength": 900,
            "note": "kept",
            "rays": [
                ["role": "shin", "angle": -12, "length": 1, "marker": "circle"] as [String: Any],
                ["role": "soe", "angle": -45, "length": 0.75, "marker": "square"] as [String: Any],
                ["role": "hikae", "angle": 75, "length": 0.5, "marker": "triangle"] as [String: Any]
            ]
        ] as [String: Any]
        try write(manifest, to: destination)
        _ = try SeiShinTemplateExporter.export(snapshot: snapshot.project, script: snapshot.script, to: destination)
        let kept = try object(destination.appendingPathComponent("manifest.json"))
        let guides = try #require(kept["guides"] as? [String: Any])
        expectPoint(guides["origin"], 640, 1580)
        #expect(near(guides["shinLength"], 900))
        #expect(guides["note"] as? String == "kept")
        let rays = try #require(guides["rays"] as? [[String: Any]])
        #expect(rays.count == 3)
        #expect(rays[0]["role"] as? String == "shin" && near(rays[0]["angle"], -12) && rays[0]["marker"] as? String == "circle")
        #expect(rays[1]["role"] as? String == "soe" && near(rays[1]["angle"], -45) && near(rays[1]["length"], 0.75))
        #expect(rays[2]["role"] as? String == "hikae" && near(rays[2]["angle"], 75) && rays[2]["marker"] as? String == "triangle")
        let elements = try #require(kept["elements"] as? [[String: Any]])
        #expect(elements.first?["id"] as? String == "vase")

        manifest = kept
        manifest["guides"] = ["origin": [1, 2]]
        try write(manifest, to: destination)
        let broken = failure { _ = try SeiShinTemplateExporter.export(snapshot: snapshot.project, script: snapshot.script, to: destination) }
        #expect(broken.contains("guides"))
        let still = try object(destination.appendingPathComponent("manifest.json"))
        let origin = try #require((still["guides"] as? [String: Any])?["origin"] as? [Any])
        #expect((origin[0] as? NSNumber)?.intValue == 1 && (origin[1] as? NSNumber)?.intValue == 2)
        #expect((still["elements"] as? [[String: Any]])?.first?["id"] as? String == "vase")
    }

    @Test func documentPointsLandInTheTrimmedImage() throws {
        var turned = LayerTransform(origin: CGPoint(x: 45, y: 45), size: CGSize(width: 10, height: 10))
        turned.rotation = 90
        let center = SeiShinTemplateExporter.imagePoint(CGPoint(x: 50, y: 50), transform: turned, width: 10, height: 10)
        let below = SeiShinTemplateExporter.imagePoint(CGPoint(x: 50, y: 60), transform: turned, width: 10, height: 10)
        #expect(abs(center.x - 5) < 0.001 && abs(center.y - 5) < 0.001)
        #expect(abs(below.x - 15) < 0.001 && abs(below.y - 5) < 0.001)

        let id = UUID()
        let image = try rgba(width: 10, height: 10) { _, _ in (20, 40, 80, 255) }
        let upright = layer(id: id, name: "Vase", origin: CGPoint(x: 45, y: 45), size: CGSize(width: 10, height: 10), rotation: 90)
        let project = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [upright]),
                                      images: [id: ImportedImage(image: image, thumbnail: image, name: "Vase")])
        let destination = try temporary("Turned.ikebana")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let script = element("vase", kind: "vessel", layer: id, anchor: [50, 60])
        _ = try SeiShinTemplateExporter.export(snapshot: project, script: Data(script.utf8), to: destination)
        let record = try onlyElement(at: destination)
        expectPoint(record["anchor"], 15, 5)
        expectPoint(record["center"], 50, 60)
        #expect(near(record["rotation"], 90) && near(record["scale"], 1))
        #expect(try pngSize(destination.appendingPathComponent("images/vase.png")) == (10, 10))
    }

    @Test func uniformAndNonUniformScaleAndOpacity() throws {
        let uniform = try exportOne(pixels: 10, displayed: CGSize(width: 20, height: 20), opacity: 1)
        defer { try? FileManager.default.removeItem(at: uniform.url.deletingLastPathComponent()) }
        #expect(near(uniform.record["scale"], 2))
        #expect(try pngSize(uniform.url.appendingPathComponent("images/vase.png")) == (10, 10))

        let stretched = try exportOne(pixels: 10, displayed: CGSize(width: 20, height: 10), opacity: 1)
        defer { try? FileManager.default.removeItem(at: stretched.url.deletingLastPathComponent()) }
        #expect(near(stretched.record["scale"], 1))
        #expect(try pngSize(stretched.url.appendingPathComponent("images/vase.png")) == (20, 10))

        let faded = try exportOne(pixels: 2, displayed: CGSize(width: 2, height: 2), opacity: 0.5)
        defer { try? FileManager.default.removeItem(at: faded.url.deletingLastPathComponent()) }
        let alpha = try alphas(faded.url.appendingPathComponent("images/vase.png"))
        #expect(alpha.allSatisfy { abs(Int($0) - 128) <= 1 })
    }

    @Test func aVerticalFlipIsBakedAndAMaskTrimsAwayWhatItHides() throws {
        let id = UUID()
        let image = try rgba(width: 4, height: 2) { _, y in y == 0 ? (180, 20, 40, 255) : (0, 0, 0, 0) }
        let record = layer(id: id, name: "Petal", origin: .zero, size: CGSize(width: 4, height: 2), flipY: true)
        let project = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: id, layers: [record]),
                                      images: [id: ImportedImage(image: image, thumbnail: image, name: "Petal")])
        let destination = try temporary("Flipped.ikebana")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try SeiShinTemplateExporter.export(snapshot: project, script: Data(element("petal", kind: "vessel", layer: id).utf8), to: destination)
        #expect(try pngSize(destination.appendingPathComponent("images/petal.png")) == (4, 1))
        #expect(try alphas(destination.appendingPathComponent("images/petal.png")).allSatisfy { $0 == 255 })
        let petal = try onlyElement(at: destination)
        expectPoint(petal["anchor"], 2, 0)
        #expect((petal["flipX"] as? NSNumber)?.boolValue == false)

        let maskedID = UUID()
        let full = try rgba(width: 4, height: 4) { _, _ in (10, 20, 30, 255) }
        let mask = try gray(width: 4, height: 4) { x, _ in x < 2 ? 255 : 0 }
        let masked = layer(id: maskedID, name: "Leaf", origin: .zero, size: CGSize(width: 4, height: 4), hasMask: true)
        let maskedProject = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: maskedID, layers: [masked]),
                                            images: [maskedID: ImportedImage(image: full, thumbnail: full, name: "Leaf")],
                                            masks: [maskedID: ImportedImage(image: mask, thumbnail: mask, name: "Mask")])
        let maskedURL = try temporary("Masked.ikebana")
        defer { try? FileManager.default.removeItem(at: maskedURL.deletingLastPathComponent()) }
        _ = try SeiShinTemplateExporter.export(snapshot: maskedProject, script: Data(element("leaf", kind: "vessel", layer: maskedID).utf8), to: maskedURL)
        #expect(try pngSize(maskedURL.appendingPathComponent("images/leaf.png")) == (2, 4))
    }

    @Test func aWideStemAndAMultiplyLayerWarn() throws {
        let id = UUID()
        let image = try rgba(width: 10, height: 10) { _, _ in (0, 0, 0, 255) }
        let record = layer(id: id, name: "Stem", origin: .zero, size: CGSize(width: 10, height: 10))
        let project = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 20, height: 20, activeLayerID: id, layers: [record]),
                                      images: [id: ImportedImage(image: image, thumbnail: image, name: "Stem")])
        let destination = try temporary("Wide.ikebana")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let script = "{\"op\":\"element\",\"id\":\"stem-main\",\"kind\":\"stem\",\"layer\":\"\(id.uuidString)\",\"centerline\":[[0,0],[0,10]]}\n"
        let warned = try SeiShinTemplateExporter.export(snapshot: project, script: Data(script.utf8), to: destination)
        #expect(warned.warnings.contains { $0.contains("centerline") })

        let paint = layer(id: id, name: "Stem", origin: .zero, size: CGSize(width: 4, height: 4), blend: .multiply)
        let multiplied = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: id, layers: [paint]),
                                         images: [id: ImportedImage(image: try rgba(width: 4, height: 4) { _, _ in (1, 2, 3, 255) }, thumbnail: image, name: "Stem")])
        let blendURL = try temporary("Blend.ikebana")
        defer { try? FileManager.default.removeItem(at: blendURL.deletingLastPathComponent()) }
        let blend = try SeiShinTemplateExporter.export(snapshot: multiplied, script: Data(element("stem-main", kind: "stem", layer: id, centerline: "[[0,2],[4,2]]").utf8), to: blendURL)
        #expect(blend.warnings.contains { $0.contains("Multiply") })
    }

    @Test func authoringRulesFailWithTheLineOrTheReason() throws {
        let snapshot = try vessel(side: 8)
        #expect(failure { _ = try export(snapshot.project, "") }.contains("no element"))
        let bad = "# comment\n{\"op\":\"element\",\"id\":\"nope\"}\n"
        #expect(failure { _ = try export(snapshot.project, bad) }.contains("line 2"))
        let brokenJSON = "{\"op\":\"element\"\n"
        #expect(failure { _ = try export(snapshot.project, brokenJSON) }.contains("not valid JSON"))

        let other = UUID()
        let image = try rgba(width: 4, height: 4) { _, _ in (255, 0, 0, 255) }
        let first = layer(id: snapshot.id, name: "Vase", origin: .zero, size: CGSize(width: 4, height: 4))
        let second = layer(id: other, name: "Other", origin: .zero, size: CGSize(width: 4, height: 4))
        let two = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: snapshot.id, layers: [first, second]),
                                  images: [snapshot.id: ImportedImage(image: image, thumbnail: image, name: "Vase"),
                                           other: ImportedImage(image: image, thumbnail: image, name: "Other")])
        let sameID = element("vase", kind: "vessel", layer: snapshot.id) + element("vase", kind: "vessel", layer: other)
        #expect(failure { _ = try export(two, sameID) }.contains("Two element lines"))
        let sameLayer = element("vase", kind: "vessel", layer: snapshot.id) + element("stone", kind: "stone", layer: snapshot.id)
        #expect(failure { _ = try export(snapshot.project, sameLayer) }.contains("More than one element"))

        let flower = element("bloom", kind: "flower", layer: snapshot.id)
        #expect(failure { _ = try export(snapshot.project, flower) }.contains("needs a stem"))
        let missing = element("bloom", kind: "flower", layer: snapshot.id, parent: "gone")
        #expect(failure { _ = try export(snapshot.project, missing) }.contains("not in the template"))

        let stemID = UUID(), flowerID = UUID(), berryID = UUID()
        let stem = layer(id: stemID, name: "Stem", origin: .zero, size: CGSize(width: 4, height: 4))
        let bloom = layer(id: flowerID, name: "Bloom", origin: .zero, size: CGSize(width: 4, height: 4))
        let berry = layer(id: berryID, name: "Berry", origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4))
        let family = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 16, height: 16, activeLayerID: stemID, layers: [stem, bloom, berry]),
                                     images: [stemID: ImportedImage(image: image, thumbnail: image, name: "Stem"),
                                              flowerID: ImportedImage(image: image, thumbnail: image, name: "Bloom"),
                                              berryID: ImportedImage(image: image, thumbnail: image, name: "Berry")])
        let grandchild = "{\"op\":\"element\",\"id\":\"stem-main\",\"kind\":\"stem\",\"layer\":\"\(stemID.uuidString)\",\"centerline\":[[0,4],[0,0]]}\n"
            + element("bloom", kind: "flower", layer: flowerID, parent: "stem-main")
            + element("pip", kind: "berry", layer: berryID, parent: "bloom")
        #expect(failure { _ = try export(family, grandchild) }.contains("one level"))

        let clipping = layer(id: snapshot.id, name: "Vase", origin: .zero, size: CGSize(width: 4, height: 4), maskSource: UUID())
        #expect(failure { _ = try export(replacing(snapshot, with: clipping), element("vase", kind: "vessel", layer: snapshot.id)) }.contains("clipping mask"))
        let folder = layer(id: snapshot.id, name: "Group", origin: .zero, size: CGSize(width: 4, height: 4), isGroup: true)
        #expect(failure { _ = try export(replacing(snapshot, with: folder, image: false), element("vase", kind: "vessel", layer: snapshot.id)) }.contains("folder"))
        let adjustment = layer(id: snapshot.id, name: "Curves", origin: .zero, size: CGSize(width: 4, height: 4), adjustment: LayerAdjustment(kind: .invert))
        #expect(failure { _ = try export(replacing(snapshot, with: adjustment, image: false), element("vase", kind: "vessel", layer: snapshot.id)) }.contains("adjustment"))
        let effects = layer(id: snapshot.id, name: "Vase", origin: .zero, size: CGSize(width: 4, height: 4), effects: LayerEffects(stroke: StrokeEffect()))
        #expect(failure { _ = try export(replacing(snapshot, with: effects), element("vase", kind: "vessel", layer: snapshot.id)) }.contains("effects"))
        let unlinked = layer(id: snapshot.id, name: "Vase", origin: .zero, size: CGSize(width: 4, height: 4), hasMask: true, maskLinked: false)
        #expect(failure { _ = try export(replacing(snapshot, with: unlinked), element("vase", kind: "vessel", layer: snapshot.id)) }.contains("unlinked"))

        let huge = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 2049, height: 8, activeLayerID: snapshot.id, layers: snapshot.project.manifest.layers),
                                   images: snapshot.project.images)
        #expect(failure { _ = try export(huge, element("vase", kind: "vessel", layer: snapshot.id)) }.contains("2048"))
        #expect(SeiShinTemplateExporter.templateID(forName: "Camellia, slanted") == "camellia-slanted")
        #expect(SeiShinTemplateExporter.templateID(forName: "!!!") == "template")
    }

    // MARK: - Fixture helpers

    private struct Built {
        var id: UUID
        var project: ProjectSnapshot
        var script: Data
    }

    private func vessel(side: Int) throws -> Built {
        let id = UUID()
        let image = try rgba(width: side, height: side) { _, _ in (240, 240, 240, 255) }
        let record = layer(id: id, name: "Vase", origin: .zero, size: CGSize(width: side, height: side))
        let project = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: max(side, 8), height: max(side, 8), activeLayerID: id, layers: [record]),
                                      images: [id: ImportedImage(image: image, thumbnail: image, name: "Vase")])
        return Built(id: id, project: project, script: Data(element("vase", kind: "vessel", layer: id).utf8))
    }

    private func exportOne(pixels: Int, displayed: CGSize, opacity: Double) throws -> (record: [String: Any], url: URL) {
        let id = UUID()
        let image = try rgba(width: pixels, height: pixels) { _, _ in (255, 255, 255, 255) }
        let record = layer(id: id, name: "Vase", origin: .zero, size: displayed, opacity: opacity)
        let project = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 64, height: 64, activeLayerID: id, layers: [record]),
                                      images: [id: ImportedImage(image: image, thumbnail: image, name: "Vase")])
        let url = try temporary("One-\(UUID().uuidString).ikebana")
        _ = try SeiShinTemplateExporter.export(snapshot: project, script: Data(element("vase", kind: "vessel", layer: id).utf8), to: url)
        return (try onlyElement(at: url), url)
    }

    private func replacing(_ built: Built, with record: ProjectLayerRecord, image: Bool = true) -> ProjectSnapshot {
        var images = built.project.images
        if !image { images[built.id] = nil }
        return ProjectSnapshot(manifest: ProjectManifest(documentID: built.project.manifest.documentID, width: built.project.manifest.width,
                                                         height: built.project.manifest.height, activeLayerID: built.id, layers: [record]),
                               images: images, masks: built.project.masks)
    }

    private func export(_ project: ProjectSnapshot, _ script: String) throws -> URL {
        let url = try temporary("Rule-\(UUID().uuidString).ikebana")
        do {
            _ = try SeiShinTemplateExporter.export(snapshot: project, script: Data(script.utf8), to: url)
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
        return url
    }

    private func failure(_ body: () throws -> Void) -> String {
        do {
            try body()
            Issue.record("expected the export to fail")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func element(_ id: String, kind: String, layer: UUID, parent: String? = nil, anchor: [Double]? = nil, centerline: String? = nil) -> String {
        var fields = "\"op\":\"element\",\"id\":\"\(id)\",\"kind\":\"\(kind)\",\"layer\":\"\(layer.uuidString)\""
        if let parent { fields += ",\"parent\":\"\(parent)\"" }
        if let anchor { fields += ",\"anchor\":[\(anchor[0]),\(anchor[1])]" }
        if let centerline { fields += ",\"centerline\":\(centerline)" }
        return "{" + fields + "}\n"
    }

    private func layer(id: UUID, name: String, origin: CGPoint, size: CGSize, rotation: CGFloat = 0, flipY: Bool = false, opacity: Double = 1, blend: LayerBlendMode = .normal, isGroup: Bool = false, adjustment: LayerAdjustment? = nil, maskSource: UUID? = nil, effects: LayerEffects? = nil, hasMask: Bool = false, maskLinked: Bool? = nil) -> ProjectLayerRecord {
        var transform = LayerTransform(origin: origin, size: size)
        transform.rotation = rotation
        transform.flipY = flipY
        let hasImage = !isGroup && adjustment == nil
        return ProjectLayerRecord(id: id, name: name, isVisible: true, transform: transform,
                                  imageFile: hasImage ? "\(id.uuidString).png" : nil,
                                  isGroup: isGroup ? true : nil, opacity: opacity, blendMode: blend,
                                  maskFile: hasMask ? "\(id.uuidString).mask.png" : nil,
                                  maskSourceID: maskSource, adjustment: adjustment, maskLinked: maskLinked, effects: effects)
    }

    private func rgba(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                let index = y * context.bytesPerRow + x * 4
                bytes[index] = red
                bytes[index + 1] = green
                bytes[index + 2] = blue
                bytes[index + 3] = alpha
            }
        }
        return try #require(context.makeImage())
    }

    private func gray(width: Int, height: Int, _ pixel: (Int, Int) -> UInt8) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * context.bytesPerRow + x] = pixel(x, y)
            }
        }
        return try #require(context.makeImage())
    }

    private func temporary(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SeiShin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ manifest: [String: Any], to package: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: package.appendingPathComponent("manifest.json"))
    }

    private func onlyElement(at package: URL) throws -> [String: Any] {
        let manifest = try object(package.appendingPathComponent("manifest.json"))
        let elements = try #require(manifest["elements"] as? [[String: Any]])
        return try #require(elements.first)
    }

    private func pngSize(_ url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(Data(contentsOf: url) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func alphas(_ url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(Data(contentsOf: url) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                result.append(bytes[y * context.bytesPerRow + x * 4 + 3])
            }
        }
        return result
    }

    private func isJSONNull(_ value: Any?) -> Bool {
        guard let value else { return false }
        return value is NSNull
    }

    private func expectPoint(_ value: Any?, _ x: Double, _ y: Double) {
        guard let coords = value as? [Any], coords.count >= 2,
              let px = (coords[0] as? NSNumber)?.doubleValue,
              let py = (coords[1] as? NSNumber)?.doubleValue else {
            Issue.record("expected a point, got \(String(describing: value))")
            return
        }
        #expect(abs(px - x) < 0.02 && abs(py - y) < 0.02)
    }

    private func near(_ value: Any?, _ expected: Double) -> Bool {
        guard let number = (value as? NSNumber)?.doubleValue else { return false }
        return abs(number - expected) < 0.02
    }
}
