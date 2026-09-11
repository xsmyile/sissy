# Architecture

A native Swift daemon that meters usage, and a menubar app that renders it. They are separate processes so the daemon keeps counting after the app quits.

## Wire protocol

Transport: WebSocket, plain JSON text frames. Path `/ws` on the daemon.

Authentication: HTTP header `Authorization: Bearer <token>` on the WebSocket handshake. Empty `authToken` in `server.json` disables the check (local dev only).

### Server → app

`frame` — emitted whenever any usage provider detects new data; per-provider totals are summed by `UsageAggregator` before broadcast. The daemon also re-sends the last known frame to any newly-connected client, so a reconnecting app renders the real last reading instead of placeholders.

```json
{
  "type": "frame",
  "ts": 1716000000,
  "tokens": "233M",
  "cost": "149",
  "burn": "47K",
  "primary": "233M",
  "primary_label": "TOKENS",
  "providers": [
    {"id": "claude-code", "tokens": 217000000, "cost": "138.42", "plan": "max", "windows": [
      {"minutes": 300, "used_percent": 12, "resets_at": 1789042799},
      {"minutes": 10080, "used_percent": 27, "resets_at": 1789523999}
    ]},
    {"id": "codex",       "tokens":  16000000, "cost":  "10.58", "plan": "plus", "windows": []}
  ],
  "prev_tokens": 191000000,
  "prev_cost": "121.44"
}
```

`providers` carries the raw per-provider token + cost slices (cost as a canonical decimal string so it round-trips lossless through `Decimal(string:)`). The macOS app sums it to derive both the menubar header subtitle and the panel's per-provider rows from a single payload — eliminating drift between the WS-pushed header and what used to be a polled `/stats` breakdown. Stable order: `claude-code`, `codex`, then alphabetical. Always emitted (empty array before any provider has reported).

`providers[].windows` carries that CLI's subscription rate-limit windows, shortest first, each identified by its `minutes` rather than by its position — vendors do not agree on an order, and Codex's own `primary` bucket is not always the session one. `used_percent` is a percentage of the window's allowance and `resets_at` is epoch seconds; a bucket whose reset has passed is dropped before the frame is built. Empty for a provider that publishes no limits — an API-key user, a CLI that has not surfaced a window yet, or Claude Code with the `claudeLimits` setting off — which is what puts the panel row back on its share-of-today bar.

`providers[].plan` is the account's subscription plan as the vendor's own lowercase token — `max`, `team`, `plus` — never a display label: the app words it in `UsageFormat`, so a tier a vendor ships after this release still reaches the panel. Omitted rather than sent as null for a provider that names none, which is what leaves the panel row's badge off.

`providers[].plan_tier` is the limit tier that plan is metered at (`max_5x`), for the one vendor that publishes one, and rides inside `plan`'s presence: alone it names nothing the app could attribute. The app folds it into the badge only when the tier names the plan it decorates — a Max account reads "Max 5x", while a Team seat metered at the same tier keeps "Team" and puts the tier in the row's tooltip, because "Team 5x" is a plan nobody sells.

Claude Code publishes no limit state on disk, so its windows come from `ClaudeLimitsProbe`, which reads the CLI's own OAuth token out of the login keychain and polls the endpoint Claude Code's `/usage` reads. That costs a one-time macOS keychain authorization, so it stays off until the user asks for it in Settings.

`keep_awake` carries `{mode, active}` and is always present, unlike the pairs below: the app draws its control from this key, so an absent one could not be told apart from a daemon that predates the feature. `mode` is where the user left the switch (`off`, `on`) and `active` is whether a power assertion is held right now. The two are separate fields because they come apart — power management can refuse the assertion, and the hold follows the app — and the panel renders them as two properties of one glyph, tint for the mode and fill for the effect, so "switched on and holding nothing" is readable at a glance rather than silent.

The hold is taken when the first client connects and dropped when the last one leaves, so quitting Sissy lets the Mac sleep again. The mode is untouched by that: it is where the user left the switch, it survives in `server.json`, and it is what the hold resumes from on the next connect. `Hub` reports the two edges only — a second client is not a second arrival — and it reports an arrival *before* it replays the last frame, so the reconnecting app renders a control that is already holding rather than flashing one that is not.

`prev_tokens` / `prev_cost` carry yesterday's raw combined totals so the macOS app can render a day-over-day delta without a second data path. Both keys are omitted together until every active provider has produced a `prev` snapshot so the app renders no delta rather than a false 0%.

### Client → server

`hello` — sent immediately on connect. The app uses it to push the selected primary metric and to state whether the Claude Code limit probe should run.

```json
{
  "type": "hello",
  "client": "mac-app",
  "primary_metric": "tokens",
  "claude_limits": false
}
```

`claude_limits` is the app's stored preference, resent on every reconnect, and the daemon persists it to `server.json` — so the setting survives a daemon restart the app was not around for. It also travels on its own as `set_claude_limits` when the user flips the switch mid-session.

`set_keep_awake` — switches the keep-awake mode.

```json
{
  "type": "set_keep_awake",
  "keep_awake_mode": "on"
}
```

Unlike `claude_limits` this is **not** carried on `hello` and has no copy in `preferences.json`. The daemon persists the mode to `server.json` and is the only owner: the app re-asserting it on every reconnect would overwrite a change made while it was closed, and a second copy would be a second thing to keep in step. An unknown mode is ignored by the daemon and read as `off` by the app, so a version mismatch costs one control rather than the frame.

## Daemon modules (`app/SissyServer/`)

| File | Job |
|---|---|
| `main.swift`                    | Entry point, signal handling, `--self-test` / `--scan` / `--scan-provider` / `--config` / `--dump-seed` modes |
| `SelfTest.swift`                | The `--self-test` harness: pure formatter, pricing and wire-shape assertions, run in CI for both targets |
| `SissyServer.swift`             | Actor that owns Hub + `UsageAggregator` and bootstraps the NIO server; auto-detects Codex provider at boot |
| `HTTPRequestHandler.swift`      | `/health`, `/stats` (diagnostic-only: connectedClients, filesWatched, lastFrameAt); Bearer auth; 401/404 paths |
| `HTTPResponses.swift`           | Codable/Sendable wire shapes for `/health` and `/stats`, mirrored by `app/Sissy/Server/HTTPResponses.swift` |
| `WebSocketSinkHandler.swift`    | Per-connection WS handler, conforms to `FrameSink` |
| `Hub.swift`                     | Actor — fan-out to all connected WS clients + last-frame replay |
| `KeepAwake.swift`               | Actor owning the `PreventUserIdleSystemSleep` assertion, plus the `KeepAwakeMode` / `KeepAwakeState` wire types; mode persisted in `server.json`, assertion held only while a client is connected and released on `stop()` |
| `UsageProvider.swift`           | Protocol shared by each CLI log reader (id, start/stop, current, isWarm) |
| `UsageAggregator.swift`         | Sums per-day totals across active providers; emits the combined frame to `Hub` |
| `ClaudeCodeUsageReader.swift`   | Tails `~/.claude/projects/**/*.jsonl`; dedupes by `requestId`; forwards the limit probe's windows; owns `parseTimestamp`, the one timestamp parser every reader and the probe share |
| `ClaudeLimitsProbe.swift`       | Polls Anthropic's OAuth usage endpoint for the 5-hour and weekly windows; 5-min refresh, 30-min backoff on 429; off unless `claudeLimits` is set |
| `ClaudeProfile.swift`           | Reads the plan out of the CLI's own `.claude.json` (`CLAUDE_CONFIG_DIR` or `$HOME`); no keychain, so it answers with `claudeLimits` off |
| `ClaudeCredentials.swift`       | Read-only lookup of Claude Code's keychain OAuth token — never writes it, never refreshes it — bounded so an unanswered authorization dialog cannot park the probe |
| `CodexAuth.swift`               | Reads the `chatgpt_plan_type` claim out of `~/.codex/auth.json`, for the boot before the first turn; touches no other field in it |
| `CodexUsageReader.swift`        | Tails `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`); uses `last_token_usage` as per-turn delta; model from `turn_context.payload.model` (fallback `gpt-5-codex`) |
| `UsageReaderShared.swift`       | Tuning constants both tails share (`ingestChunkSize`, `pollEmitThrottle`, mtime slack) so they cannot drift apart |
| `FSWatcher.swift`               | Wraps `FSEventStreamCreate` (CoreServices); drives per-provider reader wakes |
| `Pricing.swift`                 | Anthropic cost math, `ModelPricing`, `PricingTable`; no rate table of its own |
| `OpenAIPricing.swift`           | OpenAI cost math, same override → catalog → seed precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM rates at runtime; renders the seed for `--dump-seed` |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — offline / first-run floor |
| `FrameBuilder.swift`            | `fmtTokens` / `fmtBurn` / `fmtCost`, `activeSlices`, and the primary-metric pick |
| `Auth.swift`                    | Constant-time bearer compare; an empty token is open mode (dev only) |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`; carries `providers` toggles, `codexDataDir`, `remotePricing`, `claudeLimits` |
| `SissyPaths.swift`              | Support-dir and default-port resolution (`.dev` bundle id → dev tree); a deliberate copy of the app's helper, kept in lockstep |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); Claude reader stays on legacy `usage-state.json` for upgrade smoothness |

The daemon binds first and lets each active provider's initial JSONL backfill finish in detached tasks — clients can connect within ~1 s even on a multi-GB Claude Code or Codex history. Steady-state CPU is near zero: provider-specific `FSEventStream`s (rooted at `~/.claude/projects` for Claude Code and `~/.codex/sessions` for Codex) wake their readers only when JSONL actually changes (kernel-level coalesced events at ~1 s latency). A low-frequency safety-net poll (default 60 s, configurable via `server.json.pollIntervalSeconds`) catches missed-event flags (`MustScanSubDirs`/`UserDropped`/`KernelDropped`) and midnight day rollover when no JSONL activity straddles the boundary. Claude Code entries are deduplicated by `requestId` because Claude Code logs each assistant turn 2-3 times as the message streams; Codex turns are deduplicated implicitly because `last_token_usage` arrives once per turn.

Each provider reader retains a 2-day window on disk (today + yesterday). The daemon only ever surfaces today + yesterday — the latter feeds the panel's day-over-day delta — so the retention window is sized to match. Cold scans skip every file with `mtime < now-48h`, which on real-world trees (~500 MB across hundreds of projects) parses ~10-20% of the bytes and finishes in low seconds. Bumping this requires every consumer of `dailyTotals` to actually use the extra history; today nothing does.

## Lifecycle and login items

The daemon binary lives at `Sissy.app/Contents/MacOS/sissy-serverd`. Its LaunchAgent plist is bundled at `Sissy.app/Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist` and uses `BundleProgram` so it remains app-bundle relative if the app is moved.

The menubar app's `ServerServiceController` uses `SMAppService.agent(plistName:)` to register/unregister the LaunchAgent. Registering starts the daemon and enables it for future logins; unregistering stops it and removes the login item registration. Runtime state in the UI comes from `/health`, not from parsing `launchctl` output. Quitting the menubar app does not stop the daemon, which is the point of the split: the day keeps being counted either way.

There are therefore **two independent login items**, one per half. The daemon's agent carries `RunAtLoad`, so once the Server is on it comes back at login whether or not the app does; the app registers itself separately through `SMAppService.mainApp` (`Models/LoginItemController.swift`, exposed as General → "Start at login", which falls back to a button into System Settings when macOS reports the item needs approval), and that switch only decides whether the menu bar icon returns. Neither state is mirrored in `preferences.json`: `SMAppService` is the record, and a user who removed Sissy in System Settings → Login Items would leave a mirrored flag asserting something the system had already undone.

## Operational notes

- **Pricing**: there is no hand-maintained rate table. Rates resolve `server.json` `pricingOverride` → the LiteLLM catalog fetched at runtime (`PriceCatalog.swift`, refreshed every 24 h, cached in Application Support) → `PricingSeed.swift`, a generated snapshot embedded at build time for the offline / first-run case. A new model therefore needs no Sissy release. The cold backfill runs against exactly one catalog: a cache newer than the seed is applied before the scan starts, otherwise the first fetch is awaited under `PriceCatalogSource.coldStartBudget` and the seed prices the scan if it doesn't land. A refresh never reprices what it already counted, so letting a catalog arrive mid-scan would split a single day across two rate sets. `remotePricing: false` pins the daemon to the seed and stops all outbound requests. Regenerate the seed when cutting a release: `sissy-serverd --dump-seed > app/SissyServer/PricingSeed.swift`. The `pricing-oracle` CI job asserts exact agreement with `ccusage`, which prices from the same LiteLLM data.
- **Binding**: the daemon listens on `127.0.0.1` only. The app is its sole client.
- **Replay**: every WS client gets the last broadcast frame on connect, so a restart doesn't show stale placeholders.
- **Failure modes**:
  - No JSONL files for any active provider (empty `~/.claude/projects` and/or empty `~/.codex/sessions`) → `/health.usageReader = "no-jsonl-found"`, no frames broadcast
  - Daemon unreachable → the app reconnects with equal-jitter backoff capped at 30 s, and the menu bar dims until a frame lands
