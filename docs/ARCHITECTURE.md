# Architecture

One process. `Sissy.app` runs the metering engine in-process and renders it in
the menu bar; there is no daemon, no socket and no second half to keep in step.
The engine also builds as `sissy-cli`, a command-line tool nothing ships to a
user — CI drives it for `--self-test`, `--scan`, `--dump-seed` and
`--refresh-catalog`, so the engine's checks have an entry point that is not an
AppKit app.

It was two processes until the single-process merge, because the daemon was a
network server for an ESP32 companion and the app was its second client. The
companion left first; the wire followed it.

## Data flow

```
~/.claude/projects/**/*.jsonl ──► ClaudeCodeUsageReader ─┐
                                                          ├─► UsageAggregator ──► UsageEngine ──► FrameData
~/.codex/sessions/**/*.jsonl  ──► CodexUsageReader      ─┘                                             │
                                                                                                      ▼
                                                                            UsageEngineHost ──► SissyModel ──► menu bar, panel
```

Each reader tails one CLI's session logs and pushes a `(today, prev)` pair
through `onChange` whenever its totals move. `UsageAggregator` fans those into a
single combined reading, `UsageEngine` builds a `FrameData` from it, and the
engine calls the callback it was handed. The app hands it one that lands the
frame on `SissyModel`; `sissy-cli --scan` hands it one that prints JSON.

`UsageEngine` is an actor and the UI is `@MainActor`. `UsageEngineHost`
(`app/Sissy/Models/UsageEngineHost.swift`) is the one hop between them: frames
arrive there and reach `SissyModel` already on the main actor, and every control
the panel offers is forwarded the other way.

## The frame

`FrameData`, `ProviderSlice` and `UsageWindow` live in
[`app/SissyCore/FrameBuilder.swift`](../app/SissyCore/FrameBuilder.swift). They
are Swift values passed by reference through a callback, not a serialised
payload — a field added to one of them needs no encoder, no decoder and no
version check.

`tokens` / `cost` / `burn` are pre-formatted strings. That shape is inherited
from rendering into 128×64 pixels, and it is why `UsageFormat` in the app
re-implements its own formatters: every surface Sissy has now has room for a
decimal and a full cent. `burn` is read off the frame as-is; `tokens` and
`cost` are read only in the branch where no provider has spent anything today,
where both formatters agree on "0" anyway.

`providers` carries the raw per-provider slices — tokens as `Int`, cost as
`Decimal` — so the header subtitle, the panel's per-provider rows and each
provider's gauges all derive from one payload instead of from two counts that
can disagree. Stable order: `claude-code`, `codex`, then alphabetical.
Providers with no spend today are omitted, so the panel shows the day's actual
split rather than stale `$0` rows.

`providers[].windows` carries that CLI's subscription rate-limit windows,
shortest first, each identified by its `minutes` rather than by its position —
vendors do not agree on an order, and Codex's own `primary` bucket is not always
the session one. `usedPercent` is a percentage of the window's allowance; a
bucket whose reset has passed is dropped before the frame is built. Empty for a
provider that publishes no limits — an API-key user, a CLI that has not surfaced
a window yet, or Claude Code with `claudeLimits` off — which is what puts the
panel row back on its share-of-today bar.

`providers[].plan` is the account's subscription plan as the vendor's own
lowercase token — `max`, `team`, `plus` — never a display label: the app words it
in `UsageFormat`, so a tier a vendor ships after this release still reaches the
panel. `nil` for a provider that names none, which is what leaves the row's badge
off. `planTier` is the limit tier that plan is metered at (`max_5x`), for the one
vendor that publishes one, and rides inside `plan`'s presence: alone it names
nothing the app could attribute. The app folds it into the badge only when the
tier names the plan it decorates — a Max account reads "Max 5x", while a Team
seat metered at the same tier keeps "Team" and puts the tier in the row's
tooltip, because "Team 5x" is a plan nobody sells.

Claude Code publishes no limit state on disk, so its windows come from
`ClaudeLimitsProbe`, which reads the CLI's own OAuth token out of the login
keychain and polls the endpoint Claude Code's `/usage` reads. That costs a
one-time macOS keychain authorization, so it stays off until the user asks for it
in Settings.

`keepAwake` carries `{mode, active}` and is never optional, including when off:
the panel draws its control from this, and "off" and "nothing reported" must not
collapse into the same value. `mode` is where the user left the switch and
survives in `server.json`; `active` is whether the Mac is being held awake right
now. The hold covers the screen as well, but `active` follows the system
assertion, which is what that claim is about: a refused display assertion leaves
a Mac that stays up behind a screen that dims, and says so in the log rather than
retracting the hold that did take. A system assertion that could not be taken
drops the display one with it, so a false `active` always means nothing is held.
The two come apart — power management can refuse an assertion — and the panel
renders them as two properties of one glyph, tint for the mode and fill for the
effect, so "switched on and holding nothing" is readable at a glance rather than
silent.

`prevTokens` / `prevCost` carry yesterday's raw combined totals so the panel can
render a day-over-day delta without a second data path. Both are nil together
until every active provider has produced a `prev` snapshot, so the app renders no
delta rather than a false 0%.

## Engine modules (`app/SissyCore/`)

Compiled into both targets. `main.swift` and `SelfTest.swift` are the tool's own
and excluded from the app; everything else is shared. A new file here is
compiled into the app too.

| File | Job |
|---|---|
| `UsageEngine.swift`             | Actor that owns the aggregator, the limits probe and the keep-awake hold; builds each frame and calls the callback it was handed |
| `UsageProvider.swift`           | Protocol shared by each CLI log reader (id, start/stop, current, isWarm) |
| `UsageAggregator.swift`         | Sums per-day totals across active providers and rebuilds the per-provider slices |
| `ClaudeCodeUsageReader.swift`   | Tails `~/.claude/projects/**/*.jsonl`; dedupes by `requestId`; forwards the limit probe's windows; owns `parseTimestamp`, the one timestamp parser every reader and the probe share |
| `CodexUsageReader.swift`        | Tails `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`); uses `last_token_usage` as per-turn delta; model from `turn_context.payload.model` (fallback `gpt-5-codex`) |
| `UsageReaderShared.swift`       | Tuning constants both tails share (`ingestChunkSize`, `pollEmitThrottle`, mtime slack) so they cannot drift apart |
| `ClaudeLimitsProbe.swift`       | Polls Anthropic's OAuth usage endpoint for the 5-hour and weekly windows; 5-min refresh, 30-min backoff on 429; off unless `claudeLimits` is set |
| `ClaudeCredentials.swift`       | Read-only lookup of Claude Code's keychain OAuth token — never writes it, never refreshes it — bounded so an unanswered authorization dialog cannot park the probe |
| `ClaudeProfile.swift`           | Reads the plan out of the CLI's own `.claude.json` (`CLAUDE_CONFIG_DIR` or `$HOME`); no keychain, so it answers with `claudeLimits` off |
| `CodexAuth.swift`               | Reads the `chatgpt_plan_type` claim out of `~/.codex/auth.json`, for the boot before the first turn; touches no other field in it |
| `FSWatcher.swift`               | Wraps `FSEventStreamCreate` (CoreServices); drives per-provider reader wakes |
| `FrameBuilder.swift`            | `FrameData` / `ProviderSlice` / `UsageWindow`, plus `fmtTokens` / `fmtBurn` / `fmtCost` and the slice ordering |
| `KeepAwake.swift`               | Actor owning the `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` assertions, plus `KeepAwakeMode` / `KeepAwakeState`; the mode persists in `server.json`, the assertions die with the process |
| `Pricing.swift`                 | Anthropic cost math, `ModelPricing`, `PricingTable`; no rate table of its own |
| `OpenAIPricing.swift`           | OpenAI cost math, same override → catalog → seed precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM rates at runtime; renders the seed for `--dump-seed` |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — offline / first-run floor |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`; carries `providers` toggles, `codexDataDir`, `remotePricing`, `claudeLimits`, `keepAwake`. The engine owns the file |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); the Claude reader stays on the legacy `usage-state.json` for upgrade smoothness |
| `SissyPaths.swift`              | Support-dir and logs-dir resolution (`.dev` bundle id → dev tree) |
| `SissyLog.swift`                | `sissyLog`, stderr plus a size-capped `Library/Logs/Sissy/sissy.err.log` |
| `main.swift`                    | The tool's entry point: `--self-test` / `--scan` / `--scan-provider` / `--config` / `--dump-seed` / `--refresh-catalog`. No flag prints the list and exits 2 |
| `SelfTest.swift`                | The `--self-test` harness: pure formatter, pricing, parser and persistence assertions, run in CI |

The readers let each active provider's initial JSONL backfill finish in detached
tasks, so the app is interactive immediately even on a multi-GB history.
Steady-state CPU is near zero: provider-specific `FSEventStream`s (rooted at
`~/.claude/projects` and `~/.codex/sessions`) wake their readers only when JSONL
actually changes (kernel-coalesced events at ~1 s latency). A low-frequency
safety-net poll (default 60 s, `server.json.pollIntervalSeconds`) catches
missed-event flags (`MustScanSubDirs` / `UserDropped` / `KernelDropped`) and the
midnight day rollover when no JSONL activity straddles the boundary. Claude Code
entries are deduplicated by `requestId` because Claude Code logs each assistant
turn 2-3 times as the message streams; Codex turns are deduplicated implicitly
because `last_token_usage` arrives once per turn.

Each reader retains a 2-day window on disk (today + yesterday). Sissy only ever
surfaces today + yesterday — the latter feeds the panel's day-over-day delta — so
the retention window is sized to match. Cold scans skip every file with
`mtime < now-48h`, which on real-world trees (~500 MB across hundreds of
projects) parses ~10-20% of the bytes and finishes in low seconds. Bumping this
requires every consumer of `dailyTotals` to actually use the extra history; today
nothing does.

## The app (`app/Sissy/`)

Menu-bar only (`LSUIElement: true`), sandbox disabled. Three surfaces and no
windows of its own: a left-click usage panel (`Panel/`, an `NSPopover`), a short
right-click `NSMenu` (`Menu/StatusItemController.swift`), and the SwiftUI
`Settings` scene (`Settings/`, tabs General/About) — reachable from the app menu's
Settings… item (⌘,) and, in code, only through `SettingsLink`, which takes no
action closure and is why the panel footer aims the window at a tab through
`SissyModel.settingsTab`.

`Models/Preferences.swift` holds only what the app itself remembers
(`sissyMotion`, `retiredServerAgent`) in `preferences.json`. Everything about
metering lives in `server.json`, which the engine owns — the app reads
`claudeLimits` back from the engine rather than keeping a copy, because the copy
it used to keep could disagree with the file the probe actually booted from.

**Three readiness states, not one blank panel.** `HeaderSnapshot.make` is a pure
function of `(hasFrame, isWarm, filesWatched)`, which is what the tests target:

| | Header |
|---|---|
| a frame has landed | Sissy, awake |
| no frame, readers still scanning | "Sissy is waking up" / "Reading your session logs" |
| warm, no files watched | "Sissy is sleeping" / "No session logs found" |
| warm, files watched, nothing today | "Sissy is sleeping" / "Nothing spent yet today" |

The last is the common one first thing in the morning and the only one of the
three that is not a fault. A single "waiting" line sent people hunting for one.

## Lifecycle and login items

**One login item**, the app's own, through `SMAppService.mainApp`
(`Models/LoginItemController.swift`, surfaced as General → "Start at login",
falling back to a button into System Settings when macOS reports the item needs
approval). `SMAppService` is the record and no copy of it lands in
`preferences.json`: someone who removes Sissy from System Settings → Login Items
would leave a mirrored flag asserting something the system had already undone.

There were two until the merge — the daemon's LaunchAgent carried `RunAtLoad`
and counted whether or not the app was running. `Models/LegacyAgentRetirement.swift`
unregisters that agent once per install and, only if it actually retired one,
claims the login item on the user's behalf: Server on with the app *not* at login
was a legitimate configuration, and unregistering alone would silently stop
counting for exactly those users. The one-shot flag records that the *migration*
ran, and is only spent when the question was conclusively settled.

Both agent plists stay bundled at `Sissy.app/Contents/Library/LaunchAgents/` for
that one purpose: `SMAppService.agent(plistName:)` resolves the plist inside the
app bundle, so an agent whose plist is gone cannot be unregistered — measured:
with them removed, `.status` answers "Unable to find service status" and the
retirement is a no-op on exactly the machines that need it. They come out one
release after the one that ships the retirement, and the Homebrew cask's
`uninstall launchctl:` stanza and its `~/Library/LaunchAgents/…plist` zap path go
with them.

Nothing Sissy does to the machine outlives Sissy. It counts while it is running
and stops when it quits; the numbers live in files that are there either way, so
a relaunch resumes from persisted offsets and loses nothing. `KeepAwake` is the
worked example: the mode persists, the power assertions do not.

## Operational notes

- **Pricing**: there is no hand-maintained rate table. Rates resolve `server.json`
  `pricingOverride` → the LiteLLM catalog fetched at runtime (`PriceCatalog.swift`,
  refreshed every 24 h, cached in Application Support) → `PricingSeed.swift`, a
  generated snapshot embedded at build time for the offline / first-run case. A new
  model therefore needs no Sissy release. The cold backfill runs against exactly one
  catalog: a cache newer than the seed is applied before the scan starts, otherwise
  the first fetch is awaited under `PriceCatalogSource.coldStartBudget` and the seed
  prices the scan if it doesn't land. A refresh never reprices what it already
  counted, so letting a catalog arrive mid-scan would split a single day across two
  rate sets. `remotePricing: false` pins Sissy to the seed and stops all outbound
  requests. Regenerate the seed when cutting a release:
  `sissy-cli --dump-seed > app/SissyCore/PricingSeed.swift`. The `pricing-oracle` CI
  job asserts exact agreement with `ccusage`, which prices from the same LiteLLM data.
- **Permissions**: first run asks for nothing. A permission is requested when the
  user switches on the module that needs it — the `claudeLimits` toggle is the worked
  example, and the keychain prompt happens when the switch is flipped, not at boot.
- **No third-party code ships.** The last dependency was SwiftNIO, which the
  WebSocket server needed. `CREDITS.md` credits the projects Sissy *reads*
  (`ccusage`, LiteLLM), which is courtesy rather than obligation; `AboutTests` fails
  if a licence file reappears as a bundled resource.
- **Failure modes**:
  - No JSONL for any active provider (empty `~/.claude/projects` and/or empty
    `~/.codex/sessions`) → the panel reads "No session logs found", no frames are built
  - A `server.json` that will not parse → `ServerConfig.load` overlays what it can read
    onto the defaults rather than metering nothing
  - A model with no rate in any source → one log line per model per run and zero cost
    for it, surfacing the gap instead of billing at a wrong rate
