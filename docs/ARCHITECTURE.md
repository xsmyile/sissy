# Architecture

Two halves: a native Swift daemon on the host machine, and ESP32 firmware that pulls frames from it over WebSocket.

## Wire protocol

Transport: WebSocket, plain JSON text frames. Path `/ws` on the daemon.

Authentication: HTTP header `Authorization: Bearer <token>` on the WebSocket handshake. Empty `authToken` in `server.json` disables the check (local dev only).

### Server → device

`frame` — emitted whenever any usage provider detects new data; per-provider totals are summed by `UsageAggregator` before broadcast. The daemon also re-sends the last known frame to any newly-connected client so the OLED can update on reconnect without waiting for the next change.

```json
{
  "type": "frame",
  "ts": 1716000000,
  "tokens": "233M",
  "cost": "149",
  "burn": "47K",
  "state": "glow",
  "primary": "233M",
  "primary_label": "TOKENS",
  "providers": [
    {"id": "claude-code", "tokens": 217000000, "cost": "138.42"},
    {"id": "codex",       "tokens":  16000000, "cost":  "10.58"}
  ]
}
```

`state` is one of `sleep`, `think`, `code`, `trend`, `glow`, `angry`.
The firmware has an additional local-only `MS_OFFLINE` state it renders when the WS has been disconnected for more than 15 s. The server never sends `offline` over the wire.

`providers` carries the raw per-provider token + cost slices (cost as a canonical decimal string so it round-trips lossless through `Decimal(string:)`). The macOS app sums it to derive both the menubar header subtitle and the "Breakdown" submenu rows from a single payload — eliminating drift between the WS-pushed header and what used to be a polled `/stats` breakdown. Firmware ignores the field; older firmware builds parse the rest of the frame unchanged. Stable order: `claude-code`, `codex`, then alphabetical. Always emitted (empty array before any provider has reported).

### Client → server

`hello` — sent immediately on connect. The macOS app uses it to identify itself, push the selected primary metric, and sync the current milestone preset.

```json
{
  "type": "hello",
  "client": "mac-app",
  "primary_metric": "tokens",
  "milestone_frequency": "normal"
}
```

Reserved for V2: `input` events when the enclosure grows a button.

## Daemon modules (`app/SissyServer/`)

| File | Job |
|---|---|
| `main.swift`                    | Entry point, signal handling, `--self-test` / `--scan` / `--scan-provider` / `--config` / `--dump-seed` modes |
| `SissyServer.swift`             | Actor that owns Hub + `UsageAggregator` and bootstraps the NIO server; auto-detects Codex provider at boot |
| `HTTPRequestHandler.swift`      | `/health`, `/stats` (diagnostic-only: connectedClients, filesWatched, lastFrameAt); Bearer auth; 401/404 paths |
| `WebSocketSinkHandler.swift`    | Per-connection WS handler, conforms to `FrameSink` |
| `Hub.swift`                     | Actor — fan-out to all connected WS clients + last-frame replay |
| `UsageProvider.swift`           | Protocol shared by each CLI log reader (id, start/stop, current, isWarm) |
| `UsageAggregator.swift`         | Sums per-day totals across active providers; emits the combined frame to `Hub` |
| `ClaudeCodeUsageReader.swift`   | Tails `~/.claude/projects/**/*.jsonl`; dedupes by `requestId` |
| `CodexUsageReader.swift`        | Tails `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`); uses `last_token_usage` as per-turn delta |
| `FSWatcher.swift`               | Wraps `FSEventStreamCreate` (CoreServices); drives per-provider reader wakes |
| `Pricing.swift`                 | Anthropic cost math, `ModelPricing`, `PricingTable`; no rate table of its own |
| `OpenAIPricing.swift`           | OpenAI cost math, same override → catalog → seed precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM rates at runtime; renders the seed for `--dump-seed` |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — offline / first-run floor |
| `FrameBuilder.swift`            | Token/cost/burn formatters + state picker |
| `Auth.swift`                    | Constant-time bearer compare |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`; carries `providers` toggles, `codexDataDir`, `remotePricing` |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); Claude reader stays on legacy `usage-state.json` for upgrade smoothness |

The daemon binds first and lets each active provider's initial JSONL backfill finish in detached tasks — clients can connect within ~1 s even on a multi-GB Claude Code or Codex history. Steady-state CPU is near zero: provider-specific `FSEventStream`s (rooted at `~/.claude/projects` for Claude Code and `~/.codex/sessions` for Codex) wake their readers only when JSONL actually changes (kernel-level coalesced events at ~1 s latency). A low-frequency safety-net poll (default 60 s, configurable via `server.json.pollIntervalSeconds`) catches missed-event flags (`MustScanSubDirs`/`UserDropped`/`KernelDropped`) and midnight day rollover when no JSONL activity straddles the boundary. Claude Code entries are deduplicated by `requestId` because Claude Code logs each assistant turn 2-3 times as the message streams; Codex turns are deduplicated implicitly because `last_token_usage` arrives once per turn.

Each provider reader retains a 2-day window on disk (today + yesterday). The daemon only ever surfaces today + yesterday — the latter feeds `FrameBuilder.pickState`'s `trend` heuristic — so the retention window is sized to match. Cold scans skip every file with `mtime < now-48h`, which on real-world trees (~500 MB across hundreds of projects) parses ~10-20% of the bytes and finishes in low seconds. Bumping this requires every consumer of `dailyTotals` to actually use the extra history; today nothing does.

## Firmware modules

| File | Job |
|---|---|
| `main.cpp`                          | Boot sequence + render/render loop |
| `display/IDisplay.h`                | Display interface (V2 hardware swaps in here) |
| `display/SSD1306Display.{h,cpp}`    | 128×64 mono OLED implementation |
| `net/Config.{h,cpp}`                | `RuntimeConfig` struct + NVS persistence (`Preferences`) |
| `net/SerialProvisioning.{h,cpp}`    | USB serial `CFG:` config receiver used by Pair Device |
| `net/WifiBootstrap.{h,cpp}`         | Saved-credential connect path, WiFiManager portal fallback, auto-reconnect |
| `net/WsClient.{h,cpp}`              | WebSocketsClient bridge, JSON parse → Frame |
| `net/Ota.{h,cpp}`                   | ArduinoOTA wrapper |
| `state/Frame.h`, `StateMachine.cpp` | `MascotState` enum + name ↔ id helpers |
| `sprites_mono.h`                    | Generated by `scripts/png_to_bitmap.py` |

The static C-style `WebSocketsClient` callback in `WsClient.cpp` trampolines through a single global pointer (`gOwner`) into the live instance. This is the same pattern the upstream library uses in its own examples — the alternative (`std::function` capturing `this`) is not supported by `WebSocketsClient::onEvent` on Arduino.

## Boot flow

1. `Serial.begin(115200)` then OLED init. If the OLED fails to come up the firmware halts; there is no point in running headless when the device's only output is a screen.
2. `ConfigStore::begin()` + `WifiBootstrap::connect()` — pulls saved creds from NVS and connects directly when the app has provisioned WiFi/server settings over USB. If config is missing or WiFi fails, firmware raises the non-blocking captive portal AP `Sissy-Setup`, shows pairing instructions on the OLED, and continues polling `SerialProvisioning::tick()` so the app's **Pair Device...** flow can still provision the device without using the browser portal.
3. `Ota::begin(deviceId, otaPassword)` — registers the device on the LAN as `esp-XXXXXX.local` for wireless flashes.
4. `WsClient::begin(cfg, deviceId)` — opens the WebSocket. Bearer header is set from `cfg.authToken`.
5. `loop()` runs `Ota::loop()` + `WsClient::loop()` and renders the last received `Frame` at ~12 fps. If the WS has been down for more than 15 s and at least one frame was received before, the firmware overrides `state` to `MS_OFFLINE` and draws a small "no signal" glyph over the mascot. After 5 min without a fresh frame, the panel additionally dims to `0x10` to spare the OLED phosphor.

## Mascot state machine

Daemon picks `state` from the current cost vs. yesterday's:

| Condition | `state` | Mascot |
|---|---|---|
| `tokens == 0`               | `sleep` | sleeping — day off |
| `cost ≥ $200`               | `angry` | angry-coffee — problem |
| `cost ≥ $100`               | `glow`  | glowing-aura — heavy use |
| `cost ≥ 1.3 × yesterday`    | `trend` | trending-up — escalating |
| `cost ≥ $20`                | `code`  | coding — productive |
| otherwise                   | `think` | thinking — light use |

Thresholds in `server.json.stateThresholds`; logic in `FrameBuilder.pickState`. Renaming a wire `state` value means updating (a) the mascot bitmap order in `SSD1306Display.cpp`, (b) `MascotState` in `firmware/src/state/`, (c) the app mirror in `WebSocketClient.swift`, (d) the picker in `FrameBuilder.swift`. Between frames the firmware briefly flips to `think` every 4 s as an idle breath animation.

## Milestone presets

Milestone notifications (e.g. *"You crossed $25"*) fire on every whole-dollar step the user crosses during the day. Cost is the only axis — tokens were dropped because they aren't comparable across models or agents (1M Opus ≠ 1M Haiku ≠ 1M GPT-5), and `Pricing.swift` already normalizes everything to USD so a cost-only milestone scales to ccusage imports and multi-provider futures without per-model weights. The cadence is user-tunable from the menubar's **Milestone frequency** submenu; the preset key is persisted in `server.json.milestoneFrequency` and the bucket counter lives in `~/Library/Application Support/Sissy/milestones.json` next to the usage snapshot.

| Preset key       | Cost step |
|------------------|-----------|
| `very_frequent`  | $5        |
| `frequent`       | $10       |
| `normal` (def.)  | $25       |
| `sparse`         | $50       |
| `rare`           | $100      |

Source of truth: `MilestoneFrequency.presets` in `app/SissyServer/SissyServer.swift`. The app mirrors the values in `Preferences.MilestoneFrequency` (label + detail strings); a value mismatch between the two enums silently degrades to the `normal` defaults at lookup time.

Bucket semantics:
- `costBucket` = highest whole-dollar step crossed so far today. Persisted across restarts so a daemon bounce doesn't replay notifications.
- `presetKey` recorded alongside the bucket so a preset change is detected at load time → silent reseed (treat as midnight rollover): `bucket = today / new_step`, no fire. Same semantics for a runtime change via `set_milestone_frequency`.
- Defensive snap-down: if the persisted bucket exceeds what today's totals imply (e.g. snapshot invalidation recomputes today smaller), `check()` ratchets the bucket down silently so future genuine crossings still fire instead of being swallowed.
- Legacy snapshots (pre-cost-only) decode cleanly: the stale `tokenBucket` field is ignored via `decodeIfPresent`; `costBucket`, `dayKey`, and `presetKey` carry through unchanged.

Wire control:

| Direction          | Payload                                                                 | Effect |
|--------------------|--------------------------------------------------------------------------|--------|
| App → daemon       | `{"type":"hello","client":"mac-app","milestone_frequency":"frequent"}` | Apply at connect. Same payload also carries `primary_metric`. |
| App → daemon       | `{"type":"set_milestone_frequency","value":"sparse"}`                   | Runtime change. Persists `server.json`, reseeds tracker, rebroadcasts cached frame. |

Invalid preset keys are dropped silently (`MilestoneFrequency.isValid` guard) — a hand-edited typo or a stale version of the app talking to a newer daemon degrades to "no change".

## Daemon lifecycle (LaunchAgent)

The daemon binary lives at `Sissy.app/Contents/MacOS/sissy-serverd`. Its LaunchAgent plist is bundled at `Sissy.app/Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist` and uses `BundleProgram` so it remains app-bundle relative if the app is moved.

The menubar app's `ServerServiceController` uses `SMAppService.agent(plistName:)` to register/unregister the LaunchAgent. Registering starts the daemon and enables it for future logins; unregistering stops it and removes the login item registration. Runtime state in the UI comes from `/health`, not from parsing `launchctl` output. Quitting the menubar app does not stop the daemon — the OLED feed survives.

## Operational notes

- **Pricing**: there is no hand-maintained rate table. Rates resolve `server.json` `pricingOverride` → the LiteLLM catalog fetched at runtime (`PriceCatalog.swift`, refreshed every 24 h, cached in Application Support) → `PricingSeed.swift`, a generated snapshot embedded at build time for the offline / first-run case. A new model therefore needs no Sissy release. The cold backfill runs against exactly one catalog: a cache newer than the seed is applied before the scan starts, otherwise the first fetch is awaited under `PriceCatalogSource.coldStartBudget` and the seed prices the scan if it doesn't land. A refresh never reprices what it already counted, so letting a catalog arrive mid-scan would split a single day across two rate sets. `remotePricing: false` pins the daemon to the seed and stops all outbound requests. Regenerate the seed when cutting a release: `sissy-serverd --dump-seed > app/SissyServer/PricingSeed.swift`. The `pricing-oracle` CI job asserts exact agreement with `ccusage`, which prices from the same LiteLLM data.
- **Network changes**: the easiest reset is to wipe NVS via `WifiBootstrap::forgetAndReboot()` or a long BOOT-button hold.
- **Cert pinning / TLS**: out of scope for V1. Run on LAN only.
- **Replay**: every WS client gets the last broadcast frame on connect, so reboots don't show stale `--`.
- **Failure modes**:
  - No JSONL files for any active provider (empty `~/.claude/projects` and/or empty `~/.codex/sessions`) → `/health.usageReader = "no-jsonl-found"`, no frames broadcast
  - WiFi drop → WiFiManager attempts auto-reconnect; OLED shows "ws down retrying..."
  - Server unreachable → `WebSocketsClient::setReconnectInterval(3000)` retries forever; after 15 s the firmware switches to the offline mascot
