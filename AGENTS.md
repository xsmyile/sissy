# AGENTS.md

Guidance for coding agents working in this repository.

## Repository layout

Two independent toolchains in one repo. Don't try to lint/build them together.

- `firmware/` — ESP32 WROOM-32 C++ firmware (PlatformIO, Arduino framework). Entry `firmware/src/main.cpp`. `platformio.ini` lives at repo root with `src_dir = firmware/src`, `include_dir = firmware/include`.
- `app/` — macOS 26+ Xcode workspace, two targets:
  - `Sissy` — menubar SwiftUI app (`app/Sissy/`).
  - `sissy-serverd` — native daemon (`app/SissyServer/`), built as a command-line tool and copied into `Sissy.app/Contents/MacOS/` so the app ships the daemon as a single bundle.
  Xcode project generated from `app/project.yml` via XcodeGen — never hand-edit `Sissy.xcodeproj`. Bundle id `com.radonforge.sissy`, team `AS75YRKL95`.
- `scripts/png_to_bitmap.py` — generates `firmware/src/sprites_mono.h` from PNGs in `sprites/raw/` (gitignored).
- `docs/ARCHITECTURE.md` is the source of truth for wire protocol + module map; read it before changing the WS frame shape or boot flow.

## Common commands

### Firmware (run from repo root)

```bash
pio run -e esp32dev                                    # build only
pio run -e esp32dev -t upload                          # USB flash (port pinned in platformio.ini)
pio run -e esp32dev -t upload --upload-port esp-XXXXXX.local   # OTA flash
pio device monitor                                     # serial @115200
cp firmware/include/secrets.h.example firmware/include/secrets.h   # required before first build
```

`upload_port`/`monitor_port` are pinned to `/dev/cu.usbserial-10` in `platformio.ini` — change there if your adapter enumerates differently.

### macOS app + daemon (run from `app/`)

```bash
xcodegen generate                                                      # regenerate Sissy.xcodeproj from project.yml
xcodebuild -project Sissy.xcodeproj -scheme Sissy -configuration Debug build
xcodebuild -project Sissy.xcodeproj -scheme sissy-serverd -configuration Debug build
../scripts/dev-build-app.sh                                            # signed local app for Server start/stop testing

# Daemon self-test (pure formatters + pricing tables)
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --self-test

# Daemon scan-once mode (compare against `npx ccusage claude --json` or `ccusage codex --json`)
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --scan
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --scan --scan-provider codex
```

Server start/stop through `SMAppService` must be tested from a normally signed app bundle. `CODE_SIGNING_ALLOWED=NO` is fine for CI compilation/tests, but launching that product locally makes macOS reject `Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist`.

Adding/removing Swift files requires re-running `xcodegen generate` — the project file is generated, not tracked semantically. The daemon target sources live in `app/SissyServer/`; the app target in `app/Sissy/`.

### CI

`.github/workflows/ci.yml` runs (1) `pio run -e esp32dev` at repo root with a stub `secrets.h`, (2) `xcodebuild`, unit tests, and `--self-test` for both Xcode targets on macos-26.

## Architecture

### Data flow (end-to-end)

```
~/.claude/projects/**/*.jsonl ──► ClaudeCodeUsageReader ─┐
                                                          ├─► UsageAggregator ──► Hub.broadcast ──► WS /ws ──► firmware WsClient ──► Frame → SSD1306Display.render
~/.codex/sessions/**/*.jsonl  ──► CodexUsageReader      ─┘                              ▲                              │
                                                                                        └───────── hello frame ────────┘
```

`UsageAggregator` sums per-day totals across N `UsageProvider` instances and emits a single combined frame. The combined `tokens`/`cost`/`state` scalars are pre-formatted by the daemon for the OLED; alongside them the frame carries a raw `providers: [{id, tokens, cost}]` array so the menubar app derives both the header subtitle and the **Breakdown** submenu rows from one push-based payload. Firmware ignores `providers`. `/stats` is now diagnostic-only (`connectedClients`, `filesWatched`, `lastFrameAt`).

The daemon is stateful in one place: `Hub.lastFramePayload`. Every new WS client gets it replayed on connect so the OLED never shows `--` after a reconnect. Any change to the frame contract (`tokens`, `cost`, `state`, `providers`) must be made in **four** places that have no shared schema:

1. `app/SissyServer/FrameBuilder.swift` — `FrameData` shape, scalar formatters, picks `state`, owns `ProviderSlice`.
2. `app/SissyServer/Hub.swift` — `encode(_:devicePresent:)` is where `FrameData` becomes JSON on the wire.
3. `firmware/src/net/WsClient.cpp` — parses JSON into `Frame` (ignores `providers`).
4. `app/Sissy/Server/WebSocketClient.swift` — parses for the menubar mirror; decodes `providers` into `DisplayFrame.providers`.

`state` enum values (`sleep|think|code|trend|glow|angry`) are coupled to (a) the mascot bitmap order in `firmware/src/display/SSD1306Display.cpp`, (b) thresholds in `app/SissyServer/FrameBuilder.swift` (`StateThresholds`), (c) `MascotState` in `firmware/src/state/`. Renaming a wire state means updating all three plus regenerating sprites.

Firmware additionally owns an `MS_OFFLINE` state that is **not** sent over the wire — it's triggered locally when WS has been disconnected for more than 15 s.

### Daemon modules (`app/SissyServer/`)

| File | Job |
|---|---|
| `main.swift`                    | Entry point, signal handling, `--self-test` / `--scan` / `--scan-provider` flags |
| `SissyServer.swift`             | Actor that owns Hub + UsageAggregator and bootstraps NIO server. Auto-detects Codex provider at boot. |
| `HTTPRequestHandler.swift`      | `/health`, `/stats` (diagnostic: connectedClients, filesWatched, lastFrameAt); Bearer auth |
| `WebSocketSinkHandler.swift`    | Per-connection NIO WS handler; conforms to `FrameSink` |
| `Hub.swift`                     | Actor — fan-out + last-frame replay |
| `UsageProvider.swift`           | Protocol shared by every CLI tail (id, start/stop, current, isWarm) |
| `UsageAggregator.swift`         | Sums `DayTotals` across providers; emits combined frame to Hub |
| `ClaudeCodeUsageReader.swift`   | Tails `~/.claude/projects/**/*.jsonl`. Dedupes by `requestId`. |
| `CodexUsageReader.swift`        | Tails `~/.codex/sessions/**/rollout-*.jsonl`. Uses `last_token_usage` as per-turn delta; model from `turn_context.payload.model` (fallback `gpt-5-codex`). |
| `Pricing.swift`                 | Anthropic cost math + `ModelPricing` / `PricingTable`. No rate table — rates come from the catalog or the seed |
| `OpenAIPricing.swift`           | OpenAI cost math, same three-source precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM's rate table at runtime; renders `PricingSeed.swift` for `--dump-seed` |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — the offline / first-run floor. Never hand-edit |
| `FrameBuilder.swift`            | `fmtTokens`, `fmtBurn`, `fmtCost`, `pickState` |
| `Auth.swift`                    | Constant-time bearer compare. Empty token = open mode (dev only) |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`. Carries `providers: { claudeCode, codex }` toggles, `codexDataDir`, `remotePricing`. |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); Claude reader stays on legacy `usage-state.json` for upgrade smoothness. |

### Firmware modules

- `display/IDisplay.h` is the seam for swapping in the ST7735 color build later — keep it pure-virtual; don't leak SSD1306 specifics upward.
- `net/WsClient.cpp` uses a global `gOwner` trampoline because `WebSocketsClient::onEvent` does not accept `std::function`. This is intentional, not a refactor target.
- `net/Config` persists to NVS via `Preferences`. Pair Device provisions WiFi creds, bearer token, server host/port, and OTA password over USB serial. The WiFiManager captive portal remains a fallback path and exposes the same fields.
- Boot halts if OLED I²C init fails — there is no headless mode. Don't add a fallback; the device has no other output.
- After 5 min without a fresh frame the panel auto-dims to `0x10`. After 15 s of WS disconnect the mascot switches to `MS_OFFLINE` and draws a "no signal" glyph.

### macOS app

Menubar-only (`LSUIElement: true`). Sandbox disabled, USB + network entitlements on — it talks to ESP32 over serial during pairing (`Pairing/SerialPort.swift`, `Provisioner.swift`) and over WebSocket once paired (`Server/WebSocketClient.swift`). Uses CoreLocation only to read nearby SSIDs for the pairing picker (`Pairing/WiFiScanner.swift`); the Info.plist usage strings explain this — keep them accurate if you touch location code.

The app drives the bundled daemon's lifecycle via `Server/ServerServiceController.swift` and `SMAppService.agent(plistName:)`. The LaunchAgent plist is bundled at `Sissy.app/Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist` and points at `Contents/MacOS/sissy-serverd` with `BundleProgram`; the app no longer writes plists into `~/Library/LaunchAgents` or parses `launchctl print` for UI state. `Server/ServerHealthMonitor.swift` polls `/health` every 3 s so the menubar surfaces `Running / Stopped / No JSONL detected`. Quitting the app does not stop the daemon — that's the whole point of the agent split.

## Conventions specific to this repo

- **No serial fallback in firmware.** This is a WiFi+WebSocket device. Don't add USB-serial frame transport "just in case".
- **Sprites are generated, not authored.** Never hand-edit `firmware/src/sprites_mono.h`. Regenerate via `scripts/png_to_bitmap.py`; the argument names (`coding=`, `sleeping=`, …) must match the C array order in `SSD1306Display.cpp`. `MS_OFFLINE` currently aliases to the `sleeping` bitmap — replace with a dedicated PNG when ready.
- **`platformio.ini` controls the layout.** Don't move `firmware/src/` without updating `src_dir`/`include_dir`.
- **The git tag is the only version source; never hand-edit a version.** `scripts/version.sh` resolves `MARKETING_VERSION` from the latest tag and `CURRENT_PROJECT_VERSION` from `git rev-list --count HEAD`; `release.sh`, `release.yml` and `dev-build-app.sh` pass both to xcodebuild, which reaches the app and the daemon in one build. Cutting a release is `git tag -a vX.Y.Z && git push --tags` — there is no bump commit. The pair in `app/project.yml` is a `0.0.0` / `0` dev placeholder, and both `Info.plist` files carry only `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Reintroducing a literal in either plist recreates the bug where 0.1.6 and 0.1.7 both shipped build 6; the pre-notarization `verify bundle version` guard in `release.sh` and `release.yml` exists to catch exactly that. The release workflow needs `fetch-depth: 0` — the default shallow clone makes the commit count 1.
- **Bearer token symmetry.** `authToken` in `~/Library/Application Support/Sissy/server.json` must equal the value provisioned to the device by Pair Device or typed into the captive portal "Bearer token" field, otherwise the WS handshake 401s silently from the device's POV.
- **There is no hand-maintained rate table, and adding one is a regression.** Rates resolve through three sources: `server.json` `pricingOverride` → the LiteLLM catalog fetched at runtime (`PriceCatalog`, refreshed every 24 h, cached in Application Support) → `PricingSeed.swift`. A provider shipping a new model therefore needs **no Sissy release**. If a model prices at $0, fix the seed or wait for the refresh — do not reintroduce a table.
- **`PricingSeed.swift` is generated, not authored** — same rule as `firmware/src/sprites_mono.h`. Regenerate when cutting a release: `sissy-serverd --dump-seed > app/SissyServer/PricingSeed.swift`. It is produced by the same Swift parser that validates the runtime fetch, so there is no second implementation to drift.
- **ccusage is the cost oracle — specifically the JS package on npm.** It prices from LiteLLM too, so reading LiteLLM directly is what keeps Sissy agreeing with the number users cross-check. Where the two would disagree, match ccusage — subscription users never see a token invoice, so agreeing with the community tool beats agreeing with a hypothetical bill. The `pricing-oracle` workflow asserts exact agreement on a synthetic fixture, and invokes it as `npx ccusage@latest`. Verify pricing questions by **measuring** against ccusage, not by reading pricing pages: two independent readings of the long-context rules (an earlier pass here and a Codex review) both got them wrong, and a three-point measurement settled it in minutes.
- **`brew install ccusage` is a different implementation and is not the oracle.** Upstream ships a Rust rewrite alongside the JS package; Homebrew builds that one. Measured 2026-07-29, the Rust build 20.1.0 bills 1-hour cache-writes at the 5-minute rate (1M `ephemeral_1h` opus tokens → $6.25 where npm 20.0.19 and Sissy both say $10.00). Claude Code writes ~93% of its cache at the 1h TTL, so on a real day that reads as Sissy over-billing by ~7% — it is not. Before acting on a user-reported gap, check which binary produced their number: `ccusage --version` reporting a version npm never published (`npm view ccusage versions`) means the Rust build.
- **Known residual vs ccusage: ~0.35% on real logs** (measured 2026-07-29 against npm 20.0.19; an earlier pass recorded ~0.06%). Sub-agent (`isSidechain: true`) entries are written more than once within a session file and the two tools collapse a handful of them differently — localized to the sub-agent models, with the main model matching exactly. Not worth chasing; the fixture-based oracle is the regression guard.
- **Long-context tiers are deliberately not modelled.** Some models publish an above-200k/272k rate. ccusage bills only the tokens *above* the threshold (measured, not inferred — Anthropic's published table reads as whole-request substitution, so ccusage is arguably wrong). Claude Code compacts before reaching the threshold, so the case is near-unreachable; it was implemented once and removed as unjustified complexity.
- **Codex token convention.** `CodexUsageReader` uses `last_token_usage` as the per-turn delta (verified against real rollout files — summing `last_token_usage` across events equals the final `total_token_usage` cumulative). `output_tokens` is treated as **gross** (it already includes reasoning); `reasoning_output_tokens` is a sub-breakdown surfaced for observability only, never added to output before pricing. Verified on real rollouts: `total_tokens == input_tokens + output_tokens` regardless of `reasoning_output_tokens`. Same convention ccusage uses, so the two should agree within rounding.
- **Per-provider persistence.** `ClaudeCodeUsageReader` writes `usage-state.json` (legacy path) for upgrade smoothness; `CodexUsageReader` writes `usage-state-codex.json` via `UsageStatePersistence.forProvider("codex")`. A schema change in one provider can quarantine its snapshot without invalidating the other.

## Local fast feedback (pre-commit)

`pip install pre-commit && pre-commit install` once per clone. Subsequent `git commit` automatically runs `swift-format`, `swiftlint`, `clang-format`, `shellcheck`, `ruff` (check+format), and `actionlint` against changed files. Same tools as CI, no version drift.

`pre-commit run --all-files` runs the full sweep.

CI lints against a recorded backlog in `.swiftlint-baseline`, so only **new** violations annotate a PR. Regenerate it from the repo root when the backlog legitimately changes (e.g. after a refactor that adds or clears violations): `swiftlint lint --write-baseline .swiftlint-baseline`.

## Quality gates

Consumed by the `/commit` skill. Run before each commit; `--no-checks` to skip.

```yaml
quality-gates:
  format: xcrun swift-format lint --recursive --strict app/Sissy app/SissyServer app/SissyTests && ruff format --check scripts/
  lint: swiftlint lint --quiet --lenient && ruff check scripts/ && shellcheck scripts/*.sh
```

`test:` is intentionally omitted — `xcodebuild test` is too slow per-commit; CI catches it.
