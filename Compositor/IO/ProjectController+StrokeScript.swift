import AppKit

/// Tails `strokes.jsonl` and plays new lines through the brush. This is not a project reload:
/// the manifest and images are untouched, so undo survives and the painted pixels are ordinary edits.
extension ProjectController {
    func noteStrokeScript() {
        if session.isStrokeScriptPaused { return }
        if externalChanges.strokeTask != nil {
            externalChanges.strokeDirty = true
            return
        }
        externalChanges.strokeGeneration += 1
        let generation = externalChanges.strokeGeneration
        externalChanges.strokeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A project switch starts a newer task. This one must not drop it on the way out.
                if self.externalChanges.strokeGeneration == generation {
                    self.externalChanges.strokeTask = nil
                }
                if self.externalChanges.strokeDirty, self.externalChanges.strokeTask == nil {
                    self.externalChanges.strokeDirty = false
                    self.noteStrokeScript()
                }
            }
            await self.drainStrokeScript()
        }
    }

    private func drainStrokeScript() async {
        guard let package = session.projectURL else { return }
        var playing = false
        defer { if playing { session.isReplayingStrokes = false } }
        while !Task.isCancelled, session.projectURL == package, !session.isStrokeScriptPaused {
            let pulled = StrokeScriptReader.readNew(in: package)
            let items = pulled.items
            if items.isEmpty {
                // A comment or blank line still moves the cursor, once, so the next look starts after it.
                if pulled.offset > StrokeScriptReader.rawCursor(in: package) {
                    StrokeScriptReader.storeCursor(pulled.offset, in: package)
                }
                return
            }
            if !playing {
                session.isReplayingStrokes = true
                playing = true
            }
            for item in items {
                if Task.isCancelled || session.isStrokeScriptPaused { return }
                let applied = await session.playStrokeOp(item.op, instant: false)
                // A stroke that already started is committed inside play, so the cursor moves even if
                // the project is closing. Leaving it behind would paint that stroke again on reopen.
                if applied, session.projectURL == package { StrokeScriptReader.storeCursor(item.endOffset, in: package) }
                if !applied || Task.isCancelled || session.projectURL != package { return }
            }
            if pulled.offset > (items.last?.endOffset ?? pulled.offset) {
                StrokeScriptReader.storeCursor(pulled.offset, in: package)
            }
        }
    }
}
