# Ikebana for iPhone, v1

An iPhone-only port of Compositor, cut down to one job: open a bundled ikebana template and rearrange its parts with touch. The person composes with flowers — stem, leaf, berry, bloom, grass, vessel, stone, moss — and the empty paper between them is the point. That emptiness is *ma*. Nothing in v1 paints, imports a file, or plays a stroke recording.

This document is the product and the technical spec. It describes the Mac `.comp` package as it actually loads today, and the template format the Mac app would export from one. No iOS code is implied to exist yet.

## Goals

- A person on an iPhone opens one of a few templates bundled in the app and rearranges it into their own composition.
- Each movable part is its own picture. A stem owns its leaves, berries, and flower: they follow the stem when it moves, rotates, scales, flips, or bends, and they cannot be selected or pulled off.
- Nothing is rooted. The vessel, stones, moss, grass, and every stem move freely on the canvas.
- Transforms: move, rotate, uniform scale, horizontal flip, bend a stem, duplicate, delete, undo, redo.
- The picture on screen is the pre-rendered artwork. Bending warps the stem's image along its centerline. iOS does not run a brush engine.
- Shin, Soe, and Hikae (heaven, human, earth) can be shown as angled rays from the vessel mouth. They are off by default.
- The arrangement autosaves. The person can export a PNG.

## Non-goals (v1)

- Brushes, watercolor, hatch, flow fields, or any stroke playback on the phone.
- Opening a `.comp`, Photos import, Files import, or iCloud documents.
- iPad, landscape, and any layout that is not a portrait iPhone.
- Detaching a child from its stem, moving a child on its own, or bending a child.
- Multi-select, z-order editing, snapping, masks, blend modes, opacity, text, adjustments.
- Accounts, sharing destinations beyond the system share sheet, and printing.

## What the Mac file actually is

A `.comp` is a package. Current saves are format `com.compositor.project`, version 11, sRGB. The pieces v1 cares about:

```
Example.comp/
├── manifest.json          document id, pixel size, layers, optional guides
├── images/
│   └── <LAYER-UUID>.png   8-bit RGBA, unrotated source pixels
├── strokes.jsonl          optional, append-only, one JSON object per line
└── strokes.cursor         optional, decimal byte offset already played
```

`manifest.json` lists layers bottom to top. A layer has a UUID, a name, visibility, opacity, blend mode, and a `transform`: `origin` (top-left of the unrotated box), `size`, `rotation` in degrees clockwise around the **center** of that box, `flipX`, `flipY`, and `sampling`. The PNG is not rotated or flipped; the transform is applied when drawing. There is no stored pivot. `flipX` / `flipY` keep `size` positive. `LayerRenderer` draws by translating to the center, rotating clockwise, then scaling by the flip signs.

Stroke playback is a separate file. `strokes.jsonl` is played on demand through the same brushes a drag uses. `strokes.cursor` is the byte offset already played, not a list of objects. A line the player does not know is skipped and the cursor moves past it. Saving the package copies both files byte for byte. The ops that matter for authoring a template are `layer`, `brush`, `stroke`, `watercolor`, `hatch`, `field`, `flowLine`, and the shape ops (`spline`, `circle`, `rect`, `arc`, `polygon`, `shape`, `plot`). Points are document pixels, origin top-left, y down. After playback the marks are ordinary layer pixels. The phone never sees these ops.

These facts change the model the phone would otherwise inherit:

- **A folder is not a stem.** Version 2 `parentID` must point at a group. A group has no image and is pass-through: children are drawn on their own, not as one picture. Selecting a folder on the Mac rewrites each descendant's own `transform` (`LayerTransform.following`). That is an affine edit in one session. It is not a saved parent-relative constraint, and it cannot bend. iOS parent links are new data in the template. They are not `.comp` `parentID`s.
- **Tags do not belong in `manifest.json`.** The app re-encodes `ProjectLayerRecord` on save, so unknown manifest keys are dropped. An extra file in the package is dropped too: the atomic save writes only `manifest.json`, `images/`, `QuickLook/`, `strokes.jsonl`, and `strokes.cursor`.
- **Tags do belong in `strokes.jsonl`.** Unknown keys on a known op are ignored. An unknown `op` is skipped. The bytes survive the next save. The exporter reads the file from byte 0 and ignores `strokes.cursor`.
- **Mac guides are not these rays.** Version 8 `guides` are unnamed horizontal or vertical lines (`id`, `axis`, `position` in document pixels). The exporter does not read them. The rays are a `guides` line in `strokes.jsonl`. With no such line, and no `guides` object already on the template, export measures the vessel mouth and the tallest stem.
- **Mac PNG export** (`ImageExporter.pngData`) is the canvas in pixels, sRGB, alpha kept, guides omitted, DPI from `resolution` or 72. Quick Look's JPEG is a different thing (flattened on white, long side ≤ 1024).
- **Nothing on the Mac bends a centerline.** `MetalWarp` is smudge and liquify. `DistortWarp` is a four-corner distort. Neither is a ribbon warp, and neither shader should be copied to iOS.

## User flows

1. **Launch.** The app opens the last template the person used, or the first bundled one. If that template has an autosaved arrangement, it appears. Otherwise the template's rest pose appears. The paper is a warm off-white (`#F3EFE6`). Guide lines are off.
2. **Switch template.** A control lists the bundled templates by name. Choosing one loads its autosave, or its rest pose. The previous template's arrangement is already on disk.
3. **Select.** Tap an element. The stem, vessel, stone, moss, or grass lights up. A tap on a leaf, berry, or flower selects the stem that owns it. A tap on empty paper clears the selection. Empty paper is easy to hit; that is *ma*, and it must not stick to a nearby stem.
4. **Place.** Drag the body to move. Pinch to scale. Twist with two fingers to rotate. Flip with the flip button. On a stem, drag the tip handle to bend. Children follow through all of these.
5. **Duplicate or delete.** A small menu on the selection offers Duplicate and Delete. Duplicate copies the selected root and everything it owns, nudged down-right, and selects the copy. Delete removes that root and everything it owns.
6. **Undo, redo, reset.** Undo and redo step through committed edits in this session. Reset, behind a confirm, restores the template's rest pose.
7. **Guides.** A toggle shows Shin, Soe, and Hikae when the template defines them. A second toggle mirrors the rays left/right. The origin, at the vessel mouth, can be dragged. Visibility, mirror, and the dragged origin are remembered on the phone per template. They are not part of the arrangement and are not exported.
8. **Export.** Share writes one PNG and presents the system share sheet. The arrangement is already saved.

One finger never both moves and bends: the finger either started on the tip handle or it did not. Two fingers never move the element and never bend it.

## Element model

An **element** is one trimmed transparent image plus placement. Kinds:

| Kind | Bend | May have children | Selectable |
| --- | --- | --- | --- |
| `stem` | yes | yes | yes |
| `flower`, `leaf`, `berry` | no | no | no; the tap selects the parent stem |
| `grass`, `vessel`, `stone`, `moss` | no | no | yes |

A child is parented to a stem. One level only: a child has no children. A berry that sits on a flower is parented to the same stem, at the same station along it, not to the flower. Leaves that should flex are painted into the stem image and warp with it. Leaves, berries, and flowers that should keep their shape are child elements: they ride a point on the centerline and rotate with the tangent. They are not mesh-warped. v1 cannot bend a child.

The selectable object is always a **root** (no parent). Transforms apply to that root. Children are posed entirely from the root, the rest attachment, and the current bend.

Z-order is an integer, higher on top. It is authored in the template. Duplicate lifts the copy above every existing element, preserving order inside the copied tree. v1 has no send-forward control.

### How a child follows

The template stores, in the stem's unflipped local pixels:

- `attach`, a fraction from 0 to 1 along the rest centerline's arc length.
- `offset`, the child's anchor minus that point on the rest centerline, rotated into the rest tangent frame (tangent, clockwise normal).
- `localRotation`, the child's clockwise degrees minus the stem's clockwise degrees and the rest tangent's angle. Mac rotation is absolute, and the phone adds the stem's rotation again at draw time, so both have to come out or a turned stem turns the flower twice.
- `localScale`, the child's uniform scale divided by the stem's scale at export.
- `flipX`, the child's own horizontal flip, fixed after export.

At draw time, take the bent centerline at the same fraction: point `G'`, tangent angle `τ'`. The child's anchor in stem-local pixels is `G'` plus `offset` rotated by `τ'`. Its rotation is `τ' + localRotation`. Its scale is the stem's scale times `localScale`. The stem's canvas placement (anchor position, rotation, scale, flip) then carries the child the same way it carries the stem image. A stem flip mirrors local x about the stem anchor and negates angles before that placement.

Move, rotate, scale, and flip of the stem therefore move the children with no extra saved numbers. Bend recomputes `G'` and `τ'` only.

## Template format

The Mac exporter writes a folder the iOS app bundles. It is not a `.comp` and it is not opened by the Mac editor.

```
Camellia.ikebana/
├── manifest.json
└── images/
    ├── stem-main.png
    ├── camellia.png
    └── vessel.png
```

`manifest.json`, format `com.seiandshin.template`, version 1:

```json
{
  "format": "com.seiandshin.template",
  "version": 1,
  "id": "camellia-slanted",
  "name": "Camellia, slanted",
  "canvas": { "width": 1170, "height": 2000 },
  "guides": {
    "origin": [640, 1580],
    "shinLength": 900,
    "rays": [
      { "role": "shin", "angle": -12, "length": 1, "marker": "circle" },
      { "role": "soe", "angle": -45, "length": 0.75, "marker": "square" },
      { "role": "hikae", "angle": 75, "length": 0.5, "marker": "triangle" }
    ]
  },
  "elements": [
    {
      "id": "stem-main",
      "kind": "stem",
      "image": "stem-main.png",
      "parent": null,
      "z": 2,
      "anchor": [48, 610],
      "center": [640, 1180],
      "rotation": 18,
      "scale": 1,
      "flipX": false,
      "centerline": [[48, 610], [70, 430], [120, 180], [150, 40]]
    },
    {
      "id": "camellia",
      "kind": "flower",
      "image": "camellia.png",
      "parent": "stem-main",
      "z": 3,
      "anchor": [40, 46],
      "attach": 0.96,
      "offset": [0, -8],
      "localRotation": -12,
      "localScale": 1,
      "flipX": false
    }
  ]
}
```

Coordinates are pixels, origin top-left, y down, clockwise degrees, the same convention as `LayerTransform`. `canvas` is the source document's `width` and `height`.

For every element:

- `anchor` is the pivot in the trimmed image's local pixels. Rotation and scale happen about it. A stem's anchor is the first centerline point (the base). Anything else defaults to the image center, which is what the Mac app rotates around.
- `center` is where that anchor sits on the template canvas in the rest pose. Roots use this as the initial arrangement. Children omit it; `offset` carries their rest placement instead.
- `scale` is uniform. `1` means one image pixel per canvas pixel.
- `centerline` is required for `stem`, forbidden otherwise. At least two points, in local image pixels, base first, tip last. Segment lengths must be positive. It should run through the opaque art. The exporter warns if an opaque pixel's nearest centerline point is farther than the stem's own half-width pad (see Bend).

`guides` comes from a `guides` line in the project's `strokes.jsonl`. That line is written onto the template and replaces an object already there. With no `guides` line, the exporter leaves an existing `guides` object in place when it rewrites a template, so rays added by hand survive a re-export. With no line and no object, it writes a default: `origin` is the vessel mouth and `shinLength` is the tallest stem, with the angles and length fractions below. `guides` is omitted only when that default cannot be measured (no vessel element, or no stem). It is not derived from the Mac document's `guides` array.

`origin` is the vessel mouth in canvas pixels. `shinLength` is Shin's length in those same pixels. Each ray's `length` is a fraction of `shinLength`: Shin 1, Soe 3/4, Hikae 1/2. `angle` is degrees off straight up, positive clockwise (to the right on screen). The unmirrored example is the front elevation (立面図): Shin and Soe lean to the same side, both left of vertical, Shin at −12° (inside the usual 10°–15° lean) and Soe at −45°; Hikae leans to the opposite side, at +75°. The app draws the stored angles and does not clamp them. Markers are Shin's circle (真), Soe's square (副), and Hikae's triangle (控). The top plan in the same diagram is not a second set of rays, and the shorter side stems are not guides.

On the phone the three rays are faint dashed lines from the origin to those lengths, with a small marker at each end. They do not snap. Mirror negates every angle and leaves lengths alone. Dragging the origin moves only that point; it starts at the template `origin`. Visibility (off by default), mirror (off by default), and a dragged origin are device state per template id, not fields of the arrangement file.

Images are 8-bit sRGB PNG, RGBA, trimmed to the opaque bounding box so a full-canvas layer does not become a full-canvas texture. Long side of the canvas and of any image is at most 2048. The exporter refuses a larger source rather than downsampling in secret.

### Identifying elements in the Mac document

Today a layer has a UUID and a name, and a played stroke is just pixels. The exporter needs an id, a kind, a parent, an anchor, and, for a stem, a centerline. Those have to be written where a later Mac save will not delete them.

**Write one `element` line per part into `strokes.jsonl`.** Playback parses the line and does not paint it: the pixels are already on the layer, the brush is unchanged, and there is no undo step. The cursor moves past the line. A line that says `element` but is not a valid one is skipped the same way as any unknown op, and the exporter reports that line instead of dropping the part. The next save copies the line verbatim. How a script appends these lines is in [Stroke playback](stroke-playback.md). `examples/SeiShinSample.comp` is a tagged project small enough to export without a brush script.

```json
{"op":"element","id":"stem-main","kind":"stem","layer":"6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F","anchor":[420,900],"centerline":[[420,900],[460,640],[520,280]]}
{"op":"element","id":"camellia","kind":"flower","layer":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","parent":"stem-main","attach":0.96}
```

`layer` is the layer UUID. A name is legal in stroke ops but the wrong choice here: a name resolves to the topmost layer with that name. `centerline` and `anchor` are document pixels, the same space as `stroke` points. `parent` is an element id, not a layer id. `attach` defaults to 1 (the tip) for a child. The author copies the centerline from the stem's path; the exporter does not infer it from dab positions, because wiggle, hatch, and watercolor bleed are not a spine.

Authoring rules the exporter enforces:

- One element, one layer. Paint the stem and each rigid child on its own layer (`op: layer` with an explicit `id`, then the strokes, watercolor, and hatches for that layer).
- An element id is at most 64 characters of letters, numbers, hyphens, and underscores. It is also the PNG's file name.
- Every referenced layer exists, has an image, and is not a group. Two element lines may not share an `id` or a `layer`.
- `parent` refers to a `stem` element. No cycles, no grandchildren. A flower, leaf, or berry has to have that parent. A stem, grass, vessel, stone, or moss does not have one.
- A stem has a centerline of at least two points. Other kinds do not.
- Untagged layers (a sketch, a paper wash) are left out of the template. The phone draws its own paper.

The exporter converts document-pixel anchors and centerlines into the trimmed PNG's local pixels by inverting that layer's rest `transform` (center, clockwise rotation, flips, scale). Non-uniform Mac scale (`size` versus image pixel size differs between axes) is baked into the PNG and the template scale becomes 1 on both axes. Opacity below 1 and a raster mask are baked into alpha. A vertical flip is baked into the pixels, because a template element stores only `flipX`. A live clipping mask (`maskSourceID`), an adjustment, or a layer effect fails the export with a message to merge it first: the phone has no effects stack. A blend mode other than Normal is exported as the layer's stored pixels and the exporter warns; authors paint these templates in Normal. A stem's exported anchor is the first centerline point; an `anchor` on that element line is kept in `strokes.jsonl` and not used.

**Alternatives, and why they are worse:**

| Approach | Why it loses |
| --- | --- |
| Encode kind and parent in the layer name (`flower@stem-main`) | Names round-trip, and that is all they do. There is no centerline or anchor, names collide, and a rename looks like a data change. Acceptable only as a manual fallback the exporter refuses by default. |
| A Mac folder per stem | `parentID` cannot point at the stem image. The folder has no pixels and no centerline. Transforming it once on the Mac still saves absolute per-layer boxes. Bend has nowhere to live. |
| New keys on the layer record, format version 12 | The right long-term home, once the app round-trips them. Until then a save strips unknown manifest keys. Not usable for templates authored before that change. |
| `elements.json` beside the images inside the `.comp` | The next save deletes it. The package replacement does not keep unknown files. |
| Skeletonize the PNG, cluster strokes, guess parents | Watercolor rims and hatches do not have a single spine, and no clustering can know that a flower belongs to a stem. |

### Guides in the Mac document

Write a `guides` line into the same `strokes.jsonl`. Playback skips it, as it skips `element`. The exporter reads it from byte 0. A later `guides` line replaces an earlier one whole, so a correction is appended rather than merged. A line that says `guides` but is not valid fails the export and names the line. How a script appends lines is in [Stroke playback](stroke-playback.md).

```json
{"op":"guides","origin":[640,1580],"shinLength":900}
```

`origin` is the vessel mouth in document pixels. `shinLength` is Shin's length in those pixels and has to be positive. Omit `rays` and the exporter writes the front elevation above: Shin −12° at length 1, Soe −45° at 3/4, Hikae +75° at 1/2, markers circle, square, and triangle. To store other angles, include `rays` with all three roles. Each ray's `length` is a fraction of `shinLength` and has to be positive. The marker is fixed for the role; omit it and the exporter fills it in.

With no `guides` line, export keeps a `guides` object already on the template. With neither, it measures one. The origin is the midpoint of the top edge of the topmost vessel layer's bounds. Rotation carries that edge about the layer center, so a turned vase keeps its mouth on the rim. Flips mirror the pixels inside those bounds and do not move the point. Empty pixels inside the box count: this is the layer bounds, not the trimmed opaque art, so a layer with blank pixels above the rim should carry a `guides` line. `shinLength` is the centerline length of the tallest stem, in document pixels. Tallest means the greatest vertical span of the centerline; the same span keeps the longer line, then the lower stem. A long stem that leans over loses to a taller one. Mac alignment guides are not consulted. A project with no vessel element or no stem still omits `guides`.

## Gestures

The canvas is aspect-fitted to the portrait screen. Pinch and twist never zoom or scroll the view; if a template does not fit, it is letterboxed, not panned. Chrome buttons (flip, undo, redo, guides, export, template list) take their own taps.

| Input | Target | Result |
| --- | --- | --- |
| Tap | topmost sprite whose pixel alpha is ≥ 16, else empty paper | Select that root, or the parent stem if the sprite is a child. Empty clears the selection. |
| One-finger drag, not on the tip handle | the root under the finger (a child counts as its stem). The drag selects it. | Translate that root's anchor. Its children follow. A drag on empty paper does nothing. |
| One-finger drag starting on the tip handle | selected stem | Bend. The handle is a 44 pt square around the current tip, hit-tested before the body. |
| One-finger drag starting on the guide origin | the mouth point, and only while guides are visible | Move the guide origin. A 44 pt hit target, tested before any element. Not an arrangement edit: no undo step, no arrangement autosave. |
| Pinch | selected root | Uniform scale about the anchor. |
| Two-finger twist | selected root | Add the twist angle to `rotation`, about the anchor. |
| Flip button | selected root | Toggle horizontal flip about the anchor and negate `rotation`, matching Mac `flipLayers(horizontally: true)`. |
| Menu: Duplicate | selected root | Copy the root and its descendants. New instance ids. Root `center` shifts by (24, 24) canvas pixels. The block's z starts at max existing z + 1. |
| Menu: Delete | selected root | Remove the root and its descendants. |
| Undo / Redo | session stack | One step is one finished gesture or one button. Cap 50. A new edit drops the redo branch. |
| Reset | confirm | Replace the arrangement with the template rest pose. One undo step. |

Conflict rules:

- Pinch and twist run together. They do not translate and they do not bend.
- A second finger cancels a one-finger move or bend that has not been committed; the element returns to where the gesture began. The two-finger gesture then proceeds.
- The tip handle wins over the body only when the touch *begins* inside the handle. Sliding onto the tip during a move does not start a bend.
- Guide rays are not hit targets and do not snap. The origin handle is the only guide hit, and only while the rays are visible. It wins over a stem underneath.
- Children are never the selected object, so they have no handle and no menu.
- Scale and rotation stay on the anchor, not the finger centroid, so a stem grows from its base and a vessel grows from its middle. The fingers will not stay glued to the same pixels. That is the trade for a pivot that matches the plant.

An arrangement gesture commits on finger-up: one undo step, then autosave. Movement during the gesture is a preview and is not saved on its own. Dragging the guide origin does not.

## Bend

Bending is a mesh warp of the stem PNG along a curve of the authored length. Child images are not warped.

**Rest centerline.** Resample the authored polyline to `n = 32` stations `R[0...31]` at equal arc length. `L` is the authored length, so each segment is `L / 31`. `R[0]` is the anchor. Station `i` has fraction `u = i / 31`.

**When the tip is at rest** (`bendTip` null, or equal to `R[31]`), the drawn stations `C[i]` are `R[i]`. The mesh below is then an identity, within the grid, so an unbent stem is the PNG.

**Drag.** The finger position is converted into the stem's unflipped local pixels (inverse of flip, rotation, scale, and anchor translation). That point is the target `T`.

**Chain.** FABRIK, initialized at `R`, with the base planted:

- Pin `C[0] = R[0]` and `C[1] = R[1]`. The first segment does not rotate, so the stem keeps the angle it leaves the vase at.
- Reach from `C[1]` is `reach = 30 * (L / 31)`. If `|T - C[1]| > reach`, pull `T` onto that circle. If `|T - C[1]| < 1`, keep the rest pose.
- Eight iterations. Backward: set `C[31] = T`, then for `i` from 30 down to 2 place `C[i]` at distance `L/31` from `C[i+1]` toward the previous `C[i]`. Do not move `C[0]` or `C[1]`. Forward: leave `C[0]` and `C[1]` pinned, then for `i` from 1 to 30 place `C[i+1]` at distance `L/31` from `C[i]` toward the backward position.
- The forward pass leaves every segment at the rest length. The tip is as close to the finger as the pin allows. The handle is drawn at `C[31]`, so it never leaves the art or stretches it.

Starting from the rest polyline means a stem that was authored already curved stays that curve until the finger moves it, and a target sitting on the rest tip does not move any station.

**Mesh.** Let `half` be the max distance from `R` to an opaque pixel of the stem, plus 1 px, measured along the rest normals. Normals are the tangent rotated 90° clockwise: `(tx, ty) → (-ty, tx)`.

Build a grid, 32 along by 9 across. Vertex `(i, j)` with `d = -half + 2 * half * j / 8`:

- texture point = `R[i] + normal(R, i) * d`, as a UV in the PNG
- drawn point = `C[i] + normal(C, i) * d`, in local pixels

Draw that triangle strip with the stem PNG. UVs that fall outside the image are transparent. Then apply the stem's canvas transform (flip about the anchor, uniform scale, clockwise rotation, translation).

**Stretch.** Arc length stays `L`, so hatch marks and watercolor edges are not smeared along the branch, and the tip will not chase a finger past full reach. The cost is across the branch: on a tight bend the outside of the ribbon travels farther than the centerline and the inside compresses. Art far from the centerline distorts the most. That is why a flower or a berry is a child sprite, not part of the stem PNG. A leaf painted into the stem PNG flexes and takes this stretch. A leaf that is a child stays rigid and swings with the tangent.

Flip is applied at draw time. `bendTip` is stored in unflipped local pixels (`C[31]`), so toggling flip does not rebake the curve.

## Arrangement save format

One file per template, under Application Support, named `<template id>.json`. It is rewritten when a gesture or button commits, including undo, redo, and reset. The undo stack is session-only, as Mac undo is, and is not written.

Format `com.seiandshin.arrangement`, version 1:

```json
{
  "format": "com.seiandshin.arrangement",
  "version": 1,
  "templateID": "camellia-slanted",
  "elements": [
    {
      "id": "7C2A",
      "templateElement": "stem-main",
      "parent": null,
      "z": 2,
      "center": [640, 1180],
      "rotation": 18,
      "scale": 1,
      "flipX": false,
      "bendTip": [150, 40]
    },
    {
      "id": "7C2B",
      "templateElement": "camellia",
      "parent": "7C2A",
      "z": 3
    }
  ]
}
```

`templateID` must match a bundled template. `templateElement` is the template element id; duplicates share one, and therefore one PNG and one centerline. `parent` is an arrangement instance id. `bendTip` is in the stem's unflipped local pixels and is omitted at rest. Children store no pose; it is derived. A missing file means the rest pose. A file that fails to decode is renamed aside and the rest pose is shown.

Template ids and element ids are immutable once a build has shipped. Changing the art means a new template id. Old arrangement files keep resolving.

## PNG export

Export matches the screen, at the template's pixel size, not at the phone's point size and not multiplied by the screen scale.

- Pixel dimensions are `canvas.width` by `canvas.height` from the template (the source `.comp` size).
- 8-bit sRGB, no alpha. Composite the same meshes, in z order, over `#F3EFE6`. *Ma* in the file is that paper.
- Guides are not drawn. The selection chrome and the tip handle are not drawn.
- Write DPI 72, the Mac default when `resolution` is absent. The pixel size is the one that matters.
- The render is the Metal canvas into an offscreen texture of that size, then read back. There is not a second warp implementation for export.

This differs from Mac PNG export on purpose. `ImageExporter` keeps alpha and does not fill a background. A transparent ikebana file would drop the ground the composition was made against. JPEG, quality choices, and a transparent export are out of scope.

Refuse the export if the canvas is under 1 px or over 2048 on a side. Templates already fail export from the Mac above that, so a bundled file will not hit it.

## iOS architecture

SwiftUI for the chrome. A UIKit touch view, hosted in SwiftUI, for the canvas gestures. Metal for drawing.

Metal is the renderer because the bend is a textured triangle strip, and the same strip must be drawn on screen and into the export texture. Public Core Animation does not warp a layer along a curve: `CATransform3D` is affine plus perspective, and the mesh transform used on some Apple platforms is not public iOS API. Building milestone 2 on `CALayer` and replacing it when bend arrives would throw away the canvas. SpriteKit's `SKWarpGeometryGrid` can deform a sprite, but export wants an offscreen buffer at template resolution, and hit-testing alpha would still be custom. Metal is the smaller path that covers both.

What the Mac target can contribute:

- The coordinate conventions: top-left origin, y down, clockwise degrees, flip as a sign with a positive size, sRGB, 8-bit PNG. Copy those rules. Do not compile `LayerTransform.swift` into the iOS app; its limits (sides up to 300,000, non-uniform size, sampling modes) are the document model, and the phone's model is anchor, uniform scale, and bend.
- Nothing from `MetalWarp` or `DistortWarp`. Different problem.
- ImageIO for PNG encode and decode is available on both platforms. The iOS loader is still its own small type: the template manifest is not `ProjectManifest`.
- The natural-brush code, stroke player, and AppKit canvas stay on the Mac. v1's whole point is that the phone does not play `strokes.jsonl`.

Suggested types, all in an iOS app target:

| Type | Role |
| --- | --- |
| `Template` | Decode a bundled `.ikebana`. Load PNGs into Metal textures, tagged sRGB. |
| `Arrangement` | Value type. The JSON above. Pure functions for move, scale, rotate, flip, bend, duplicate, delete. |
| `StemCurve` | Rest resample, FABRIK, normals. No Metal. Unit-test the rest pose (target on the rest tip reproduces `R`) and a target beyond reach (segments stay `L/31` long, first segment pinned). |
| `CanvasView` | `MTKView` plus the gesture table. Samples alpha for taps. |
| `ArrangementStore` | Read and write the autosave. |
| `PNGExport` | Offscreen pass at template size, paper clear color, ImageIO write. |

The Mac exporter is a Mac-side tool in the existing app or a script next to it. It reads a `.comp` with the same rules as `ProjectStore` (it does not have to link the iOS types), scans `strokes.jsonl` from byte 0 for `op: element` and `op: guides`, renders each tagged layer, and writes the `.ikebana` folder. Milestone 1 is that tool plus three templates run through it.

Portrait only. One arrangement on screen. No brush, no document browser beyond the template list.

## Milestones

Each milestone is usable on its own. Later ones do not reopen the format except to fill fields the earlier milestone left at rest.

1. **Mac export, three templates.** `element` lines in three real `.comp` projects. Exporter writes `.ikebana` packages: trimmed PNGs, parent links, anchors, z-order, stem centerlines. It does not read Mac alignment guides. A `guides` line in `strokes.jsonl` is written onto the template. With no such line, a `guides` object already on the template is kept, and a template that has neither gets the vessel mouth and the tallest stem. A template that violates the authoring rules fails with a specific message. iOS is not required to draw yet. Convert three arrangements that already look right on the Mac canvas. The checked-in sample is `examples/SeiShinSample.comp`. A real arrangement is converted on a Mac that has its stroke script: the script appends the `element` lines and, when the rays are known, a `guides` line. The exporter does not infer centerlines.
2. **Canvas: select, move, scale, rotate, flip.** Bundled templates drawn with Metal as affine sprites (bend identity). Hit testing, the gesture table except the tip handle, children following a rigid stem. Paper background. Portrait iPhone.
3. **Bend.** Tip handle, FABRIK, mesh warp, children riding `attach`. Rest pose stays the PNG. The stretch behavior above is what "done" means: length held, flower not smeared.
4. **Duplicate, delete, undo, redo, reset.** Session undo stack. Children duplicate and delete with the stem.
5. **Autosave and PNG export.** Write the arrangement on commit. Relaunch restores it. Share sheet PNG at template pixel size over paper, guides omitted.
6. **Guides.** Draw the template's Shin, Soe, and Hikae rays: faint dashes, circle / square / triangle markers, origin drag, mirror toggle. Off by default, remembered on device, not in the PNG and not in the arrangement JSON.

## Open questions and risks

- **Flexing leaves.** A leaf in the stem PNG bends and stretches across the ribbon. A leaf as a child stays rigid. Templates have to pick per leaf. v1 will not grow a second bend on the child.
- **Planted base.** The first centerline segment is pinned, so a drag cannot change the angle at the vase. If a template needs that angle to move, it is a rotate of the whole stem, not a bend. Confirm with the first real template before softening the pin.
- **FABRIK and a crowded target.** Eight iterations from the rest pose is stable when the tip moves a little. A target that crosses the chain can flip a middle segment. Worth a fixture with a strong S-curve before calling milestone 3 done. If it misbehaves, lower the step and add a preference for the rest angles; do not switch to stretching.
- **Handle versus finger.** Past full reach the handle stops on the circle around the end of the pinned segment. The art does not elongate. This will feel like the stem ran out of length, which is the point, and it should be checked on a phone with a long stem near the edge.
- **Outside stretch.** A thick branch or a flower left inside the stem texture will smear on a hard bend. The exporter warning for opaque pixels far from the centerline is the mitigation. It is a warning, not a refusal, so a slightly wide stem still exports.
- **Alpha hit testing.** Correct for *ma*, more work than bounding boxes. If a texture readback shows up in profiles, cache a small alpha mask per element on load. Do not fall back to the bounding box; the box fills the negative space the design is about.
- **Non-uniform art.** Mac layers can be scaled differently in x and y. Baking that into the PNG on export avoids a second scale on the phone. Confirm the three templates do not rely on a live non-uniform box.
- **Template drift.** Autosave keys off template id and element id. Replacing a PNG without changing ids will move saved arrangements relative to the new art. Ship art changes as a new id.
- **Paper versus Mac PNG.** Reviewers comparing an iOS export to `ImageExporter` output will see a filled background and no alpha. That is specified, not a bug.
- **Color.** Author and export in sRGB, and tag the textures sRGB, so the phone does not shift the watercolor into Display P3.
- **Undo after relaunch.** The stack is gone; the autosave remains. Reset is the way back to the template. If that confirm is annoying it can move, but a build without Reset traps the arrangement.
- **VoiceOver and the tip handle.** Not in v1. The handle is a small drag target; a later pass should expose bend as an adjustable value.
- **Z-order.** Duplicate always comes to the front. A stem that should tuck behind the vessel has no control for that after the first duplicate. Left out on purpose; revisit if the three templates cannot be composed without it.
