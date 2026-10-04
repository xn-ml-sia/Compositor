import AppKit

/// Tails `strokes.jsonl` and plays new lines through the brush. This is not a project reload:
/// the manifest and images are untouched, so undo survives and the painted pixels are ordinary edits.
/// Lines already in the file wait until the person presses Play. An outside writer does not have to stay connected.
extension ProjectController {
    /// Play starts or continues the recording. Pause holds the open stroke and leaves the document as it is.
    /// When the cursor is already at the end, Play rewinds it and starts from the first line.
    func toggleStrokePlayback() {
        if session.strokePlaybackWanted {
            session.strokePlaybackWanted = false
            return
        }
        guard let package = session.projectURL else { return }
        session.refreshStrokeScriptPresence()
        guard session.hasStrokeScript else { return }
        if !session.strokeScriptHasUnplayed, !session.strokePlaybackRunning {
            StrokeScriptReader.storeCursor(0, in: package)
            session.refreshStrokeScriptPresence()
        }
        session.strokePlaybackWanted = true
        noteStrokeScript()
    }

    func noteStrokeScript() {
        session.refreshStrokeScriptPresence()
        guard session.strokePlaybackWanted, !session.isStrokeScriptPaused else { return }
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
        defer {
            if playing {
                session.isReplayingStrokes = false
                session.strokePlaybackRunning = false
            }
        }
        while !Task.isCancelled, session.projectURL == package, !session.isStrokeScriptPaused {
            if !session.strokePlaybackWanted {
                if !playing {
                    session.isReplayingStrokes = true
                    session.strokePlaybackRunning = true
                    playing = true
                }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let pulled = StrokeScriptReader.readNew(in: package)
            let items = pulled.items
            if items.isEmpty {
                // A comment or blank line still moves the cursor, once, so the next look starts after it.
                if pulled.offset > StrokeScriptReader.rawCursor(in: package) {
                    StrokeScriptReader.storeCursor(pulled.offset, in: package)
                }
                session.strokePlaybackWanted = false
                session.strokePlaybackRunning = false
                session.isReplayingStrokes = false
                session.refreshStrokeScriptPresence()
                return
            }
            if !playing {
                session.isReplayingStrokes = true
                session.strokePlaybackRunning = true
                playing = true
            }
            for item in items {
                while !session.strokePlaybackWanted {
                    if Task.isCancelled || session.isStrokeScriptPaused || session.projectURL != package { return }
                    try? await Task.sleep(for: .milliseconds(40))
                }
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
