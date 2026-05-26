#!/usr/bin/env python3
"""Render Sissy mascot menubar templates as flat silhouettes with alpha cutouts.

Generates template-style RGBA images directly: black fill, anti-aliased
alpha. macOS AppKit handles tinting; intermediate alpha values give smooth
edges.

Usage:
  python3 scripts/mascot_render.py \\
      --out app/Sissy/Resources/Assets.xcassets \\
      sleep code think trend glow angry
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw


SIZES = [22, 44, 66]
SS = 8


def _draw_head(d: ImageDraw.ImageDraw, size: int) -> tuple[float, float, float, float]:
    cx, cy = size * 0.40, size * 0.58
    rw, rh = size * 0.27, size * 0.22
    d.ellipse(
        [(cx - rw) * SS, (cy - rh) * SS, (cx + rw) * SS, (cy + rh) * SS],
        fill=255,
    )
    left_ear = [
        ((cx - rw * 0.95) * SS, (cy - rh * 0.35) * SS),
        ((cx - rw * 0.50) * SS, (cy - rh - size * 0.14) * SS),
        ((cx - rw * 0.05) * SS, (cy - rh * 0.55) * SS),
    ]
    right_ear = [
        ((cx + rw * 0.05) * SS, (cy - rh * 0.55) * SS),
        ((cx + rw * 0.50) * SS, (cy - rh - size * 0.14) * SS),
        ((cx + rw * 0.95) * SS, (cy - rh * 0.35) * SS),
    ]
    d.polygon(left_ear, fill=255)
    d.polygon(right_ear, fill=255)
    return cx, cy, rw, rh


def _eyes_closed(d, size, cx, cy, rw, rh):
    eye_y = cy
    t = max(1, int(size * 0.055 * SS))
    d.line(
        [((cx - rw * 0.60) * SS, eye_y * SS), ((cx - rw * 0.15) * SS, eye_y * SS)],
        fill=0,
        width=t,
    )
    d.line(
        [((cx + rw * 0.15) * SS, eye_y * SS), ((cx + rw * 0.60) * SS, eye_y * SS)],
        fill=0,
        width=t,
    )


def _eyes_open(d, size, cx, cy, rw, rh):
    eye_y = cy - rh * 0.05
    r = max(1, int(size * 0.055 * SS))
    cl = (cx - rw * 0.40) * SS
    cr = (cx + rw * 0.40) * SS
    ey = eye_y * SS
    d.ellipse([cl - r, ey - r, cl + r, ey + r], fill=0)
    d.ellipse([cr - r, ey - r, cr + r, ey + r], fill=0)


def _eyes_narrow(d, size, cx, cy, rw, rh):
    t = max(1, int(size * 0.055 * SS))
    dy = size * 0.04
    # Furrowed brows: outer-high, inner-low (slants converging toward nose)
    d.line(
        [
            ((cx - rw * 0.65) * SS, (cy - dy) * SS),
            ((cx - rw * 0.15) * SS, (cy + dy) * SS),
        ],
        fill=0,
        width=t,
    )
    d.line(
        [
            ((cx + rw * 0.15) * SS, (cy + dy) * SS),
            ((cx + rw * 0.65) * SS, (cy - dy) * SS),
        ],
        fill=0,
        width=t,
    )


def _eyes_smile(d, size, cx, cy, rw, rh):
    t = max(1, int(size * 0.055 * SS))
    bbox_l = [
        ((cx - rw * 0.70) * SS, (cy - size * 0.07) * SS),
        ((cx - rw * 0.10) * SS, (cy + size * 0.07) * SS),
    ]
    bbox_r = [
        ((cx + rw * 0.10) * SS, (cy - size * 0.07) * SS),
        ((cx + rw * 0.70) * SS, (cy + size * 0.07) * SS),
    ]
    d.arc(bbox_l, start=180, end=360, fill=0, width=t)
    d.arc(bbox_r, start=180, end=360, fill=0, width=t)


def _draw_z(d, left, top, side):
    thick = max(1.0, side * 0.26)

    def coords(pts):
        return [(p[0] * SS, p[1] * SS) for p in pts]

    d.polygon(
        coords(
            [
                (left, top),
                (left + side, top),
                (left + side, top + thick),
                (left, top + thick),
            ]
        ),
        fill=255,
    )
    d.polygon(
        coords(
            [
                (left, top + side - thick),
                (left + side, top + side - thick),
                (left + side, top + side),
                (left, top + side),
            ]
        ),
        fill=255,
    )
    d.line(
        [
            ((left + side) * SS, (top + thick) * SS),
            (left * SS, (top + side - thick) * SS),
        ],
        fill=255,
        width=int(thick * SS * 0.9),
    )


def _finalize(mask: Image.Image, size: int) -> Image.Image:
    alpha = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    opx = out.load()
    apx = alpha.load()
    for y in range(size):
        for x in range(size):
            opx[x, y] = (0, 0, 0, apx[x, y])
    return out


def render_sleep(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_closed(d, size, cx, cy, rw, rh)
    _draw_z(d, size * 0.78, size * 0.04, size * 0.18)
    _draw_z(d, size * 0.62, size * 0.22, size * 0.11)
    return _finalize(mask, size)


def render_code(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_open(d, size, cx, cy, rw, rh)
    # "< >" angle brackets upper-right
    t = max(1, int(size * 0.06 * SS))
    cy_b = size * 0.18
    half_h = size * 0.07
    half_w = size * 0.06
    # left chevron <, pointing inward (tip on right)
    lx_tip = size * 0.70
    d.line(
        [
            ((lx_tip + half_w) * SS, (cy_b - half_h) * SS),
            (lx_tip * SS, cy_b * SS),
            ((lx_tip + half_w) * SS, (cy_b + half_h) * SS),
        ],
        fill=255,
        width=t,
        joint="curve",
    )
    # right chevron >, pointing inward (tip on left)
    rx_tip = size * 0.94
    d.line(
        [
            ((rx_tip - half_w) * SS, (cy_b - half_h) * SS),
            (rx_tip * SS, cy_b * SS),
            ((rx_tip - half_w) * SS, (cy_b + half_h) * SS),
        ],
        fill=255,
        width=t,
        joint="curve",
    )
    return _finalize(mask, size)


def render_think(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_open(d, size, cx, cy, rw, rh)
    # Thought bubble: solid filled circle + small dot tail
    bx, by, br = size * 0.84, size * 0.18, size * 0.12
    d.ellipse(
        [(bx - br) * SS, (by - br) * SS, (bx + br) * SS, (by + br) * SS], fill=255
    )
    dx, dy, dr = size * 0.72, size * 0.34, size * 0.035
    d.ellipse(
        [(dx - dr) * SS, (dy - dr) * SS, (dx + dr) * SS, (dy + dr) * SS], fill=255
    )
    return _finalize(mask, size)


def render_trend(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_open(d, size, cx, cy, rw, rh)
    # Stock-chart uptrend line: three segments rising up-right.
    t = max(1, int(size * 0.07 * SS))
    points = [
        (size * 0.60, size * 0.36),
        (size * 0.70, size * 0.26),
        (size * 0.78, size * 0.30),
        (size * 0.94, size * 0.08),
    ]
    for (x1, y1), (x2, y2) in zip(points[:-1], points[1:]):
        d.line([(x1 * SS, y1 * SS), (x2 * SS, y2 * SS)], fill=255, width=t)
    tx, ty = points[-1]
    px, py = points[-2]
    shaft = math.atan2(ty - py, tx - px)
    hl = size * 0.14
    half_spread = math.radians(28)
    a1 = shaft + math.pi - half_spread
    a2 = shaft + math.pi + half_spread
    bx1 = tx + hl * math.cos(a1)
    by1 = ty + hl * math.sin(a1)
    bx2 = tx + hl * math.cos(a2)
    by2 = ty + hl * math.sin(a2)
    d.polygon(
        [(tx * SS, ty * SS), (bx1 * SS, by1 * SS), (bx2 * SS, by2 * SS)],
        fill=255,
    )
    return _finalize(mask, size)


def render_glow(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_smile(d, size, cx, cy, rw, rh)
    # Sun-ray pattern around upper hemisphere, skipping the ±90° ear corridor
    t = max(1, int(size * 0.05 * SS))
    inner = size * 0.40
    outer = size * 0.50
    angles_deg = [-175, -150, -50, -25, 5, 175]
    for deg in angles_deg:
        rad = math.radians(deg)
        x1 = (cx + inner * math.cos(rad)) * SS
        y1 = (cy + inner * math.sin(rad)) * SS
        x2 = (cx + outer * math.cos(rad)) * SS
        y2 = (cy + outer * math.sin(rad)) * SS
        d.line([(x1, y1), (x2, y2)], fill=255, width=t)
    return _finalize(mask, size)


def render_angry(size: int) -> Image.Image:
    s = size * SS
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    cx, cy, rw, rh = _draw_head(d, size)
    _eyes_narrow(d, size, cx, cy, rw, rh)
    # Three radiating tension strokes upper-right (manga anger marks)
    t = max(1, int(size * 0.06 * SS))
    strokes = [
        ((size * 0.58, size * 0.06), (size * 0.62, size * 0.20)),
        ((size * 0.70, size * 0.02), (size * 0.70, size * 0.18)),
        ((size * 0.82, size * 0.06), (size * 0.78, size * 0.20)),
    ]
    for (x1, y1), (x2, y2) in strokes:
        d.line([(x1 * SS, y1 * SS), (x2 * SS, y2 * SS)], fill=255, width=t)
    return _finalize(mask, size)


RENDERERS = {
    "sleep": render_sleep,
    "code": render_code,
    "think": render_think,
    "trend": render_trend,
    "glow": render_glow,
    "angry": render_angry,
}


def write_imageset(name: str, out_root: Path) -> None:
    render = RENDERERS[name]
    imageset = out_root / f"Mascot{name.capitalize()}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, size in zip([1, 2, 3], SIZES):
        path = imageset / f"mascot-{name}@{scale}x.png"
        render(size).save(path)
        images.append(
            {"idiom": "universal", "filename": path.name, "scale": f"{scale}x"}
        )
    (imageset / "Contents.json").write_text(
        json.dumps(
            {
                "images": images,
                "info": {"author": "sissy", "version": 1},
                "properties": {"template-rendering-intent": "template"},
            },
            indent=2,
        )
    )
    print(f"wrote {imageset.name}/")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, required=True, help="Path to Assets.xcassets")
    p.add_argument("states", nargs="+", help=f"one of {sorted(RENDERERS)} or 'all'")
    args = p.parse_args()
    if not args.out.is_dir():
        print(f"out must be a directory: {args.out}", file=sys.stderr)
        return 1
    states = sorted(RENDERERS) if args.states == ["all"] else args.states
    for s in states:
        if s not in RENDERERS:
            print(f"unknown state: {s}", file=sys.stderr)
            return 1
        write_imageset(s, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
