# Stroke playback

An open Compositor project can be painted by something that only writes files. Append one JSON object per line to `strokes.jsonl` inside the `.comp` package. The app tails that file and plays each line through the same brush a drag uses, at drawing speed, then commits it. Undo names follow the preset (`HB Stroke`, `Charcoal Erase`, `Watercolor Fill`).

This is separate from editing `manifest.json`. A stroke script does not reload the project, does not clear undo, and does not ask the person to revert. The painted pixels become ordinary layer pixels.

```
Demo.comp/
├── manifest.json
├── images/
├── strokes.jsonl      append-only instructions
└── strokes.cursor     byte offset the app has already played
```

`strokes.cursor` is a decimal byte offset. The app writes it after each line it finishes. Reopening the project continues after that offset, so finished lines are not painted again. Saving the project keeps both files; the package is replaced atomically and would otherwise drop them. Choosing Don't Save when closing puts the cursor back to the last save, so strokes that were never saved play again. The file is append-only: do not rewrite or shorten it. If you replace it, delete `strokes.cursor` as well or the old offset will skip the new text. A shorter file pulls the cursor back to the new end without painting those bytes again. A line without a closing newline is ignored until the newline arrives, so a half-written append is safe.

Lines that start with `#` are comments. A line the app does not understand is skipped and marked consumed, so one bad line does not stall the rest.

## Ops

Every object has an `"op"` field. `layer` is a layer id (UUID) or its name. A name picks the topmost layer with that name.

### `layer`

Creates a blank layer, or selects it when that id or name already exists. The new layer covers the canvas and has no pixels yet, so the next stroke can paint it.

```json
{"op":"layer","name":"Petals","id":"6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F"}
```

`id` is optional. Omit it and the app makes one.

### `brush`

Sets the brush used by later strokes and hatches. It is not an undo step.

```json
{"op":"brush","preset":"HB","diameter":22,"color":[0.1,0.2,0.9,1],"opacity":1,"hardness":1,"wiggle":0,"erase":false,"layer":"Petals"}
```

`preset` is `Round`, `HB`, `2B`, `2H`, `Colored Pencil` (or `cpencil`), `Charcoal`, `Pastel`, `Crayon`, `Marker`, `Pen`, `Rotring`, or `Spray`. `color` is `[red, green, blue]` or `[red, green, blue, alpha]` in 0…1. `opacity` overrides the alpha. `erase` true uses the eraser. `layer` is optional.

### `stroke`

Feeds points through the live brush, then commits one undo step.

```json
{"op":"stroke","layer":"Petals","seed":42,"pace":"live","points":[[12,40,1],[60,42,0.8,0.2],[100,38]]}
```

A point is `[x, y]`, `[x, y, pressure]`, or `[x, y, pressure, t]`, in document pixels, origin at the top left. `pressure` runs from 0 (light) to 1 (firm). Omit it and the brush uses speed, the same fallback a mouse has. `t` is seconds from the start of this stroke. Omit it and the point is spaced at 640 pixels per second.

`pace` is `"live"` (default), `"fast"` (eight times quicker), or a number such as `2` for twice as fast. `seed` makes the same stroke replay the same dabs. Use an integer up to 2^53, or a string if you need a larger one.

The stroke is clipped by the current selection, the same way a drag is. Smoothing is ignored for scripted points so they land where you wrote them. The person's smoothing is restored when the stroke ends.

### `watercolor`

Fills a polygon with the watercolor wash, as its own undo step named `Watercolor Fill`. The polygon is the clip. It does not replace the person's selection.

```json
{"op":"watercolor","layer":"Wash","polygon":[[20,20],[180,24],[170,140],[30,130]],"color":[0.2,0.45,0.85],"seed":5}
```

### `hatch`

Hatches a polygon with the current brush (HB when the tip is still Round). Optional `color` overrides the brush color for this hatch. `angle` is degrees (default 45) and `spacing` is the gap in document pixels (default follows the brush size).

```json
{"op":"hatch","layer":"Wash","polygon":[[20,20],[180,24],[170,140],[30,130]],"angle":45,"spacing":8,"seed":3}
```

### `clear`

Clears one layer back to empty pixels covering the canvas. One undo step, `Clear Layer`.

```json
{"op":"clear","layer":"Petals"}
```

## While it plays

Points are handed to the brush over time, and the canvas redraws as they land. Closing the project during a stroke commits the points already drawn and does not resume that line. A line that has not started is left for the next open. Clicks on the canvas wait until the line in progress finishes.

`scripts/paint_flower.py` appends a small flower. Open a saved project, run the script with the package path, and watch the canvas.
