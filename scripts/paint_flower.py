#!/usr/bin/env python3
"""Append a small flower to a Compositor project's stroke script.

The open app plays the new lines through its brush. The manifest is not touched.

Usage:
    python3 scripts/paint_flower.py ~/Desktop/demo.comp
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


def arc(cx, cy, rx, ry, start, end, steps, pressure):
    from math import cos, pi, sin
    points = []
    for step in range(steps + 1):
        angle = start + (end - start) * step / steps
        points.append([round(cx + cos(angle) * rx, 2), round(cy + sin(angle) * ry, 2), pressure])
    return points


def flower(width, height):
    from math import cos, pi, sin
    cx, cy = width * 0.5, height * 0.46
    stem = max(28.0, min(width, height) * 0.04)
    ops = [
        {"op": "layer", "name": "Flower"},
        {"op": "brush", "preset": "2B", "diameter": stem * 0.55, "color": [0.18, 0.38, 0.16], "opacity": 1, "hardness": 1, "layer": "Flower"},
        {"op": "stroke", "layer": "Flower", "seed": 11, "points": [
            [round(cx, 2), round(cy + stem * 1.2, 2), 0.7],
            [round(cx + stem * 0.15, 2), round(height * 0.78, 2), 0.9],
            [round(cx - stem * 0.05, 2), round(height * 0.92, 2), 0.5],
        ]},
        {"op": "brush", "preset": "Charcoal", "diameter": stem * 0.7, "color": [0.15, 0.42, 0.18], "opacity": 0.9, "hardness": 0.7},
        {"op": "stroke", "layer": "Flower", "seed": 12, "points": [
            [round(cx, 2), round(cy + stem * 2.2, 2), 0.8],
            [round(cx - stem * 1.6, 2), round(cy + stem * 3.1, 2), 0.5],
        ]},
        {"op": "stroke", "layer": "Flower", "seed": 13, "points": [
            [round(cx + stem * 0.2, 2), round(cy + stem * 2.8, 2), 0.8],
            [round(cx + stem * 1.8, 2), round(cy + stem * 3.6, 2), 0.45],
        ]},
        {"op": "brush", "preset": "Pastel", "diameter": stem * 1.35, "color": [0.9, 0.32, 0.48], "opacity": 0.85, "hardness": 0.85, "wiggle": 0.15},
    ]
    for petal in range(5):
        angle = -pi / 2 + petal * 2 * pi / 5
        px = cx + cos(angle) * stem * 1.15
        py = cy + sin(angle) * stem * 0.85
        ops.append({
            "op": "stroke",
            "layer": "Flower",
            "seed": 20 + petal,
            "points": arc(px, py, stem * 0.95, stem * 0.62, angle, angle + pi * 1.6, 18, 0.85),
        })
    ops.append({"op": "brush", "preset": "Spray", "diameter": stem * 1.4, "color": [0.95, 0.78, 0.2], "opacity": 0.9, "hardness": 1, "wiggle": 0})
    ops.append({
        "op": "stroke",
        "layer": "Flower",
        "seed": 30,
        "points": arc(cx, cy, stem * 0.28, stem * 0.22, 0, pi * 2, 10, 1),
    })
    return ops


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
        print("Usage: python3 scripts/paint_flower.py Project.comp", file=sys.stderr)
        return 1
    package = os.path.abspath(sys.argv[1])
    if not os.path.isdir(package) or not os.path.exists(os.path.join(package, "manifest.json")):
        print(f"Not a Compositor project: {package}", file=sys.stderr)
        return 1
    width, height = canvas_size(package)
    append(package, flower(width, height))
    print(f"Appended a flower to {os.path.join(package, 'strokes.jsonl')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
