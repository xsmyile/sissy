#!/usr/bin/env python3
"""Generate the Hugeicons symbolsets the app draws its glyphs from.

The names are the raw values of ``Glyph`` in ``app/Sissy/Panel/Glyph.swift``,
the one list of them. Each is taken from the free Hugeicons package at the
version pinned below, drawn as a 24-unit stroked SVG, and handed to SwiftDraw,
which expands the strokes into an SF Symbol template. Every symbolset in the
``Glyphs`` folder is written by this script and the folder is emptied first, so
a glyph dropped from the enum leaves no asset behind.

Every glyph has one drawing, so its weight is the stroke below and a
``.font(weight:)`` on it changes nothing. Scaled-stroke masters were tried and
dropped: SwiftDraw's stroker splits a path into different segments at different
widths: measured 2026-10-20, 15 of the 32 glyphs came out with masters that
cannot interpolate already at 0.75x and 1.33x, and each of those drawn to check
rendered blank.

The stroke is Hugeicons' 1.5 thickened to 1.75 and the insets map the middle 18
of the 24 units to the cap height, which is what put the glyphs closest to the
system symbols they replaced at the panel's own sizes, measured 2026-10-20.

Needs ``npm`` and ``swiftdraw`` (``brew install swiftdraw``) on ``PATH``.
Re-run after editing ``Glyph`` and commit what it writes:

    scripts/generate-glyphs.py
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENUM = REPO / "app/Sissy/Panel/Glyph.swift"
FOLDER = REPO / "app/Sissy/Resources/Assets.xcassets/Glyphs"
PACKAGE = "@hugeicons/core-free-icons"
VERSION = "4.3.5"
INSETS = "3,3,3,3"
STROKE_WIDTH = "1.75"
INK = "#000000"
CASE = re.compile(r'^\s*case \w+ = "(\w+)"$', re.MULTILINE)
ELEMENT = re.compile(r'\["(\w+)", \{([^}]*)\}\]')
ATTRIBUTE = re.compile(r'(\w+): "([^"]*)"')
FOLDER_CONTENTS = {"info": {"author": "xcode", "version": 1}}


class GlyphError(RuntimeError):
    """A glyph the enum names cannot be generated."""


def names() -> list[str]:
    found = CASE.findall(ENUM.read_text(encoding="utf-8"))
    if not found:
        raise GlyphError(f"no `case name = \"Name\"` lines in {ENUM}")
    return found


def fetch_package(workdir: Path) -> Path:
    subprocess.run(
        ["npm", "pack", f"{PACKAGE}@{VERSION}", "--pack-destination", str(workdir), "--silent"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    tarball = next(workdir.glob("*.tgz"))
    extracted = workdir / "package-root"
    with tarfile.open(tarball) as archive:
        archive.extractall(extracted, filter="data")
    return extracted / "package/dist/esm"


def kebab(key: str) -> str:
    return re.sub(r"([A-Z])", lambda match: "-" + match.group(1).lower(), key)


def paint(key: str, value: str) -> str:
    if key == "strokeWidth":
        return STROKE_WIDTH
    return INK if value == "currentColor" else value


def svg(source: Path, name: str) -> str:
    module = source / f"{name}Icon.js"
    if not module.exists():
        raise GlyphError(f"{name} is not in {PACKAGE}@{VERSION}; check the name on hugeicons.com")
    elements = []
    for tag, body in ELEMENT.findall(module.read_text(encoding="utf-8")):
        attributes = " ".join(
            f'{kebab(key)}="{paint(key, value)}"'
            for key, value in ATTRIBUTE.findall(body)
            if key != "key"
        )
        elements.append(f"<{tag} {attributes}/>")
    if not elements:
        raise GlyphError(f"{module} holds no drawable elements")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">'
        + "".join(elements)
        + "</svg>"
    )


def symbolset(source: Path, name: str, workdir: Path) -> None:
    drawing = workdir / f"{name}.svg"
    drawing.write_text(svg(source, name), encoding="utf-8")
    target = FOLDER / f"{name}.symbolset"
    target.mkdir()
    subprocess.run(
        [
            "swiftdraw", str(drawing),
            "--format", "sfsymbol",
            "--insets", INSETS,
            "--output", str(target / f"{name}.svg"),
        ],
        check=True,
        capture_output=True,
    )
    if not (target / f"{name}.svg").exists():
        raise GlyphError(f"swiftdraw wrote no template for {name}")
    contents = {"info": FOLDER_CONTENTS["info"], "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}
    (target / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    for tool in ("npm", "swiftdraw"):
        if shutil.which(tool) is None:
            print(f"{tool} is not on PATH; see this script's docstring for how to install it")
            return 1
    try:
        wanted = names()
        if FOLDER.exists():
            shutil.rmtree(FOLDER)
        FOLDER.mkdir()
        (FOLDER / "Contents.json").write_text(json.dumps(FOLDER_CONTENTS, indent=2) + "\n", encoding="utf-8")
        with tempfile.TemporaryDirectory() as scratch:
            workdir = Path(scratch)
            source = fetch_package(workdir)
            for name in wanted:
                symbolset(source, name, workdir)
    except (GlyphError, subprocess.CalledProcessError) as error:
        print(f"glyph generation failed: {error}")
        return 1
    print(f"wrote {len(wanted)} symbolsets to {FOLDER.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
