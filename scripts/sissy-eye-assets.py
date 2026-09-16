#!/usr/bin/env python3
"""Split Sissy's silhouettes into an eye and the rest of the cat.

Every Sissy asset is a single ``<path>`` whose final subpath is the eye — an
almond of ink sitting inside the transparent muzzle, and the only feature that
moves across the 24 blink frames. The menu bar tints that subpath on its own
while the Mac is being held awake, which needs it as an asset of its own.

Both halves are emitted, and the eyeless one is not optional: the coloured eye
is drawn as a second image over the first, so a body that kept its own eye ink
would show through the blue's antialiased edge as a fringe — about a third of
the eye at the ~5×3 device pixels the menu bar draws it in.

Neither half is re-traced: the source file's ``viewBox`` and its whole ``<g>``
transform chain come back unchanged, so the two register pixel-for-pixel.
Re-run this whenever the silhouettes are re-rendered:

    scripts/sissy-eye-assets.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CATALOGUE = Path(__file__).resolve().parent.parent / "app/Sissy/Resources/Assets.xcassets"
BODY_IMAGESETS = [
    "SissyMenuBarTemplate.imageset",
    "SissyMenuBarSleepingTemplate.imageset",
    *(f"SissyMotion/SissyMotionBlink{index:03d}.imageset" for index in range(24)),
]
EYE_SUFFIX = "Eye"
EYELESS_SUFFIX = "Eyeless"
SUBPATH_COUNT = 5
IMAGESET_PROPERTIES = {
    "preserves-vector-representation": True,
    "template-rendering-intent": "template",
}


class DeriveError(RuntimeError):
    """A source silhouette is not the shape this script knows how to split."""


def split_at_eye(path_data: str) -> tuple[str, str]:
    starts = [match.start() for match in re.finditer(r"[Mm]", path_data)]
    if len(starts) != SUBPATH_COUNT:
        raise DeriveError(f"expected {SUBPATH_COUNT} subpaths, found {len(starts)}")
    eye = path_data[starts[-1] :]
    if not eye.startswith("M"):
        raise DeriveError("the eye subpath is relative; it cannot be lifted out on its own")
    return path_data[: starts[-1]], eye


def derive(source: Path, keep: str) -> str:
    svg = source.read_text(encoding="utf-8")
    paths = re.findall(r'\sd="([^"]+)"', svg)
    if len(paths) != 1:
        raise DeriveError(f"expected one <path>, found {len(paths)}")
    opening = re.match(r"(<svg[^>]*>)", svg)
    if opening is None:
        raise DeriveError("no <svg> element")
    groups = re.findall(r"<g[^>]*[^/]>", svg)
    if len(groups) != len(re.findall(r"<g[\s>]", svg)):
        raise DeriveError("a <g> is self-closing; the transform chain cannot be rebuilt")
    if len(groups) != svg.count("</g>"):
        raise DeriveError(
            f"{len(groups)} <g> opened against {svg.count('</g>')} closed; "
            "the path is not wrapped in one chain"
        )
    eyeless, eye = split_at_eye(paths[0])
    return (
        opening.group(1)
        + "".join(groups)
        + f'<path fill="#000000" d="{eye if keep == EYE_SUFFIX else eyeless}"/>'
        + "</g>" * len(groups)
        + "</svg>"
    )


def write_imageset(body: Path, target: Path, keep: str) -> None:
    name = target.name.removesuffix(".imageset")
    target.mkdir(parents=True, exist_ok=True)
    (target / f"{name}.svg").write_text(derive(body, keep), encoding="utf-8")
    contents = {
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": IMAGESET_PROPERTIES,
    }
    (target / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    for relative in BODY_IMAGESETS:
        imageset = CATALOGUE / relative
        name = imageset.name.removesuffix(".imageset")
        body = imageset / f"{name}.svg"
        if not body.is_file():
            print(f"missing silhouette: {body}", file=sys.stderr)
            return 1
        for suffix in (EYE_SUFFIX, EYELESS_SUFFIX):
            target = imageset.with_name(f"{name}{suffix}.imageset")
            try:
                write_imageset(body, target, suffix)
            except DeriveError as error:
                print(f"{body}: {error}", file=sys.stderr)
                return 1
            print(f"{relative} -> {target.relative_to(CATALOGUE)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
