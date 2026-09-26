# Natural brushes

Compositor can paint with the natural-media brushes from [p5.brush](https://github.com/acamposuribe/p5.brush) (MIT License, Alejandro Campos Uribe). The behavior is ported from that library's stroke, fill, and hatch code. The round brush is unchanged: it still sweeps a continuous tip on the GPU.

Pick a preset from the **Brush** menu in the brush options. **Round** is the existing smooth tip. The others lay down the discs p5.brush stamps.

## How to paint

1. Choose the Brush tool (B).
2. Pick a preset. Size, hardness, opacity, smoothing, and the foreground color still apply.
3. Draw. A tablet's pen pressure drives the stroke. A mouse has no pressure, so a slow drag is firm and a fast one is light. The first and last moments of a stroke taper.
4. **Hardness** at 100% is p5.brush's hard disc with a thin antialiased edge. Lower values feather each dab.
5. **Opacity** caps the whole stroke, the same way it does for the round brush. The preset also has its own ink strength, so charcoal stays lighter than a marker at 100%.
6. **Wiggle** pushes pencil-style dabs off the pointer. 0 stays on the line. It is the live version of p5.brush's flow-field wiggle.
7. Undo names follow the preset: `Charcoal Stroke`, `HB Erase`, and so on.

Clone Stamp, Spot Healing, and Smear keep the round tip.

## Presets

Size is p5.brush's stroke weight, scaled so spacing grows with it. At a given Size, a marker is wider than a pen, and charcoal scatters more than HB. Spray is the exception: Size is the width of the cloud, not a single dot.

The numbers below are the p5.brush presets (`weight`, `scatter`, `sharpness`, `grain`, `opacity`, `spacing`, pressure `min…max`).

| Preset | weight | scatter | sharpness | grain | opacity | spacing | pressure |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Pen | 0.3 | 0.15 | 0.9 | 0.7 | 150 | 0.1 | 1.2…1 |
| Rotring | 0.15 | 0.05 | 0.7 | 0.9 | 210 | 0.1 | 1.3…1 |
| 2B | 0.3 | 0.75 | 0.45 | 0.8 | 180 | 0.1 | 1.1…0.9 |
| HB | 0.3 | 0.6 | 0.3 | 0.7 | 170 | 0.1 | 1.1…0.9 |
| 2H | 0.2 | 0.6 | 0.3 | 0.75 | 120 | 0.1 | 1.1…0.9 |
| Colored Pencil | 0.35 | 0.55 | 0.8 | 0.7 | 75 | 0.1 | 0.95…1.1 |
| Pastel | 0.7 | 5 | 0.91 | 1 | 30 | 0.028 | 1.09…0.93 |
| Crayon | 0.33 | 1.9 | 0.75 | 2 | 159 | 0.07 | 1.1…0.9 |
| Charcoal | 0.35 | 1.5 | 0.68 | 2 | 120 | 0.03 | 1.1…0.95 |
| Spray | 0.2 | 6 | — | 40 | 90 | 0.5 | 0.7…1 |
| Marker | 2 | 0.2 | — | — | 1 | 0.03 | 1.2…0.85 |

Pencil, pastel, crayon, charcoal, and spray opacities are p5.brush's 0–255 scale, divided by 255 when a dab is stamped. The marker's opacity is `1`, then divided by `min(Size, 1.3)`, which is already a fraction of full ink. That fraction is not divided by 255 again: p5.brush's circle routine divides every tip, and doing that to the marker would make it nearly invisible, including the darker heel at each end. Grain above 1 always leaves a dab; below 1 it skips some. Spray's grain is how many specks each step throws.

Dabs inside one stroke are seeded. Redrawing the provisional tail does not shimmer, and it is not added to the finished stroke twice. Overlapping dabs use source-over, which is the blend p5.brush uses (`ONE_MINUS_DST_ALPHA`, `ONE`).

Spectral (Kubelka–Munk) mixing is not used. It assumes opaque white paper. Paint on a transparent layer stays ordinary source-over, so pixels you have not painted stay transparent.

## Watercolor and hatch

Both commands are in the Edit menu and need a selection.

- **Watercolor Fill Selection** grows and redraws the selection outline in translucent layers, then lifts some pigment with erased circles. That is the fill from p5.brush, after Tyler Hobbs' watercolor technique. The wash builds up on screen, then becomes one undo step named `Watercolor Fill`. It is clipped to the selection. Ten layers are drawn rather than p5.brush's twenty, so the fill stays responsive.
- **Hatch Selection** fills the selection with 45° lines in the current natural brush (HB if the tip is still Round). The undo name is like `Charcoal Hatch`. A very large selection stops after about 12,000 dabs so the edit can finish.

## What was adapted for a live brush

p5.brush simulates pressure from the finished length of a stroke. A drag in progress does not know that length, so a tablet uses `NSEvent` pressure mapped into the preset's min/max, and a mouse uses speed plus a short taper at each end.

p5.brush's spacing is an absolute distance unless the whole library is scaled. Here spacing scales with Size, so a large charcoal is not hundreds of dabs per pixel. Spray's Size is the cloud diameter for the same reason: in p5.brush the cloud is `scatter × stroke weight` (often much wider than the weight) while the specks stay tiny.

## License

p5.brush is MIT licensed. The preset values, dab placement, watercolor growth, and hatch scanlines in this app are derived from that project:

```
MIT License

Copyright (c) Alejandro Campos Uribe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Source: https://github.com/acamposuribe/p5.brush — `package.json` declares `"license": "MIT"`. The watercolor steps also follow Tyler Hobbs, [A Generative Approach to Simulating Watercolor Paints](https://tylerxhobbs.com/essays/2017/a-generative-approach-to-simulating-watercolor-paints).
