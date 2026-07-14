#!/usr/bin/env python3
"""Detect drift between Sissy's hardcoded pricing tables and LiteLLM.

Sissy prices tokens from two hand-maintained Swift tables
(`app/SissyServer/Pricing.swift`, `app/SissyServer/OpenAIPricing.swift`), each
looked up exact-first then longest-prefix. When a provider ships a new model or
changes a rate, those tables silently go wrong: an unmatched family bills at
$0, and a new point-release (e.g. `gpt-5.6`) falls onto its base-family row
(`gpt-5`) at the wrong rate. This script is the alarm the code comments have
long promised: it replays Sissy's matcher against every current OpenAI/
Anthropic model LiteLLM knows and reports where the resolved rate diverges.

LiteLLM (`model_prices_and_context_window.json`) is the same source ccusage
uses; costs are per-token, so ×1e6 gives Sissy's per-million-token fields.

Cache-creation caveat: LiteLLM carries a single `cache_creation_input_token_cost`
priced at 1.25× input for every Anthropic model — it has no 1-hour tier. That
value equals Sissy's *5-minute* rate (`cacheCreationPerMTok`), so it is
comparable. Sissy's 1-hour tier (2× input) is derived at cost-time and is
deliberately absent from LiteLLM; this script never compares it.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

LITELLM_URL_TEMPLATE = (
    "https://raw.githubusercontent.com/BerriAI/litellm/{ref}/"
    "model_prices_and_context_window.json"
)
FETCH_TIMEOUT_SECONDS = 30
FETCH_ATTEMPTS = 3
FETCH_BACKOFF_BASE_SECONDS = 1.0
PER_MILLION = 1_000_000

REPO_ROOT = Path(__file__).resolve().parent.parent
ANTHROPIC_TABLE = REPO_ROOT / "app" / "SissyServer" / "Pricing.swift"
OPENAI_TABLE = REPO_ROOT / "app" / "SissyServer" / "OpenAIPricing.swift"

TRACKED_PROVIDERS = {"anthropic", "openai"}
CHAT_MODES = {"chat", "responses"}
EXCLUDE_SUBSTRINGS = (
    "audio",
    "realtime",
    "transcribe",
    "tts",
    "whisper",
    "image",
    "dall-e",
    "embedding",
    "moderation",
    "-search-",
    "computer-use",
    "guard",
    ":",
    "/",
    "ft:",
)

FIELDS = ("input", "output", "cache_read", "cache_creation")
# OpenAI has no cache-write billing channel Sissy consumes: Codex rollouts
# carry no cache-creation token count and `cacheCreationPerMTok` stays 0 by
# convention, so comparing it against LiteLLM only yields false drift.
COMPARE_FIELDS = {
    "anthropic": FIELDS,
    "openai": ("input", "output", "cache_read"),
}
LITELLM_FIELD = {
    "input": "input_cost_per_token",
    "output": "output_cost_per_token",
    "cache_read": "cache_read_input_token_cost",
    "cache_creation": "cache_creation_input_token_cost",
}
SWIFT_FIELD = {
    "input": "inputPerMTok",
    "output": "outputPerMTok",
    "cache_read": "cacheReadPerMTok",
    "cache_creation": "cacheCreationPerMTok",
}


@dataclass(frozen=True)
class Rates:
    input: float
    output: float
    cache_read: float
    cache_creation: float

    def swift_init(self) -> str:
        return (
            f".init(inputPerMTok: {_fmt(self.input)}, "
            f"outputPerMTok: {_fmt(self.output)}, "
            f"cacheReadPerMTok: {_fmt(self.cache_read)}, "
            f"cacheCreationPerMTok: {_fmt(self.cache_creation)})"
        )


@dataclass(frozen=True)
class Finding:
    kind: str
    provider: str
    model: str
    detail: str
    suggestion: str
    relevant: bool


def _fmt(value: float) -> str:
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if text else "0"


SWIFT_ENTRY_RE = re.compile(r'"([A-Za-z0-9.\-]+)"\s*:\s*\.init\(([^)]*)\)', re.DOTALL)
TABLE_ANCHOR = "static let table: [String: ModelPricing] = ["

INGEST_SHAPE = {
    # Claude Code writes `message.model` as `claude-<name>-<ver>` (letter after
    # the dash); LiteLLM's `claude-<major>-<name>` API aliases and retired
    # `claude-3-*` names never appear in the JSONL, so a digit here is noise.
    "anthropic": re.compile(r"claude-[a-z]"),
    # Codex records `turn_context.payload.model` — the gpt-5+ / codex families
    # its CLI runs. Older gpt-4/3.5/4o names and the *-deep-research responses
    # variants are never emitted by Codex sessions.
    "openai": re.compile(r"(gpt-[5-9]|gpt-[1-9][0-9]|codex)"),
}


def is_ingest_shape(provider: str, key: str) -> bool:
    """True when `key` matches a model string Sissy's readers actually emit."""
    if provider == "openai" and "deep-research" in key:
        return False
    return INGEST_SHAPE[provider].match(key) is not None


def table_literal(path: Path, text: str) -> str:
    """Return the source span of the `static let table = [...]` array literal.

    Scoping to the literal keeps a stray `"key": .init(...)` elsewhere in the
    file (e.g. a doc-comment sample) from being parsed as a real pricing row.
    """
    start = text.find(TABLE_ANCHOR)
    if start == -1:
        raise ValueError(f"{path.name}: `static let table` literal not found")
    open_idx = start + len(TABLE_ANCHOR) - 1
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[open_idx : i + 1]
    raise ValueError(f"{path.name}: unterminated `table` literal")


def parse_swift_table(path: Path) -> dict[str, Rates]:
    """Extract every `"model": .init(...)` row from a Sissy pricing table."""
    body = table_literal(path, path.read_text(encoding="utf-8"))
    table: dict[str, Rates] = {}
    for key, init_body in SWIFT_ENTRY_RE.findall(body):
        if key in table:
            raise ValueError(f"{path.name}: duplicate pricing row '{key}'")
        values: dict[str, float] = {}
        for field, swift_name in SWIFT_FIELD.items():
            match = re.search(rf"{swift_name}:\s*([0-9]+(?:\.[0-9]+)?)", init_body)
            if match is None:
                raise ValueError(f"{path.name}: row '{key}' missing {swift_name}")
            values[field] = float(match.group(1))
        table[key] = Rates(**values)
    if not table:
        raise ValueError(f"{path.name}: no pricing rows parsed — format changed?")
    return table


def sissy_resolve(model: str, table: dict[str, Rates]) -> tuple[str, Rates] | None:
    """Mirror Swift's `price(for:)`: exact match, then longest-prefix match."""
    if model in table:
        return model, table[model]
    for key in sorted(table, key=len, reverse=True):
        if model.startswith(key):
            return key, table[key]
    return None


def fetch_url(url: str) -> str:
    """GET `url` with a timeout and bounded exponential backoff + jitter."""
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_SECONDS) as resp:  # noqa: S310
                return resp.read().decode("utf-8")
        except OSError as exc:
            if attempt == FETCH_ATTEMPTS:
                raise OSError(
                    f"fetch failed after {FETCH_ATTEMPTS} attempts ({url}): {exc}"
                ) from exc
            backoff = FETCH_BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
            time.sleep(backoff + random.uniform(0, backoff))
    raise AssertionError("unreachable")


def load_litellm(ref: str, source: Path | None) -> dict[str, dict]:
    if source is not None:
        raw = source.read_text(encoding="utf-8")
    else:
        raw = fetch_url(LITELLM_URL_TEMPLATE.format(ref=ref))
    data = json.loads(raw)
    if not isinstance(data, dict) or len(data) < 100:
        raise ValueError("LiteLLM payload malformed or truncated")
    return data


def is_tracked_chat_model(key: str, entry: dict) -> bool:
    if not isinstance(entry, dict):
        return False
    if entry.get("litellm_provider") not in TRACKED_PROVIDERS:
        return False
    mode = entry.get("mode")
    if mode is not None and mode not in CHAT_MODES:
        return False
    return not any(bad in key for bad in EXCLUDE_SUBSTRINGS)


def litellm_rates(entry: dict) -> dict[str, float | None]:
    rates: dict[str, float | None] = {}
    for field, litellm_name in LITELLM_FIELD.items():
        value = entry.get(litellm_name)
        rates[field] = (
            round(value * PER_MILLION, 6) if isinstance(value, (int, float)) else None
        )
    return rates


def diff_fields(
    provider: str, sissy: Rates, litellm: dict[str, float | None]
) -> list[str]:
    mismatches: list[str] = []
    for field in COMPARE_FIELDS[provider]:
        want = litellm[field]
        if want is None:
            continue
        have = getattr(sissy, field)
        if not math.isclose(have, want, rel_tol=1e-6, abs_tol=1e-9):
            mismatches.append(
                f"{SWIFT_FIELD[field]} have {_fmt(have)} / litellm {_fmt(want)}"
            )
    return mismatches


def audit(
    tables: dict[str, dict[str, Rates]],
    litellm: dict[str, dict],
) -> list[Finding]:
    provider_table = {"anthropic": tables["anthropic"], "openai": tables["openai"]}
    findings: list[Finding] = []
    for key in sorted(litellm):
        entry = litellm[key]
        if not is_tracked_chat_model(key, entry):
            continue
        provider = entry["litellm_provider"]
        rates = litellm_rates(entry)
        if rates["input"] is None or rates["output"] is None:
            continue
        resolved = sissy_resolve(key, provider_table[provider])
        cache_creation = rates["cache_creation"] if provider == "anthropic" else None
        suggested = Rates(
            input=rates["input"],
            output=rates["output"],
            cache_read=rates["cache_read"] or 0.0,
            cache_creation=cache_creation or 0.0,
        )
        relevant = is_ingest_shape(provider, key)
        if resolved is None:
            findings.append(
                Finding(
                    kind="UNPRICED",
                    provider=provider,
                    model=key,
                    detail="no table row matches — Sissy bills this model at $0",
                    suggestion=f'"{key}": {suggested.swift_init()},',
                    relevant=relevant,
                )
            )
            continue
        matched_key, sissy_rates = resolved
        mismatches = diff_fields(provider, sissy_rates, rates)
        if mismatches:
            findings.append(
                Finding(
                    kind="MISPRICED",
                    provider=provider,
                    model=key,
                    detail=f"resolves to row '{matched_key}'; " + "; ".join(mismatches),
                    suggestion=f'"{key}": {suggested.swift_init()},',
                    relevant=relevant,
                )
            )
    return findings


def render(findings: list[Finding]) -> str:
    order = {"UNPRICED": 0, "MISPRICED": 1}
    key = lambda f: (order[f.kind], f.provider, f.model)  # noqa: E731
    relevant = sorted((f for f in findings if f.relevant), key=key)
    other = sorted((f for f in findings if not f.relevant), key=key)

    lines: list[str] = []
    if relevant:
        lines.append(
            f"Pricing drift: {len(relevant)} model(s) Sissy can encounter would misbill."
        )
        lines.append("")
        for f in relevant:
            lines.append(f"[{f.kind}] {f.provider}/{f.model}")
            lines.append(f"    {f.detail}")
            lines.append(f"    add/fix: {f.suggestion}")
            lines.append("")
        lines.append("Paste the suggested row(s) into the matching *.swift table, then")
        lines.append("re-run --self-test. Do NOT copy cache-creation for a 1-hour-tier")
        lines.append("model blindly — see the header note in this script.")
    else:
        lines.append("No pricing drift for any model Sissy's readers can emit.")

    if other:
        lines.append("")
        lines.append(
            f"({len(other)} other LiteLLM model(s) also diverge but are outside Sissy's"
        )
        lines.append(" ingest shapes — informational, does not fail --check:)")
        for f in other:
            lines.append(f"    [{f.kind}] {f.provider}/{f.model} — {f.suggestion}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--ref", default="main", help="LiteLLM git ref to fetch (default: main)"
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Read LiteLLM JSON from a local file instead of the network",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit non-zero when any drift is found (for CI)",
    )
    args = parser.parse_args(argv)

    try:
        litellm = load_litellm(args.ref, args.source)
        tables = {
            "anthropic": parse_swift_table(ANTHROPIC_TABLE),
            "openai": parse_swift_table(OPENAI_TABLE),
        }
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"check_pricing_drift: {exc}", file=sys.stderr)
        return 2

    findings = audit(tables, litellm)
    print(render(findings))
    has_relevant = any(f.relevant for f in findings)
    return 1 if (has_relevant and args.check) else 0


if __name__ == "__main__":
    raise SystemExit(main())
