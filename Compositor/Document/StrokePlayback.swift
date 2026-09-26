import AppKit

// Plays stroke-script ops through the brush the pointer uses: begin, a point at a time, then commit.
// Each stroke is its own undo step, named by the preset. Times come from StrokeTiming; tests pass
// `instant` so the same points commit without waiting on the clock.

extension EditorSession {
    /// Plays ops in order. `instant` commits every point before returning, which is what tests use.
    /// A live playback sleeps so the canvas can show the stroke as it grows.
    @MainActor
    func playStrokeScript(_ ops: [StrokeOp], instant: Bool) async {
        for op in ops {
            if Task.isCancelled { return }
            await playStrokeOp(op, instant: instant)
        }
    }

    /// False when the op was not applied because playback was cancelled first. A stroke that already
    /// started is finished and counts as applied, so it is not painted a second time later.
    @MainActor
    @discardableResult
    func playStrokeOp(_ op: StrokeOp?, instant: Bool) async -> Bool {
        guard await waitUntilStrokeScriptCanEdit() else { return false }
        switch op {
        case .none:
            brushError = "Skipped a stroke line that is not a known op."
            return true
        case .layer(let name, let id):
            addStrokeScriptLayer(name: name, id: id)
        case .brush(let brush):
            strokeScriptBrush = brush
            if let layer = brush.layer { guard aimStrokeScript(at: layer) else { return true } }
            applyStrokeScriptBrush(brush, seed: nil)
        case .stroke(let draw):
            if await playStrokeDraw(draw, instant: instant) == false { return false }
        case .watercolor(let fill):
            await playStrokeFill(fill)
        case .hatch(let hatch):
            await playStrokeHatch(hatch)
        case .clear(let layer):
            clearStrokeScriptLayer(layer)
        }
        return true
    }

    @MainActor
    private func waitUntilStrokeScriptCanEdit() async -> Bool {
        while !canEditLayers || brushStroke != nil {
            if Task.isCancelled || isStrokeScriptPaused { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if isStrokeScriptPaused { return false }
        return true
    }

    @MainActor
    private func aimStrokeScript(at token: String) -> Bool {
        guard let id = strokeScriptLayer(token) else {
            brushError = "Stroke script has no layer “\(token)”."
            return false
        }
        if activeLayerID != id { selectLayer(id) }
        guard activeLayerID == id else {
            brushError = "Stroke script could not select “\(token)”."
            return false
        }
        isMaskSelected = false
        return true
    }

    private func strokeScriptLayer(_ token: String) -> UUID? {
        if let id = UUID(uuidString: token), document?.layers.contains(where: { $0.id == id }) == true { return id }
        return document?.layers.last(where: { $0.name == token })?.id
    }

    @MainActor
    private func addStrokeScriptLayer(name: String, id: UUID?) {
        guard var document else { return }
        if let id, document.layers.contains(where: { $0.id == id }) {
            selectLayer(id)
            return
        }
        if id == nil, let existing = document.layers.last(where: { $0.name == name }) {
            selectLayer(existing.id)
            return
        }
        guard document.layers.count < 10_000 else { brushError = "Stroke script could not add another layer."; return }
        let layerID = id ?? UUID()
        let layer = ImageLayer(id: layerID, asset: nil, name: name, isVisible: true, transform: LayerTransform(origin: .zero, size: document.size))
        beginEdit("New Blank Layer")
        document.layers.append(layer)
        self.document = document
        activeLayerID = layerID
        endEdit()
    }

    @MainActor
    private func clearStrokeScriptLayer(_ token: String) {
        guard aimStrokeScript(at: token), let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }),
              document?.layers[index].isGroup == false, document?.layers[index].adjustment == nil,
              let size = document?.size else { return }
        beginEdit("Clear Layer")
        document?.layers[index].asset = nil
        document?.layers[index].text = nil
        document?.layers[index].shape = nil
        document?.layers[index].transform = LayerTransform(origin: .zero, size: size)
        endEdit()
    }

    @MainActor
    private func applyStrokeScriptBrush(_ brush: StrokeScriptBrush, seed: UInt64?) {
        if tool != .brush { selectTool(.brush) }
        var settings = brushSettings
        settings.natural = brush.preset
        settings.diameter = brush.diameter
        settings.red = brush.red
        settings.green = brush.green
        settings.blue = brush.blue
        settings.opacity = brush.opacity
        settings.hardness = brush.hardness
        settings.wiggle = brush.wiggle
        settings.naturalSeed = seed
        brushSettings = settings
        brushMode = brush.erase ? .erase : .paint
    }

    /// True when the line should be consumed. False when playback was cancelled before the first dab,
    /// so the same line can start again later. A stroke that already started is finished here.
    @MainActor
    private func playStrokeDraw(_ draw: StrokeDraw, instant: Bool) async -> Bool {
        if let layer = draw.layer, !aimStrokeScript(at: layer) { return true }
        guard activeLayer != nil else { brushError = "Stroke script has no layer to paint."; return true }
        let brush = strokeScriptBrush ?? StrokeScriptBrush(settings: brushSettings, erase: brushMode == .erase)
        let savedSmoothing = brushSettings.smoothing
        applyStrokeScriptBrush(brush, seed: draw.seed)
        brushSettings.smoothing = 0
        var started = false
        defer {
            // Finish while smoothing is still off, so the stroke does not chase the last point a second time.
            if started, brushStroke != nil { finishBrushImmediately() }
            brushSettings.smoothing = savedSmoothing
            brushSettings.naturalSeed = nil
        }
        let times = StrokeTiming.times(draw.points, pace: instant ? .fast : draw.pace)
        var elapsed: CGFloat = 0
        for (sample, due) in zip(draw.points, times) {
            if Task.isCancelled { return started }
            if !instant {
                let wait = due - elapsed
                if wait >= 1.0 / 60 {
                    try? await Task.sleep(for: .milliseconds(Int(min(wait, 5) * 1000)))
                    if Task.isCancelled { return started }
                    elapsed = due
                }
            }
            let point = CGPoint(x: sample.x, y: sample.y)
            brushPointingPressure = sample.pressure
            if !started {
                beginBrush(at: point, pressure: sample.pressure)
                guard brushStroke != nil else {
                    brushError = brushError ?? "Stroke script could not start a stroke."
                    return true
                }
                started = true
            } else {
                continueBrush(at: point, pressure: sample.pressure)
            }
        }
        return true
    }

    @MainActor
    private func playStrokeFill(_ fill: StrokeFill) async {
        guard aimStrokeScript(at: fill.layer), let path = StrokeScriptReader.polygonPath(fill.polygon) else { return }
        await watercolorFillSelection(path: path, red: fill.red, green: fill.green, blue: fill.blue, seed: fill.seed)
    }

    @MainActor
    private func playStrokeHatch(_ hatch: StrokeHatch) async {
        guard aimStrokeScript(at: hatch.layer), let path = StrokeScriptReader.polygonPath(hatch.polygon) else { return }
        var brush = strokeScriptBrush ?? StrokeScriptBrush(settings: brushSettings, erase: false)
        if let red = hatch.red, let green = hatch.green, let blue = hatch.blue {
            brush.red = red
            brush.green = green
            brush.blue = blue
        }
        applyStrokeScriptBrush(brush, seed: hatch.seed)
        await hatchSelection(path: path, angle: hatch.angle, spacing: hatch.spacing, seed: hatch.seed)
    }
}
