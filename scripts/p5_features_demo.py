#!/usr/bin/env python3
"""Append a p5.brush 2.2.3 feature demo to a Compositor project's stroke script.

The open app plays the new lines through its brush. The manifest is not touched.
The script draws pressure presets, a watercolor wash that can bleed past its
polygon, a flow field, a continuous gradient hatch, and spline and circle shapes.

Usage:
    python3 scripts/p5_features_demo.py ~/Desktop/demo.comp
"""

import json
import os
import sys


def canvas_size(package):
    path = os.path.join(package, "manifest.json")
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        return float(manifest["width"]), float(manifest["height"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return 1200.0, 800.0


def line(op):
    return json.dumps(op, separators=(",", ":"))


def pt(x, y, pressure=None):
    if pressure is None:
        return [round(x, 2), round(y, 2)]
    return [round(x, 2), round(y, 2), pressure]


def demo(width, height):
    # Keep the marks inside a margin so a small canvas still shows the bleed.
    margin = max(24.0, min(width, height) * 0.06)
    span = min(width, height) - margin * 2
    left = margin
    top = margin
    mid_y = top + span * 0.22
    layer = "p5 demo"
    wash = [
        pt(left, top + span * 0.42),
        pt(left + span * 0.34, top + span * 0.40),
        pt(left + span * 0.36, top + span * 0.72),
        pt(left + span * 0.04, top + span * 0.70),
    ]
    hatch_box = [
        pt(left + span * 0.42, top + span * 0.42),
        pt(left + span * 0.78, top + span * 0.44),
        pt(left + span * 0.76, top + span * 0.74),
        pt(left + span * 0.44, top + span * 0.72),
    ]
    return [
        {"op": "layer", "name": layer},
        # Pen, crayon, and marker: known-length strokes so the pressure envelope shows.
        {"op": "brush", "preset": "Pen", "diameter": max(8, span * 0.018), "color": [0.12, 0.14, 0.18], "opacity": 1, "hardness": 1, "layer": layer},
        {"op": "stroke", "layer": layer, "seed": 41, "points": [
            pt(left, mid_y, 0.35),
            pt(left + span * 0.28, mid_y - span * 0.02, 1),
            pt(left + span * 0.55, mid_y + span * 0.015, 0.9),
        ]},
        {"op": "brush", "preset": "Crayon", "diameter": max(14, span * 0.03), "color": [0.75, 0.28, 0.18], "opacity": 0.9, "hardness": 0.8},
        {"op": "stroke", "layer": layer, "seed": 42, "points": [
            pt(left, mid_y + span * 0.08, 1),
            pt(left + span * 0.5, mid_y + span * 0.1, 1),
        ]},
        {"op": "brush", "preset": "Marker", "diameter": max(16, span * 0.028), "color": [0.15, 0.35, 0.72], "opacity": 0.85, "hardness": 1},
        {"op": "stroke", "layer": layer, "seed": 43, "points": [
            pt(left, mid_y + span * 0.16, 0.4),
            pt(left + span * 0.22, mid_y + span * 0.15, 1),
            pt(left + span * 0.48, mid_y + span * 0.18, 0.55),
        ]},
        # Outward bleed is not clipped, so the darker rim can leave the polygon.
        {"op": "watercolor", "layer": layer, "polygon": wash, "color": [0.25, 0.48, 0.78], "seed": 44,
         "bleed": 0.1, "texture": 0.85, "border": 0.55, "opacity": 150, "direction": "out", "scatter": True, "clip": False},
        {"op": "field", "name": "waves", "wiggle": 1, "seed": 3},
        {"op": "brush", "preset": "2B", "diameter": max(6, span * 0.012), "color": [0.1, 0.1, 0.12], "opacity": 1, "hardness": 1},
        {"op": "flowLine", "layer": layer, "x": left + span * 0.42, "y": top + span * 0.12, "length": span * 0.32,
         "direction": 0, "pressure": 1, "seed": 45, "pace": "fast"},
        {"op": "hatch", "layer": layer, "polygon": hatch_box, "angle": 32, "spacing": max(6, span * 0.018), "seed": 46,
         "rand": 0, "continuous": True, "gradient": 0.6, "brush": "HB", "diameter": max(4, span * 0.01)},
        {"op": "brush", "preset": "Pen", "diameter": max(5, span * 0.01), "color": [0.2, 0.16, 0.12], "opacity": 1, "hardness": 1},
        {"op": "spline", "layer": layer, "curvature": 0.55, "seed": 47, "points": [
            pt(left + span * 0.08, top + span * 0.82),
            pt(left + span * 0.22, top + span * 0.78, 0.8),
            pt(left + span * 0.34, top + span * 0.9),
        ]},
        {"op": "circle", "layer": layer, "x": left + span * 0.62, "y": top + span * 0.86, "radius": max(18, span * 0.06),
         "r": 0.25, "seed": 48,
         "fill": {"color": [0.85, 0.55, 0.25], "opacity": 150, "bleed": 0.08, "direction": "out", "clip": False},
         "hatch": {"angle": 30, "spacing": max(5, span * 0.014), "continuous": True, "gradient": 0.35, "brush": "2H"}},
        {"op": "field", "name": "none"},
    ]


def append(package, ops):
    path = os.path.join(package, "strokes.jsonl")
    prefix = ""
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as handle:
            handle.seek(-1, os.SEEK_END)
            if handle.read(1) != b"\n":
                prefix = "\n"
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(prefix)
        for op in ops:
            handle.write(line(op))
            handle.write("\n")


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/p5_features_demo.py Project.comp", file=sys.stderr)
        return 1
    package = os.path.abspath(sys.argv[1])
    if not os.path.isdir(package) or not os.path.exists(os.path.join(package, "manifest.json")):
        print(f"Not a Compositor project: {package}", file=sys.stderr)
        return 1
    width, height = canvas_size(package)
    append(package, demo(width, height))
    print(f"Appended the p5.brush feature demo to {os.path.join(package, 'strokes.jsonl')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
