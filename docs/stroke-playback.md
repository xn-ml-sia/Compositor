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

Fills a polygon with the watercolor wash, as its own undo step named `Watercolor Fill`. It does not replace the person's selection. Bleed is allowed to leave the polygon unless `"clip":true`.

```json
{"op":"watercolor","layer":"Wash","polygon":[[20,20],[180,24],[170,140],[30,130]],"color":[0.2,0.45,0.85],"seed":5,"bleed":0.07,"texture":0.8,"border":0.5,"opacity":150,"direction":"out","angle":30,"scatter":true,"clip":false}
```

`opacity` is 0…255 (default 150). `direction` is `"out"` or `"in"`. `angle` is degrees and picks which vertex the wash starts from; omit it for a random start. `scatter` false skips the sparse texture layer. Older lines that only set `polygon`, `color`, and `seed` still fill.

### `hatch`

Hatches a polygon with the current brush (HB when the tip is still Round). Optional `color` overrides the brush color for this hatch. `angle` is degrees (default 45) and `spacing` is the gap in document pixels (default follows the brush size). `rand` defaults to 0. `continuous` true joins lines with zig-zag connectors. `gradient` from 0 to 1 opens the spacing as the hatch proceeds. `brush` and `diameter` are hatch-only; a set brush jitters each line's size by about 10 percent. Each line uses the pressure envelope for that brush.

```json
{"op":"hatch","layer":"Wash","polygon":[[20,20],[180,24],[170,140],[30,130]],"angle":45,"spacing":8,"seed":3,"rand":0,"continuous":true,"gradient":0.4,"brush":"HB","diameter":12}
```

### `field`

Turns a flow field on or off for every later stroke, hatch, and shape. `name` is `hand`, `curved`, `zigzag`, `waves`, `seabed`, `spiral`, `columns`, `custom`, or `none`. `wiggle` scales the field (a line with only `wiggle` uses the hand field). `seed` rebuilds the same field. A custom field supplies a row-major `angles` array in degrees, with `columns` and `rows`.

```json
{"op":"field","name":"waves","wiggle":1,"seed":3}
{"op":"field","name":"none"}
{"op":"field","name":"custom","columns":2,"rows":2,"angles":[0,90,10,-20],"wiggle":1}
```

### `flowLine`

Draws `length` pixels from `(x, y)` headed `direction` degrees, bent by the active field. With no field it is a straight line. It commits as one stroke.

```json
{"op":"flowLine","layer":"Wash","x":40,"y":80,"length":120,"direction":0,"pressure":1,"seed":7,"pace":"fast"}
```

### Shapes

`spline`, `circle`, `rect`, `arc`, `polygon`, `shape`, and `plot` can outline with the current brush, watercolor-fill, and hatch in one line. They follow the active field. `outline` defaults to true. `fill` and `hatch` use the same fields as those ops (`color`, `bleed`, `angle`, `rand`, `continuous`, and the rest). Omit them to skip that part.

```json
{"op":"spline","layer":"Wash","curvature":0.5,"points":[[20,40],[80,30,0.8],[120,70]],"seed":4}
{"op":"circle","layer":"Wash","x":90,"y":80,"radius":28,"r":0.2,"seed":5,"fill":{"color":[0.2,0.45,0.8],"opacity":150,"bleed":0.08},"hatch":{"angle":30,"spacing":7,"continuous":true}}
{"op":"rect","layer":"Wash","x":20,"y":20,"w":80,"h":40,"mode":"corner","outline":false,"fill":{"color":[0.8,0.3,0.2]}}
{"op":"arc","layer":"Wash","x":100,"y":100,"radius":40,"start":0,"end":200}
{"op":"polygon","layer":"Wash","points":[[10,10],[40,12,0.6],[30,40]]}
{"op":"shape","layer":"Wash","curvature":0.4,"closed":true,"points":[[10,10],[50,12],[40,40]]}
{"op":"plot","layer":"Wash","x":30,"y":30,"segments":[{"angle":0,"length":40,"pressure":1},{"angle":90,"length":24,"pressure":0.6}],"endPressure":0.4}
```

`circle`'s `r` is irregularity. `rect` `mode` is `"corner"` or `"center"`. `shape` with `curvature` 0 is the polyline, and `closed` true repeats the first point. `plot` is a sequence of angle (degrees) and length steps from the start point, the same idea as `beginStroke` / `move` / `endStroke`. A point inside a shape is `[x, y]` or `[x, y, pressure]`.

### `clear`

Clears one layer back to empty pixels covering the canvas. One undo step, `Clear Layer`.

```json
{"op":"clear","layer":"Petals"}
```

## While it plays

Points are handed to the brush over time, and the canvas redraws as they land. Closing the project during a stroke commits the points already drawn and does not resume that line. A line that has not started is left for the next open. Clicks on the canvas wait until the line in progress finishes.

`scripts/paint_flower.py` appends a small flower. `scripts/p5_features_demo.py` appends pressure presets, a watercolor rim, a flow field, a continuous hatch, and spline and circle shapes. Open a saved project, run either script with the package path, and watch the canvas.
