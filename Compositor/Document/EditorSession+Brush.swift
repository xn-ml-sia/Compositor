import AppKit

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        // A folder has no pixels of its own, so only its mask can be painted.
        canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || activeLayer?.mask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
    }
    /// Tiled raster edit of the active layer's pixels or mask, within the shared pixel budgets.
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings(), growsMask: Bool = false) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        let stroke = try BrushStroke(layer: layer, mask: isMaskSelected, settings: settings, canvas: document.size, growsMask: growsMask)
        let used = document.layers.filter { $0.id != layer.id }.reduce(0) { total, layer in
            let image = isMaskSelected ? layer.mask?.asset.image : layer.asset?.image
            return total + (image.map { $0.width * $0.height } ?? 0)
        }
        stroke.pixelLimit = DocumentLimits.documentPixelBudget - used
        stroke.selectionClip = try selection?.clip(canvas: document.size)
        if !isMaskSelected, layer.mask != nil {
            let maskPixels = document.layers.filter { $0.id != layer.id }.reduce(0) { $0 + ($1.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0) }
            stroke.pixelLimit = min(stroke.pixelLimit, DocumentLimits.documentPixelBudget - maskPixels)
        }
        return stroke
    }
    func beginBrush(at point: CGPoint, pressure: CGFloat? = nil) {
        // Spot Healing and Clone Stamp rework image pixels; they have nothing to do on a mask.
        if tool == .blur, blurMode != .blur { beginWarp(at: point); return }
        guard tool == .brush || tool == .blur || (tool.isBrushTool && !isMaskSelected), canPaint, let layer = activeLayer, let document else { return }
        var clone: (image: CGImage, offset: CGSize)?
        if tool == .cloneStamp {
            guard let offset = cloneStrokeOffset(at: point) else {
                brushError = "Option-click where Clone Stamp should copy from first."
                return
            }
            guard let image = cloneSample(document) else { return }
            cloneOffset = offset
            clone = (image, offset)
        }
        // Blur paints a softened copy of the layer, in place, through the brush tip.
        if tool == .blur {
            guard let image = blurSample(document, mask: isMaskSelected) else { return }
            clone = (image, .zero)
        }
        finishOpacityEdit()
        do {
            var settings = brushSettings
            settings.healing = tool == .spotHealing
            settings.erasing = tool == .brush && brushMode == .erase && !isMaskSelected
            settings.healingMode = spotHealingMode
            // Clone, heal, and smear keep the round tip. Natural presets are a paint/erase brush.
            if tool != .brush { settings.natural = .round; settings.wiggle = 0 }
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: tool == .brush)
            if settings.natural != .round {
                stroke.editName = settings.erasing ? "\(settings.natural.rawValue) Erase" : "\(settings.natural.rawValue) Stroke"
            }
            stroke.clone = clone
            stroke.isBlur = tool == .blur
            brushStroke = stroke
            brushPointingPressure = pressure
            try stroke.append(point, pressure: pressure)
            brushAnchor = point
            brushPointer = point
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint, pressure: CGFloat? = nil) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        guard let brushStroke else { return }
        brushPointer = point
        if pressure != nil { brushPointingPressure = pressure }
        guard let painted = smoothed(point) else { return }
        let next = steered(painted)
        do { try brushStroke.append(next, pressure: brushPointingPressure); lastBrushPoint?.point = next; brushRevision += 1 }
        catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// Where the brush actually is, with Smoothing on: it trails the pointer on a string, and only
    /// moves once the pointer pulls that string taut — the model Photoshop uses. The string's length
    /// is in screen points, so it feels the same however far the canvas is zoomed in. Nil while the
    /// string is still slack, which is the whole point: those jitters never reach the stroke.
    private func smoothed(_ point: CGPoint) -> CGPoint? {
        guard tool == .brush, brushSettings.smoothing > 0, let anchor = brushAnchor else { return point }
        let radius = brushSettings.smoothing / max(0.01, viewport.zoom)
        let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let distance = hypot(delta.x, delta.y)
        guard distance > radius else { return nil }
        let step = (distance - radius) / distance
        let moved = CGPoint(x: anchor.x + delta.x * step, y: anchor.y + delta.y * step)
        brushAnchor = moved
        return moved
    }

    /// A live drag follows the active flow field. Scripted points are steered once, before they reach the brush.
    private func steered(_ point: CGPoint) -> CGPoint {
        guard !isScriptedBrushStroke, tool == .brush, let field = flowField, abs(field.wiggle) > 1e-4, let last = lastBrushPoint?.point else { return point }
        let length = hypot(point.x - last.x, point.y - last.y)
        guard length > 0.2 else { return point }
        let direction = atan2(point.y - last.y, point.x - last.x) * 180 / CGFloat.pi
        let heading = (direction - field.angle(at: last)) * CGFloat.pi / 180
        return CGPoint(x: last.x + CGFloat(cos(heading)) * length, y: last.y + CGFloat(sin(heading)) * length)
    }

    func applyFlowField(name: String, wiggle: CGFloat? = nil, seed: UInt64? = nil, columns: Int? = nil, rows: Int? = nil, angles: [CGFloat]? = nil) {
        if let wiggle { flowWiggle = min(8, max(-8, wiggle)) }
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard let size = document?.size else { flowField = nil; return }
        if let field = FlowField.make(name: key, wiggle: flowWiggle, seed: seed ?? 1, canvas: size, columns: columns, rows: rows, angles: angles) {
            flowField = field
        } else if key == "none" || key == "off" || key == "nofield" {
            flowField = nil
        } else {
            brushError = "Unknown flow field “\(name)”."
            flowField = nil
        }
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    func cancelBrush() {
        warpStroke = nil
        brushStroke = nil
        brushAnchor = nil
        brushPointer = nil
        brushPointingPressure = nil
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard let stroke = brushStroke else { return true }
        guard !isProjectBusy else { return false }
        defer { cancelBrush() }
        do {
            // Smoothing leaves the brush short of the pointer; the stroke ends where the hand did.
            if let pointer = brushPointer, let anchor = brushAnchor, pointer != anchor,
               tool == .brush, brushSettings.smoothing > 0 {
                try stroke.append(pointer, pressure: brushPointingPressure)
            }
            try stroke.flush()
            if stroke.settings.healing { try stroke.heal() }
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
        return true
    }

    func finishBrush() async { finishBrushImmediately() }

    /// Install immutable tiles immediately, including the undo entry. The next
    /// stroke and other tools can start without awaiting full-image assembly.
    func commitPaintSnapshot(_ stroke: BrushStroke) throws {
        let result = try stroke.paintSnapshot()
        guard result.transform.isValid,
              let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform else { return }
        var mask = current.mask
        if !stroke.isMask, let original = mask, original.placement == nil, result.bounds != stroke.sourceRect {
            let raster = RasterSnapshot.replacing(source: original.asset, sourceRect: stroke.sourceRect,
                patches: [], crop: result.bounds, isMask: true)
            mask = original.replacing(ImportedImage(image: try raster.makeImage(), thumbnail: try raster.thumbnail(),
                name: original.asset.name, raster: raster))
        }
        beginEdit(stroke.editName ?? (stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.isBlur ? "Blur" : stroke.clone != nil ? "Clone Stamp" : stroke.settings.healing ? "Spot Healing" : "Brush Stroke"))
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { mask in
                var painted = mask.replacing(result.asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document. A linked
                // one still moves with its layer.
                if mask.placement != nil || result.bounds != stroke.sourceRect { painted.placement = result.transform }
                return painted
            } ?? LayerMask(asset: result.asset)
        } else {
            document?.layers[index] = ImageLayer(id: current.id, asset: result.asset, name: current.name,
                isVisible: current.isVisible, transform: result.transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode, mask: mask, maskSourceID: current.maskSourceID, effects: current.effects)
        }
        endEdit()
    }

    /// Assembles a raster edit off the main thread and replaces the layer's pixels or
    /// mask as one undo step. Other layer properties are read at commit time.
    func commitRasterEdit(_ stroke: BrushStroke, name: String, alsoApply: (() -> Void)? = nil) async throws {
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard stroke.committedTransform.isValid else { throw ProjectError.tooLarge }
        let input = stroke.commitInput()
        let result = try await BrushCommit.shared.render(input)
        let asset = result.asset
        let transform = stroke.transform(for: result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY))
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = stroke.layer.mask
        if !stroke.isMask, let originalMask = mask, originalMask.placement == nil {
            mask = originalMask.replacing(try await BrushCommit.shared.expandMask(originalMask.asset, for: input, croppedTo: result.pixelBounds))
        }
        // The raster was built from this layer's pixels, transform, and mask; never
        // write it over content that changed underneath it.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform,
              current.mask?.asset.image === stroke.layer.mask?.asset.image else { return }
        beginEdit(name)
        if stroke.isMask {
            let bounds = result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY)
            document?.layers[index].mask = current.mask.map { mask in
                var edited = mask.replacing(asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document.
                if mask.placement != nil || bounds != stroke.sourceRect { edited.placement = transform }
                return edited
            } ?? LayerMask(asset: asset)
        } else {
            document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name,
                isVisible: current.isVisible, transform: transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode,
                mask: mask.map { mask -> LayerMask in
                    var kept = mask
                    kept.isEnabled = current.mask?.isEnabled ?? mask.isEnabled
                    return kept
                }, maskSourceID: current.maskSourceID, effects: current.effects)
        }
        alsoApply?()
        endEdit()
    }
    /// Tools where number keys set opacity: the brush or gradient opacity, or with
    /// Move/Transform the opacity of the selected layers.
    var usesOpacityKeys: Bool { tool.isBrushTool || tool == .gradient || tool == .move }

    /// Photoshop-style opacity keys: 1 = 10% … 9 = 90%, 0 = 100%.
    /// Two digits typed quickly set an exact value (4 then 5 = 45%, 0 then 5 = 5%).
    func typeOpacityDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesOpacityKeys, brushStroke == nil, !isProjectBusy, (0...9).contains(digit) else { return }
        var percent = digit == 0 ? 100 : digit * 10
        if let pending = pendingOpacityDigit, time - pending.time < 0.6 {
            percent = max(1, pending.digit * 10 + digit)
            pendingOpacityDigit = nil
        } else {
            pendingOpacityDigit = (digit, time)
        }
        let value = CGFloat(percent) / 100
        switch tool {
        case .brush, .spotHealing, .cloneStamp, .blur: brushSettings.opacity = value
        case .gradient: gradientSettings.opacity = value
        default: setSelectedLayersOpacity(Double(value))
        }
    }
    /// Shift-[ / Shift-]: hardness in Photoshop's 25% steps (0, 25, 50, 75, 100%).
    func changeBrushHardness(increase: Bool) {
        guard brushStroke == nil else { return }
        // Snap to the next step up or down, so 80% goes to 100% or 75%.
        let quarter = brushSettings.hardness * 4
        let step = increase ? floor(quarter + 0.001) + 1 : ceil(quarter - 0.001) - 1
        brushSettings.hardness = min(4, max(0, step)) / 4
    }
    func changeBrushSize(increase: Bool) {
        guard brushStroke == nil else { return }
        // A step of a fifth, but always at least one pixel: 2 shrunk by a fifth would otherwise round back to 2,
        // leaving the smallest brushes out of reach.
        let current = brushSettings.diameter
        let stepped = increase ? max(current + 1, (current * 1.2).rounded()) : min(current - 1, (current / 1.2).rounded())
        brushSettings.diameter = min(2000, max(1, stepped))
    }

    /// Watercolor wash of the current selection, revealed a layer at a time, then one undo step.
    /// The wash is built in its own buffer, so the erases lift pigment and not the layer under it.
    /// Main actor: `Task.yield` would otherwise resume off the thread that owns AppKit.
    /// `path` fills that polygon instead of the current selection. A stroke script passes one;
    /// the menu command leaves it nil and keeps requiring a selection.
    @MainActor
    func watercolorFillSelection(path override: CGPath? = nil, red: CGFloat? = nil, green: CGFloat? = nil, blue: CGFloat? = nil, seed explicitSeed: UInt64? = nil, options explicitOptions: WatercolorOptions? = nil) async {
        let outline = override ?? selection?.path
        let region = outline.map { DocumentSelection(path: $0) }
        guard canEditLayers, let document, let layer = activeLayer, layer.isGroup == false, layer.adjustment == nil,
              let outline, let region, !region.isEmpty else {
            brushError = "Select an area to fill with watercolor."
            return
        }
        if override == nil {
            guard canEditPixels else { brushError = "Select an area to fill with watercolor."; return }
        }
        let contours = SelectionContours.make(from: outline)
        guard !contours.isEmpty else { brushError = "Select an area to fill with watercolor."; return }
        let seed = explicitSeed ?? brushSettings.naturalSeed ?? UInt64.random(in: 1...UInt64(UInt32.max))
        let options = (explicitOptions ?? watercolorOptions).clamped()
        let passes = WatercolorFill.passes(contours: contours, seed: seed, options: options)
        guard !passes.isEmpty else { return }
        let canvas = CGRect(origin: .zero, size: document.size)
        let tight = region.coverageBounds.integral.intersection(canvas)
        let margin = WatercolorFill.bleedMargin(bounds: tight, options: options)
        let area = tight.insetBy(dx: -margin, dy: -margin).intersection(canvas).integral.intersection(canvas)
        guard area.width >= 1, area.height >= 1, area.width * area.height <= CGFloat(DocumentLimits.documentPixelBudget) else {
            brushError = ProjectError.tooLarge.localizedDescription
            return
        }
        let palette = paletteColor(background: false)
        let ink = PaletteColor(red: red ?? palette.red, green: green ?? palette.green, blue: blue ?? palette.blue)
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false; cancelBrush() }
        do {
            var settings = brushSettings
            settings.natural = .round
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: true)
            stroke.selectionClip = options.clip ? try region.clip(canvas: document.size) : nil
            stroke.editName = "Watercolor Fill"
            guard area.width * area.height <= CGFloat(max(1, stroke.pixelLimit)) else { throw ProjectError.tooLarge }
            let buffer = try BrushRaster.context(width: Int(area.width), height: Int(area.height), mask: isMaskSelected)
            buffer.translateBy(x: -area.minX, y: -area.minY)
            brushStroke = stroke
            for pass in passes {
                WatercolorFill.draw(pass, red: ink.red, green: ink.green, blue: ink.blue, mask: isMaskSelected, in: buffer)
                guard let image = buffer.makeImage() else { throw ExportError.render }
                try stroke.compositeImage(image, in: area)
                brushRevision += 1
                await Task.yield()
            }
            if !isMaskSelected { NaturalShade.retint(buffer, red: ink.red, green: ink.green, blue: ink.blue) }
            NaturalShade.darkenRims(in: buffer)
            if let image = buffer.makeImage() { try stroke.compositeImage(image, in: area) }
            guard !stroke.patches.isEmpty else { return }
            try commitPaintSnapshot(stroke)
        } catch { brushError = error.localizedDescription }
    }

    /// Hatches the selection with the current natural brush (HB when the tip is still Round).
    /// `path` hatches that polygon instead of the current selection.
    @MainActor
    func hatchSelection(path override: CGPath? = nil, angle: CGFloat = 45, spacing explicitSpacing: CGFloat? = nil, seed explicitSeed: UInt64? = nil, options explicitOptions: HatchOptions? = nil) async {
        let outline = override ?? selection?.path
        guard canEditLayers, let document, let layer = activeLayer, layer.isGroup == false, layer.adjustment == nil,
              let outline, !DocumentSelection(path: outline).isEmpty else {
            brushError = "Select an area to hatch."
            return
        }
        if override == nil {
            guard canEditPixels else { brushError = "Select an area to hatch."; return }
        }
        let contours = SelectionContours.make(from: outline)
        guard !contours.isEmpty else { return }
        let options = explicitOptions ?? hatchOptions
        let chosen = options.brush ?? brushSettings.natural
        let kind: NaturalBrushKind = chosen == .round ? .hb : chosen
        let baseDiameter = options.diameter ?? brushSettings.diameter
        let spacing = explicitSpacing ?? options.spacing ?? max(4, baseDiameter * 0.7)
        let seed = explicitSeed ?? brushSettings.naturalSeed ?? UInt64.random(in: 1...UInt64(UInt32.max))
        let hatchAngle = explicitOptions == nil && angle == 45 ? options.angle : angle
        var lines = NaturalHatch.lines(contours: contours, angle: hatchAngle, spacing: spacing, seed: seed, jitter: options.rand, continuous: options.continuous, gradient: options.gradient)
        if let field = flowField {
            lines = field.steer(lines, step: max(2, spacing * 0.45))
        }
        guard !lines.isEmpty, let preset = kind.preset else { return }
        let gain = NaturalBrushEngine.strokeGain(kind: kind, seed: seed)
        var dabs: [NaturalDab] = []
        let styleJitter = options.brush != nil || options.diameter != nil
        for (index, line) in lines.enumerated() {
            let lineSeed = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
            var diameter = baseDiameter
            if styleJitter {
                var jitter = NaturalRNG(seed: lineSeed == 0 ? 1 : lineSeed)
                diameter *= CGFloat(jitter.uniform(0.9, 1.1))
            }
            let length = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let curve = NaturalBrushMath.curve(preset: preset, seed: lineSeed)
            let cap = NaturalBrushMath.envelope(plotted: length, length: max(length, 0.001), preset: preset, curve: curve)
            let walked = NaturalBrushEngine.walk(segments: [(line.start, line.end)], pressureStart: 1, pressureEnd: 1, cursor: .start, kind: kind, diameter: diameter, seed: lineSeed, gain: gain, wiggle: min(2, max(0, brushSettings.wiggle)), ending: true, span: max(length, 0.001))
            dabs.append(contentsOf: walked.dabs)
            dabs.append(contentsOf: NaturalBrushEngine.endCaps(at: line.end, pressure: cap, kind: kind, diameter: diameter, seed: lineSeed, gain: gain))
            if dabs.count > 12_000 { break }
        }
        guard !dabs.isEmpty else { return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            var settings = brushSettings
            settings.natural = .round
            if let red = options.red { settings.red = red }
            if let green = options.green { settings.green = green }
            if let blue = options.blue { settings.blue = blue }
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: true)
            // Continuous connectors run along the outline, so clipping to it would cut them in half.
            // The chords already end on the outline; p5.brush does not clip a hatch either.
            if override != nil, options.continuous == false { stroke.selectionClip = try DocumentSelection(path: outline).clip(canvas: document.size) }
            stroke.editName = "\(kind.rawValue) Hatch"
            try stroke.stampDabs(dabs)
            guard !stroke.patches.isEmpty else { return }
            try commitPaintSnapshot(stroke)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
