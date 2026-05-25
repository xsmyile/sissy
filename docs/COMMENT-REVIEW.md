# Comment Review — 2026-05-25

First-pass review of comments across `app/`, `firmware/`, `scripts/`. Goal: trim
redundancy/staleness/drift, surface bugs found while reading. Comments are not
nuked wholesale — only ones that mislead, lie, or rot.

Codex thread for context: `019e5fa0-f9e1-7710-a0c2-6d7fdaa923d4`.

## Bugs (fix first)

| # | Location | Severity | Status | Problem |
|---|----------|----------|--------|---------|
| 1 | `app/SissyServer/Auth.swift:17` | Low | DONE | Length mismatch returns early — leaks `expected.count` via timing. |
| 2 | `app/SissyServer/ServerConfig.swift:67` | Medium | DONE | Partial-config merge drops `stateThresholds` and `pricingOverride`. |
| 3 | `app/SissyServer/ClaudeCodeUsageReader.swift:617` | Medium | DONE | Byte prefilter requires exact `"type":"assistant"`; whitespace-tolerant JSON skipped. |
| 4 | `app/Sissy/Notifications/MascotNotifier.swift:83` | Medium | DONE | Milestone dedupe key is the raw string; same `cost:<D>` on a later day is suppressed. |
| 5 | `app/Sissy/Models/StateDescriptor.swift:125` | Low | DONE | Cost catchphrase says "$X of tokens" — wrong unit, should be spend/cost. |

## Comment findings (33)

Tags: REDUNDANT / MISLEADING / STALE / VERBOSE / WHY-MISSING / WRONG-DOC / COMMENTED-CODE.

### app/Sissy/

- `Models/Preferences.swift:68` — WRONG-DOC: describes decoder but attaches to defaulted init. Fix: move above `init(from:)`.
- `Models/SissyModel.swift:435` — MISLEADING: `devicePresent` no longer drives companion-voice header. Fix: say it gates device-specific UI.
- `Notifications/MascotNotifier.swift:6` — MISLEADING: class also shows milestone pop-ups. Fix: mention mood-change and milestone pop-ups.
- `Notifications/MascotNotifier.swift:11` — VERBOSE: long NSPopover justification. Fix: collapse to one sentence.
- `Notifications/MascotNotifier.swift:73` — MISLEADING: `compactMap` drops nil frames before dedupe. Fix: dedupe by crossing instance/day or rewrite after code fix.
- `Notifications/MascotNotifier.swift:175` — STALE: example still "150M tokens". Fix: use cost example.
- `Pairing/Provisioner.swift:89` — MISLEADING: `speed` already used by `cfsetspeed`. Fix: delete no-op comment.
- `Server/ServerHealthMonitor.swift:124` — STALE: "phase C" jargon. Fix: say "older daemon without providers map".
- `Server/WebSocketClient.swift:117` — STALE: references removed `test_sprite` flash. Fix: "Pin until cleared; nil resumes computed state."
- `Server/WebSocketClient.swift:238` — MISLEADING: notifier doesn't see nil→value after `compactMap`. Fix: clarify field present only on crossing frames.

### app/SissyServer/

- `Auth.swift:4` — MISLEADING: length mismatch exits early, not fully constant-time. Fix: rewrite after Bug #1.
- `ClaudeCodeUsageReader.swift:32` — MISLEADING: Claude uses legacy `usage-state.json`, not `usage-state-claude-code.json`. Fix: mention persistence URL is injected.
- `ClaudeCodeUsageReader.swift:248` — MISLEADING: save errors not logged at site. Fix: "Best-effort; save errors are swallowed."
- `ClaudeCodeUsageReader.swift:267` — STALE: "1s polling loop" is old; safety poll defaults to 60s. Fix: say FSEvents primary.
- `ClaudeCodeUsageReader.swift:650` — STALE: "earlier in this commit" is commit-local archaeology. Fix: "Cold rescan cheap; avoid partial reconciliation."
- `CodexUsageReader.swift:506` — MISLEADING: no one-byte discriminator. Fix: "Try token_count first, then turn_context."
- `CodexUsageReader.swift:613` — STALE: dead-code block + comment. Fix: delete.
- `SelfTest.swift:325` — MISLEADING: slow path doesn't catch non-compact assistant lines gated out by prefilter. Fix: say skipped or fix after Bug #3.
- `SelfTest.swift:824` — MISLEADING: comment says `gpt-5`; fixture uses `o3`. Fix: change to `o3`.
- `SissyServer.swift:29` — STALE: "running 1s poll" old cadence. Fix: "running poll/cold scan".
- `SissyServer.swift:475` — MISLEADING: `$25.99 -> $25.00` wording backwards. Fix: "Truncate so $24.99 stays 24 and $25.00 enters bucket."
- `UsageProvider.swift:13` — MISLEADING: provider id not always persistence-file suffix. Fix: "Used in /stats and provider-specific persistence where applicable."
- `UsageStatePersistence.swift:4` — MISLEADING: Claude uses legacy unqualified path. Fix: mention exception.
- `UsageStatePersistence.swift:73` — STALE: `forProvider("claude-code")` migration not current. Fix: delete or note legacy Claude path.
- `UsageStatePersistence.swift:82` — MISLEADING: hashes Codex dirs too. Fix: "Hash provider data dir; field name is legacy."
- `WebSocketSinkHandler.swift:5` — MISLEADING: claims no unchecked escape hatch, but nested `State` is `@unchecked Sendable`. Fix: mention locked `State`.
- `WebSocketSinkHandler.swift:94` — MISLEADING: `lastInboundAt` also initialized in `handlerAdded`. Fix: include that.

### firmware/

- `display/SSD1306Display.cpp:14` — WHY-MISSING: `MS_OFFLINE` silently aliases `sleeping`. Fix: one-line rationale.
- `main.cpp:1` — MISLEADING: "WebSocket pull" contradicts push behavior. Fix: "WiFi + WebSocket client".
- `main.cpp:6` — STALE: "future flashes" already shipped. Fix: "wireless flashes".
- `net/SerialProvisioning.h:7` — MISLEADING: banner says `Sissy`, firmware prints `SISSY`. Fix: update literal.
- `net/WifiBootstrap.h:13` — MISLEADING: portal can timeout/reboot. Fix: say returns after WiFi connects, otherwise reboots.

### scripts/

- `mascot_render.py:4` — STALE: references removed `mascot_to_menubar.py`. Fix: "Generates template RGBA mascot assets directly."

## Summary

- Categories: MISLEADING 20, STALE 10, WRONG-DOC 1, VERBOSE 1, WHY-MISSING 1.
- Bugs: Medium 3, Low 2.
- Hotspots: `MascotNotifier.swift`, `ClaudeCodeUsageReader.swift`.

## Bug-fix log

### #1 — Auth.swift constant-time leak (DONE)
- `constantTimeEquals` now walks `expected.count` bytes regardless of input
  length; mismatch contributes to `diff` instead of returning early.
- Comment at `Auth.swift:4` rewritten to drop the misleading "constant-time"
  claim about the public function and point the reader at the inner helper.

### #2 — ServerConfig partial-merge (DONE)
- `mergeWithDefaults` now decodes `stateThresholds` and `pricingOverride` from
  the raw JSON object via a nested `JSONDecoder.decode` round-trip, so a
  hand-edited `server.json` that fails strict decoding still preserves those
  keys instead of silently reverting to defaults.

### #3 — Claude prefilter whitespace tolerance (DONE)
- Replaced compact `"type":"assistant"` marker with a two-pattern scan: find
  `"type"`, skip JSON whitespace + `:` + whitespace, then check `"assistant"`.
- Self-test `marker absent with space` was asserting the bug; flipped to
  `marker present with space` plus tab/padded-key cases and a `"user"`
  negative case.

### #4 — Milestone dedupe day-aware (DONE)
- Dedupe key changed from `milestone` to `(milestone, frame.ts)`. Daemon
  emits a single crossing frame with a unique `ts`, so the same `cost:<D>`
  bucket crossed on a later day now fires; daemon replays of the same
  crossing still collapse.

### #5 — Cost catchphrase wording (DONE)
- `"${X} of tokens, zero regrets"` → `"${X} of vibes, zero regrets"`. Cost
  milestone template no longer references tokens.

### Verification
- `xcodebuild` — both `Sissy` and `sissy-serverd` schemes build clean.
- `sissy-serverd --self-test` — ALL PASS (incl. new prefilter cases).
- `xcodebuild test -scheme Sissy` — pass.
- `pio run -e esp32dev` — firmware build clean after comment edits.

## Comment cleanup log

All 33 findings landed. Notable adjustments where verification changed the
codex suggestion:

- `Preferences.swift:68` — comment didn't get a one-line replacement; moved
  the existing 3-line docstring above `init(from:)` where it actually
  describes the code.
- `Provisioner.swift:89` — codex suggested "delete no-op/comment"; verified
  that `cfsetspeed(&tio, speed)` already consumes `speed`, so the
  `_ = speed` line is dead and was removed too (not just the comment).
- `MascotNotifier.swift:73` — comment was rewritten as part of bug #4
  (dedupe key) so the rewrite reflects the new `(milestone, ts)` key
  instead of the old string-only key.
- `MascotNotifier.swift:6/11` — folded the two findings into a single
  rewritten class doc rather than editing each in place; net result is one
  paragraph covering both mood and milestone flows.
- `CodexUsageReader.swift:613` — deleted the `if … contains(where: { _ in
  false }) == false { /* no-op */ }` block, not just the comment.
- `SelfTest.swift:325` — finding was paired with bug #3; the negative
  assertion that documented the bug was replaced by positive cases proving
  the whitespace-tolerant prefilter.
- `SSD1306Display.cpp:14` — codex flagged WHY-MISSING; added a 4-line note
  covering both the MS_OFFLINE alias and the enum-ordering coupling, since
  the array contract is the part future readers will need to preserve.
- `UsageStatePersistence.swift:4` — instead of one-line fix, reworked the
  top doc to spell out Claude's legacy path exception once so the
  per-method docs underneath can stay short.

No finding was rejected — each held up under direct inspection.

