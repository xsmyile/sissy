#!/usr/bin/env python3
"""Convert PNG sprites to monochrome bitmap arrays for Adafruit_GFX drawBitmap().

Strategy:
  1. Open RGBA PNG.
  2. Crop to opaque bounding box (drop empty padding).
  3. Resize to target size, square aspect.
  4. Threshold by alpha + luminance: pixel ON if opaque AND not near-white background.
  5. Emit MSB-first packed bytes, padded to multiple of 8 cols per row.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image


def png_to_mono(path: Path, size: int, alpha_thresh: int = 64, lum_thresh: int = 230) -> list[int]:
    img = Image.open(path).convert("RGBA")
    alpha = img.split()[3]
    bbox = alpha.getbbox()
    if bbox:
        img = img.crop(bbox)

    w, h = img.size
    side = max(w, h)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(img, ((side - w) // 2, (side - h) // 2))
    img = square.resize((size, size), Image.NEAREST)

    pixels = img.load()
    bits: list[int] = []
    for y in range(size):
        for x in range(size):
            r, g, b, a = pixels[x, y]
            lum = (r * 299 + g * 587 + b * 114) // 1000
            on = a >= alpha_thresh and lum < lum_thresh
            bits.append(1 if on else 0)

    bytes_per_row = (size + 7) // 8
    out: list[int] = []
    for y in range(size):
        for bx in range(bytes_per_row):
            byte = 0
            for bit in range(8):
                x = bx * 8 + bit
                if x < size and bits[y * size + x]:
                    byte |= 1 << (7 - bit)
            out.append(byte)
    return out


def emit_c(name: str, size: int, data: list[int]) -> str:
    lines = [f"// {name} {size}x{size} mono bitmap"]
    lines.append(f"static const uint8_t PROGMEM {name}[] = {{")
    per_row = (size + 7) // 8
    for r in range(size):
        chunk = data[r * per_row : (r + 1) * per_row]
        lines.append("  " + ", ".join(f"0x{b:02X}" for b in chunk) + ",")
    lines.append("};")
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--size", type=int, default=48)
    p.add_argument("--out", type=Path, default=Path("firmware/src/sprites_mono.h"))
    p.add_argument("--lum", type=int, default=200, help="luminance threshold; lower = pickier")
    p.add_argument("inputs", nargs="+", help="name=path.png pairs")
    args = p.parse_args()

    blocks: list[str] = []
    names: list[str] = []
    for spec in args.inputs:
        if "=" not in spec:
            print(f"bad spec: {spec}", file=sys.stderr)
            return 1
        name, path = spec.split("=", 1)
        data = png_to_mono(Path(path), args.size, lum_thresh=args.lum)
        blocks.append(emit_c(name, args.size, data))
        names.append(name)

    header = ["#pragma once", "#include <Arduino.h>", "", f"#define SPRITE_W {args.size}", f"#define SPRITE_H {args.size}", ""]
    header.append("\n\n".join(blocks))
    args.out.write_text("\n".join(header) + "\n")
    print(f"wrote {args.out} ({len(names)} sprites)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
