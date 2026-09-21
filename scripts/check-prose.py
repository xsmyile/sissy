#!/usr/bin/env python3
"""Fails when user-facing copy carries an em dash or an en dash.

Product copy reads as short declarative sentences; the aside habit an em
dash invites crept back into the README across seven documentation commits
after commit f1f9e14 cleared it once by hand (see
docs/DECISIONS.md#user-facing-copy-carries-no-em-dash). This mechanizes the
zero state so a later documentation pass cannot silently reproduce it.

Checked by default: the root docs a user reads (README.md, SECURITY.md,
CONTRIBUTING.md, CREDITS.md, CODE_OF_CONDUCT.md, NOTICE) and every Swift
string literal under app/Sissy, app/SissyCore and app/SissyTests. AGENTS.md
and docs/ are design notes, not product copy, and keep their dashes; inside
Swift, a `//`/`///` comment, a bare `"—"`/`"–"` literal (the panel's
no-reading placeholder), a `sissyLog` diagnostic, a `"sissy: ..."` log
literal tested outside a `sissyLog` call and a `CustomStringConvertible`
`description` (a log line by its own convention here, never an
`errorDescription` an alert can show) are exempt for the same reason none
of them is copy a user reads. A markdown fenced code block or inline code
span is exempt because its dash can belong to a command or a file's content
rather than to prose.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MARKDOWN_FILES = (
    "README.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CREDITS.md",
    "CODE_OF_CONDUCT.md",
    "NOTICE",
)
SWIFT_ROOTS = ("app/Sissy", "app/SissyCore", "app/SissyTests")

DASH = re.compile("[—–]")
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
BARE_DASH_LITERAL = re.compile('"[—–]"')
LOG_CALL = re.compile(r"\bsissyLog\(")
LOG_DESCRIPTION = re.compile(r"\bvar\s+description\s*:")
LOG_LITERAL = re.compile(r'"sissy:')


def default_files() -> list[pathlib.Path]:
    """Returns the checked scope when no paths are given on the command line."""
    files = [REPO / name for name in MARKDOWN_FILES if (REPO / name).is_file()]
    for root in SWIFT_ROOTS:
        files.extend(sorted((REPO / root).rglob("*.swift")))
    return files


def display_path(path: pathlib.Path) -> str:
    """Renders a path relative to the repo root when it is under one."""
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def markdown_violations(path: pathlib.Path) -> list[tuple[int, str]]:
    """Finds prose dashes in a markdown or plain-text file.

    A fenced code block is skipped in full and an inline code span is
    stripped from the line before it is checked, since either can hold a
    dash that belongs to a command or a file's content.
    """
    hits: list[tuple[int, str]] = []
    in_fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        masked = INLINE_CODE.sub("", line)
        if DASH.search(masked):
            hits.append((number, line.strip()))
    return hits


def strip_swift_comment(line: str) -> str:
    """Returns a line with a trailing `//` or `///` comment removed.

    Scans for the comment marker outside of a string literal, so a URL's
    `//` inside a quoted string is left alone.
    """
    in_string = False
    escaped = False
    for index, char in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        else:
            if char == '"':
                in_string = True
            elif char == "/" and line[index : index + 2] == "//":
                return line[:index]
    return line


def mark_balanced_region(
    lines: list[str], trigger: re.Pattern[str], open_char: str, close_char: str
) -> set[int]:
    """Returns the line numbers spanned by each region a trigger opens.

    A region starts where `trigger` matches and ends once the running count
    of `open_char` and `close_char` from that point balances back to zero,
    so a multi-line `sissyLog(...)` call or `description` property body is
    marked in full.
    """
    marked: set[int] = set()
    depth = 0
    for number, line in enumerate(lines, 1):
        if depth == 0:
            match = trigger.search(line)
            if not match:
                continue
            segment = line[match.start() :]
        else:
            segment = line
        depth += segment.count(open_char) - segment.count(close_char)
        marked.add(number)
        if depth <= 0:
            depth = 0
    return marked


def swift_violations(path: pathlib.Path) -> list[tuple[int, str]]:
    """Finds prose dashes in a Swift file's string literals.

    A `//`/`///` comment, a bare `"—"`/`"–"` literal, a `sissyLog`
    diagnostic, a `"sissy: ..."` log literal and a `CustomStringConvertible`
    `description` are exempt: none of them is copy a user reads.
    """
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    code_lines = [strip_swift_comment(line) for line in raw_lines]
    exempt = mark_balanced_region(code_lines, LOG_CALL, "(", ")")
    exempt |= mark_balanced_region(code_lines, LOG_DESCRIPTION, "{", "}")
    hits: list[tuple[int, str]] = []
    for number, code in enumerate(code_lines, 1):
        if number in exempt or LOG_LITERAL.search(code):
            continue
        masked = BARE_DASH_LITERAL.sub('""', code)
        if DASH.search(masked):
            hits.append((number, raw_lines[number - 1].strip()))
    return hits


def violations(path: pathlib.Path) -> list[tuple[int, str]]:
    """Dispatches to the markdown or Swift checker by file suffix."""
    if path.suffix == ".swift":
        return swift_violations(path)
    return markdown_violations(path)


def main() -> int:
    paths = [pathlib.Path(arg) for arg in sys.argv[1:]] or default_files()
    failed = False
    for path in paths:
        for number, content in violations(path):
            print(f"{display_path(path)}:{number}: {content}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
