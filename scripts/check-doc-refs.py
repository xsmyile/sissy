#!/usr/bin/env python3
"""Fails when a docstring names a Swift symbol the source no longer declares.

A docstring's numbers are self-contained and a wrong one is visible; a symbol
name is a coupling to another part of the tree, and when that part is renamed
or deleted nothing on the page says so. This reads every `///` line, takes the
backticked tokens shaped like Swift identifiers, and asks whether the source
still mentions them.

Platform APIs, environment variables and vendor names look identical from here,
so the accepted ones live in `.docref-baseline` and only a token that is in
neither the source nor the baseline is reported. Regenerate the baseline with
`--write-baseline` the way swiftlint's is regenerated.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ROOTS = ("app/Sissy", "app/SissyCore", "app/SissyTests")
BASELINE = REPO / ".docref-baseline"
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_(:)]*)*$")
BACKTICKED = re.compile(r"`([^`]+)`")
MIN_BARE_LENGTH = 4


def is_candidate(token: str) -> bool:
    if not IDENTIFIER.match(token):
        return False
    if "_" in token and token.islower():
        return False
    return not (token.islower() and "." not in token and len(token) < MIN_BARE_LENGTH)


def swift_files() -> list[pathlib.Path]:
    return sorted(f for root in ROOTS for f in (REPO / root).rglob("*.swift"))


def collect(files: list[pathlib.Path]) -> tuple[dict[str, str], str]:
    references: dict[str, str] = {}
    code: list[str] = []
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("///"):
                for token in BACKTICKED.findall(stripped):
                    if is_candidate(token):
                        where = f"{path.relative_to(REPO)}:{number}"
                        references.setdefault(token, where)
            elif not stripped.startswith("//"):
                code.append(line)
    return references, "\n".join(code)


def unresolved(references: dict[str, str], code: str) -> list[str]:
    missing = []
    for token in references:
        head = token.split(".")[0]
        tail = token.split(".")[-1].split("(")[0]
        found = re.search(rf"\b{re.escape(head)}\b", code) and re.search(
            rf"\b{re.escape(tail)}\b", code
        )
        if not found:
            missing.append(token)
    return sorted(missing)


def load_baseline() -> set[str]:
    if not BASELINE.exists():
        return set()
    lines = BASELINE.read_text(encoding="utf-8").splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def main() -> int:
    files = swift_files()
    if not files:
        print(f"no Swift files under {', '.join(ROOTS)} in {REPO}: nothing could be checked")
        return 1

    references, code = collect(files)
    missing = unresolved(references, code)

    if "--write-baseline" in sys.argv:
        header = "# Names a docstring may cite that this source does not declare:\n"
        note = "# platform APIs, environment variables, external files, vendor UI.\n"
        BASELINE.write_text(header + note + "\n".join(missing) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE} with {len(missing)} accepted names")
        return 0

    stale = [token for token in missing if token not in load_baseline()]
    for token in stale:
        print(f"{references[token]}: docstring names `{token}`, which the source does not declare")
    if stale:
        print(
            f"\n{len(stale)} stale docstring reference(s). Update the docstring, or — if the "
            f"name is a platform API, an environment variable or a vendor's own — record it "
            f"with: python3 scripts/check-doc-refs.py --write-baseline"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
