import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let seiShinTemplate = UTType(exportedAs: "com.seiandshin.template", conformingTo: .package)
}

/// A Sei & Shin template folder (`.ikebana`) written from a Compositor project.
/// Element tags are read from `strokes.jsonl` from the first byte. Mac alignment guides are not.
/// An existing template's `guides` object is kept when the same folder is exported again.
enum SeiShinTemplateExporter {
    static let format = "com.seiandshin.template"
    static let version = 1
    static let maxSide = 2048

    struct Result: Sendable {
        var warnings: [String]
    }

    static func export(snapshot: ProjectSnapshot, script: Data, to url: URL) throws -> Result {
        var destination = url
        if destination.pathExtension.lowercased() != "ikebana" {
            destination = destination.appendingPathExtension("ikebana")
        }
        let guides = try preservedGuides(at: destination)
        let elements = try readElements(script)
        guard !elements.isEmpty else { throw SeiShinTemplateError.noElements }
        guard snapshot.manifest.width <= maxSide, snapshot.manifest.height <= maxSide else {
            throw SeiShinTemplateError.rule("This canvas is \(snapshot.manifest.width)×\(snapshot.manifest.height). A Sei & Shin template is at most \(maxSide) pixels on a side.")
        }
        let layers = snapshot.manifest.layers
        var resolved: [Resolved] = []
        var seenIDs = Set<String>()
        var seenLayers = Set<UUID>()
        for element in elements {
            guard seenIDs.insert(element.id).inserted else {
                throw SeiShinTemplateError.rule("Two element lines use the id \(element.id).")
            }
            guard let layer = layer(element.layer, in: layers) else {
                throw SeiShinTemplateError.rule("Element \(element.id) names a layer \(element.layer) that is not in the project.")
            }
            guard seenLayers.insert(layer.id).inserted else {
                throw SeiShinTemplateError.rule("More than one element uses the layer \(layer.name).")
            }
            try validateLayer(layer, element: element)
            resolved.append(Resolved(element: element, layer: layer))
        }
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.element.id, $0) })
        for item in resolved {
            if let parentID = item.element.parent {
                guard parentID != item.element.id, let parent = byID[parentID] else {
                    throw SeiShinTemplateError.rule("Element \(item.element.id) names a parent \(parentID) that is not in the template.")
                }
                guard parent.element.kind == .stem, parent.element.parent == nil else {
                    throw SeiShinTemplateError.rule("Element \(item.element.id) is parented to \(parentID). A child has to belong to a stem, and only one level deep.")
                }
                guard item.element.kind.needsParent else {
                    throw SeiShinTemplateError.rule("Element \(item.element.id) is a \(item.element.kind.rawValue), so it cannot have a parent.")
                }
            } else if item.element.kind.needsParent {
                throw SeiShinTemplateError.rule("Element \(item.element.id) is a \(item.element.kind.rawValue) and needs a stem as its parent.")
            }
        }
        let order = layers.enumerated().reduce(into: [UUID: Int]()) { $0[$1.element.id] = $1.offset }
        let sorted = resolved.sorted { (order[$0.layer.id] ?? 0) < (order[$1.layer.id] ?? 0) }
        var warnings: [String] = []
        var prepared: [UUID: Prepared] = [:]
        for item in sorted {
            let made = try prepare(item, images: snapshot.images, masks: snapshot.masks, warnings: &warnings)
            prepared[item.layer.id] = made
        }
        let name = destination.deletingPathExtension().lastPathComponent
        var records: [[String: Any]] = []
        for (z, item) in sorted.enumerated() {
            let part = try record(item, z: z, prepared: prepared, byID: byID)
            records.append(part)
        }
        var manifest: [String: Any] = [
            "format": format,
            "version": version,
            "id": templateID(forName: name),
            "name": name,
            "canvas": ["width": snapshot.manifest.width, "height": snapshot.manifest.height],
            "elements": records
        ]
        if let guides { manifest["guides"] = guides }
        let body = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        var files: [String: FileWrapper] = ["manifest.json": FileWrapper(regularFileWithContents: body)]
        var images: [String: FileWrapper] = [:]
        for item in sorted {
            guard let part = prepared[item.layer.id] else { throw SeiShinTemplateError.encode }
            images["\(item.element.id).png"] = FileWrapper(regularFileWithContents: try pngData(part.image))
        }
        files["images"] = FileWrapper(directoryWithFileWrappers: images)
        if FileManager.default.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try FileManager.default.removeItem(at: destination)
        }
        try FileWrapper(directoryWithFileWrappers: files).write(to: destination, options: .atomic, originalContentsURL: nil)
        return Result(warnings: warnings)
    }

    static func templateID(forName name: String) -> String {
        var slug = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !slug.isEmpty {
                slug.append("-")
                dash = true
            }
        }
        while slug.last == "-" { slug.removeLast() }
        return slug.isEmpty ? "template" : slug
    }

    // MARK: - Script

    private struct Resolved {
        var element: StrokeElement
        var layer: ProjectLayerRecord
    }

    private static func readElements(_ script: Data) throws -> [StrokeElement] {
        var elements: [StrokeElement] = []
        var lineNumber = 0
        var cursor = script.startIndex
        while cursor < script.endIndex {
            guard let newline = script[cursor...].firstIndex(of: 0x0A) else { break }
            var line = script[cursor..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            cursor = script.index(after: newline)
            lineNumber += 1
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if text.range(of: #""op"\s*:\s*"element""#, options: .regularExpression) != nil {
                    throw SeiShinTemplateError.rule("strokes.jsonl line \(lineNumber): this element line is not valid JSON.")
                }
                continue
            }
            guard object["op"] as? String == "element" else { continue }
            switch StrokeScriptReader.readElement(object) {
            case .success(let element): elements.append(element)
            case .failure(let reason): throw SeiShinTemplateError.rule("strokes.jsonl line \(lineNumber): \(reason)")
            }
        }
        return elements
    }

    private static func layer(_ token: String, in layers: [ProjectLayerRecord]) -> ProjectLayerRecord? {
        if let id = UUID(uuidString: token) { return layers.first { $0.id == id } }
        return layers.last { $0.name == token }
    }

    private static func validateLayer(_ layer: ProjectLayerRecord, element: StrokeElement) throws {
        if layer.isGroup == true {
            throw SeiShinTemplateError.rule("Element \(element.id) is on the folder \(layer.name). Tag a layer that has pixels.")
        }
        if layer.adjustment != nil {
            throw SeiShinTemplateError.rule("Layer \(layer.name) is an adjustment. Merge it before exporting for Sei & Shin.")
        }
        if layer.maskSourceID != nil {
            throw SeiShinTemplateError.rule("Layer \(layer.name) uses a clipping mask. Merge it before exporting for Sei & Shin.")
        }
        if layer.effects?.isEmpty == false {
            throw SeiShinTemplateError.rule("Layer \(layer.name) has effects. Merge them before exporting for Sei & Shin.")
        }
        if layer.imageFile == nil {
            throw SeiShinTemplateError.rule("Layer \(layer.name) has no pixels.")
        }
        if layer.maskFile != nil, layer.maskLinked == false {
            throw SeiShinTemplateError.rule("The mask on \(layer.name) is unlinked. Link it, or merge it, before exporting for Sei & Shin.")
        }
    }

    // MARK: - Pixels

    private struct Prepared {
        var image: CGImage
        var transform: LayerTransform
        /// Image size the centerline and anchor were measured in, before the trim.
        var untrimmed: CGSize
        var trim: CGPoint
        var scale: CGFloat
    }

    private static func prepare(_ item: Resolved, images: [UUID: ImportedImage], masks: [UUID: ImportedImage], warnings: inout [String]) throws -> Prepared {
        guard let source = images[item.layer.id]?.image else {
            throw SeiShinTemplateError.rule("Layer \(item.layer.name) has no pixels.")
        }
        var context = try BrushRaster.copy(source)
        let opacity = item.layer.opacity ?? 1
        if opacity < 1 { multiplyAlpha(context, by: opacity) }
        if item.layer.maskFile != nil, item.layer.maskEnabled != false, let mask = masks[item.layer.id]?.image {
            try multiplyMask(context, mask: mask)
        }
        if let blend = item.layer.blendMode, blend != .normal {
            warnings.append("Layer \(item.layer.name) uses \(blend.rawValue). The template keeps its pixels and draws them in Normal.")
        }
        var image = try image(from: context)
        var transform = item.layer.transform
        if transform.flipY {
            image = try flippedVertically(image)
            transform.flipY = false
        }
        let scaleX = transform.size.width / CGFloat(image.width)
        let scaleY = transform.size.height / CGFloat(image.height)
        if abs(scaleX - scaleY) > 0.001 * max(scaleX, scaleY) {
            let width = max(1, Int(transform.size.width.rounded()))
            let height = max(1, Int(transform.size.height.rounded()))
            guard width <= maxSide, height <= maxSide else {
                throw SeiShinTemplateError.rule("\(item.element.id) would be \(width)×\(height) after baking its scale. A Sei & Shin image is at most \(maxSide) pixels on a side.")
            }
            let baked = try BrushRaster.context(width: width, height: height, mask: false)
            draw(image, into: baked, rect: CGRect(x: 0, y: 0, width: width, height: height))
            image = try image(from: baked)
            let center = transform.center
            transform.size = CGSize(width: width, height: height)
            transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        }
        guard image.width <= maxSide, image.height <= maxSide else {
            throw SeiShinTemplateError.rule("\(item.element.id) is \(image.width)×\(image.height). A Sei & Shin image is at most \(maxSide) pixels on a side, and the exporter does not scale it down.")
        }
        guard let trim = ImageTrim.calculateTrimRect(in: image, options: TrimOptions()) else {
            throw SeiShinTemplateError.rule("Layer \(item.layer.name) has no opaque pixels to export.")
        }
        let cropped = try crop(image, to: trim)
        if item.element.kind == .stem, let line = item.element.centerline {
            let local = line.map { imagePoint($0, transform: transform, width: image.width, height: image.height) }
                .map { CGPoint(x: $0.x - trim.origin.x, y: $0.y - trim.origin.y) }
            if centerlineLeavesTheArt(local, image: cropped) {
                warnings.append("Stem \(item.element.id) has painted pixels farther from its centerline than half its narrower side.")
            }
        }
        let scale = transform.size.width / CGFloat(image.width)
        return Prepared(image: cropped, transform: transform, untrimmed: CGSize(width: image.width, height: image.height), trim: trim.origin, scale: scale)
    }

    /// Document pixels to image pixels. The image origin is its top left, y down. Rotation is clockwise
    /// around the layer center, which is how `LayerRenderer` draws a layer. `flipY` is applied here and
    /// then baked into the pixels, because a Sei & Shin element only stores `flipX`.
    static func imagePoint(_ point: CGPoint, transform: LayerTransform, width: Int, height: Int) -> CGPoint {
        let dx = point.x - transform.center.x, dy = point.y - transform.center.y
        let cosine = cos(transform.radians), sine = sin(transform.radians)
        var x = dx * cosine + dy * sine
        var y = -dx * sine + dy * cosine
        if transform.flipX { x = -x }
        if transform.flipY { y = -y }
        return CGPoint(x: (x / transform.size.width + 0.5) * CGFloat(width),
                       y: (y / transform.size.height + 0.5) * CGFloat(height))
    }

    private static func centerlineLeavesTheArt(_ line: [CGPoint], image: CGImage) -> Bool {
        guard line.count >= 2, let context = try? BrushRaster.copy(image), let data = context.data else { return false }
        // Half the narrower side: a stem's ribbon. Farther than that, the bend will stretch the paint.
        let half = CGFloat(min(image.width, image.height)) / 2
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * stride + x * 4 + 3] > 0 {
                let pixel = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if distance(pixel, to: line) > half { return true }
            }
        }
        return false
    }

    private static func distance(_ point: CGPoint, to line: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<line.count {
            best = min(best, distance(point, from: line[index - 1], to: line[index]))
        }
        return best
    }

    private static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = dx * dx + dy * dy
        let t = length <= 0 ? 0 : min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    // MARK: - Manifest records

    private static func record(_ item: Resolved, z: Int, prepared: [UUID: Prepared], byID: [String: Resolved]) throws -> [String: Any] {
        guard let part = prepared[item.layer.id] else { throw SeiShinTemplateError.encode }
        let anchorDocument: CGPoint
        let anchorLocal: CGPoint
        if item.element.kind == .stem, let line = item.element.centerline, let first = line.first {
            anchorDocument = first
            anchorLocal = local(first, part)
        } else if let anchor = item.element.anchor {
            anchorDocument = anchor
            anchorLocal = local(anchor, part)
        } else {
            anchorDocument = item.layer.transform.center
            anchorLocal = local(item.layer.transform.center, part)
        }
        var record: [String: Any] = [
            "id": item.element.id,
            "kind": item.element.kind.rawValue,
            "image": "\(item.element.id).png",
            "z": z,
            "anchor": [number(anchorLocal.x), number(anchorLocal.y)],
            "flipX": part.transform.flipX
        ]
        if let parentID = item.element.parent, let parent = byID[parentID], let parentPart = prepared[parent.layer.id],
           let centerline = parent.element.centerline {
            let localLine = centerline.map { local($0, parentPart) }
            let fraction = item.element.attach ?? 1
            let sample = sampleLine(localLine, fraction: fraction)
            let child = local(anchorDocument, parentPart)
            let radians = sample.angle * .pi / 180
            let tangent = CGPoint(x: cos(radians), y: sin(radians))
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let dx = child.x - sample.point.x, dy = child.y - sample.point.y
            let offset = CGPoint(x: dx * tangent.x + dy * tangent.y, y: dx * normal.x + dy * normal.y)
            let parentScale = parentPart.scale
            record["parent"] = parentID
            record["attach"] = number(fraction)
            record["offset"] = [number(offset.x), number(offset.y)]
            // Mac rotation is absolute. The phone adds the stem's rotation again, so it has to come out here
            // along with the rest tangent, or a turned stem would turn the flower twice.
            record["localRotation"] = number(part.transform.rotation - parentPart.transform.rotation - sample.angle)
            record["localScale"] = number(parentScale == 0 ? 1 : part.scale / parentScale)
        } else {
            record["parent"] = NSNull()
            record["center"] = [number(anchorDocument.x), number(anchorDocument.y)]
            record["rotation"] = number(part.transform.rotation)
            record["scale"] = number(part.scale)
            if item.element.kind == .stem, let line = item.element.centerline {
                record["centerline"] = line.map { local($0, part) }.map { [number($0.x), number($0.y)] }
            }
        }
        return record
    }

    private static func local(_ point: CGPoint, _ part: Prepared) -> CGPoint {
        let image = imagePoint(point, transform: part.transform, width: Int(part.untrimmed.width), height: Int(part.untrimmed.height))
        return CGPoint(x: image.x - part.trim.x, y: image.y - part.trim.y)
    }

    private static func sampleLine(_ points: [CGPoint], fraction: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        guard points.count >= 2 else { return (points.first ?? .zero, 0) }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in 1..<points.count {
            let length = hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            lengths.append(length)
            total += length
        }
        let target = min(max(fraction, 0), 1) * total
        var walked: CGFloat = 0
        for index in 0..<lengths.count {
            let length = lengths[index]
            if walked + length >= target - 0.001 || index == lengths.count - 1 {
                let t = length > 0 ? min(1, max(0, (target - walked) / length)) : 0
                let start = points[index], end = points[index + 1]
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                let angle = atan2(end.y - start.y, end.x - start.x) * 180 / .pi
                return (point, angle)
            }
            walked += length
        }
        return (points[points.count - 1], 0)
    }

    private static func number(_ value: CGFloat) -> Any {
        let rounded = (value * 1000).rounded() / 1000
        if abs(rounded - rounded.rounded()) < 0.0001 { return Int(rounded.rounded()) }
        return Double(rounded)
    }

    // MARK: - Guides already on the template

    private static func preservedGuides(at url: URL) throws -> Any? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SeiShinTemplateError.unreadableGuides
        }
        // Missing guides are normal: the first export of a project has none. A guides value that is
        // present and unreadable must stop the write, or the next file would drop what was there.
        guard object.keys.contains("guides") else { return nil }
        guard let guides = object["guides"] as? [String: Any] else { throw SeiShinTemplateError.unreadableGuides }
        try validateGuides(guides)
        return guides
    }

    private static func validateGuides(_ value: Any) throws {
        guard let guides = value as? [String: Any],
              let origin = guides["origin"] as? [Any], origin.count == 2,
              let shin = StrokeScriptReaderDouble.finite(guides["shinLength"]), shin > 0,
              origin.allSatisfy({ StrokeScriptReaderDouble.finite($0) != nil }),
              let rays = guides["rays"] as? [Any], rays.count == 3 else {
            throw SeiShinTemplateError.unreadableGuides
        }
        let markers = ["shin": "circle", "soe": "square", "hikae": "triangle"]
        var roles = Set<String>()
        for ray in rays {
            guard let ray = ray as? [String: Any], let role = ray["role"] as? String, let marker = markers[role],
                  ray["marker"] as? String == marker, roles.insert(role).inserted,
                  let angle = StrokeScriptReaderDouble.finite(ray["angle"]),
                  let length = StrokeScriptReaderDouble.finite(ray["length"]), length > 0, angle.isFinite else {
                throw SeiShinTemplateError.unreadableGuides
            }
        }
    }

    // MARK: - Bitmaps

    private static func multiplyAlpha(_ context: CGContext, by opacity: Double) {
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let count = context.height * context.bytesPerRow
        for index in 0..<count {
            bytes[index] = UInt8((Double(bytes[index]) * opacity).rounded())
        }
    }

    private static func multiplyMask(_ context: CGContext, mask: CGImage) throws {
        let width = context.width, height = context.height
        let coverage = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: coverage)
        guard let pixels = context.data, let gray = coverage.data else { throw SeiShinTemplateError.encode }
        let color = pixels.assumingMemoryBound(to: UInt8.self)
        let maskBytes = gray.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let factor = Double(maskBytes[y * coverage.bytesPerRow + x]) / 255
                let pixel = y * context.bytesPerRow + x * 4
                for channel in 0..<4 {
                    color[pixel + channel] = UInt8((Double(color[pixel + channel]) * factor).rounded())
                }
            }
        }
    }

    private static func flippedVertically(_ image: CGImage) throws -> CGImage {
        let context = try BrushRaster.copy(image)
        guard let data = context.data else { throw SeiShinTemplateError.encode }
        let stride = context.bytesPerRow
        let row = UnsafeMutableRawPointer.allocate(byteCount: stride, alignment: 16)
        defer { row.deallocate() }
        for y in 0..<(image.height / 2) {
            let top = data + y * stride
            let bottom = data + (image.height - 1 - y) * stride
            row.copyMemory(from: top, byteCount: stride)
            top.copyMemory(from: bottom, byteCount: stride)
            bottom.copyMemory(from: row, byteCount: stride)
        }
        return try image(from: context)
    }

    private static func crop(_ image: CGImage, to trim: CGRect) throws -> CGImage {
        let width = max(1, Int(trim.width.rounded()))
        let height = max(1, Int(trim.height.rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: -trim.minX, y: -trim.minY, width: image.width, height: image.height), mask: false, context: context)
        return try image(from: context)
    }

    private static func draw(_ image: CGImage, into context: CGContext, rect: CGRect) {
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func image(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw SeiShinTemplateError.encode }
        return image
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SeiShinTemplateError.encode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SeiShinTemplateError.encode }
        return data as Data
    }
}

/// `double` on the stroke reader is private. Guides validation only needs a finite number.
private enum StrokeScriptReaderDouble {
    static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

enum SeiShinTemplateError: LocalizedError {
    case noElements
    case rule(String)
    case unreadableGuides
    case encode

    var errorDescription: String? {
        switch self {
        case .noElements: "This project has no element lines in strokes.jsonl. Tag each part with an element op, then export again."
        case .rule(let message): message
        case .unreadableGuides: "The template already has a guides object that could not be read, so it was not replaced."
        case .encode: "The Sei & Shin template could not be written."
        }
    }
}
