# AGENTS.md

Guidance for coding agents working in this repository.

## Repository layout

- `app/` — macOS 26+ Xcode workspace, two targets:
  - `Sissy` — menubar SwiftUI app (`app/Sissy/`).
  - `sissy-serverd` — native daemon (`app/SissyServer/`), built as a command-line tool and copied into `Sissy.app/Contents/MacOS/` so the app ships the daemon as a single bundle.
  Xcode project generated from `app/project.yml` via XcodeGen — never hand-edit `Sissy.xcodeproj`. Bundle id `com.radonforge.sissy`, team `AS75YRKL95`.
- `docs/ARCHITECTURE.md` is the source of truth for wire protocol + module map; read it before changing the WS frame shape.

The ESP32 companion that used to live in `firmware/` is gone from master as of 0.1.9. The last state where it built and paired is the `companion` branch. Archive it on a **branch, never a tag**: `scripts/version.sh` resolves `MARKETING_VERSION` with an unfiltered `git describe --tags`, so any reachable tag becomes the version.

## Common commands

### macOS app + daemon (run from `app/`)

```bash
xcodegen generate                                                      # regenerate Sissy.xcodeproj from project.yml
xcodebuild -project Sissy.xcodeproj -scheme Sissy -configuration Debug build
xcodebuild -project Sissy.xcodeproj -scheme sissy-serverd -configuration Debug build
../scripts/dev-build-app.sh                                            # signed local app for Server start/stop testing

# Daemon self-test (pure formatters + pricing tables)
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --self-test

# Daemon scan-once mode (compare against `npx ccusage@latest claude --json` or
# `npx ccusage@latest codex --json` — never a bare `ccusage`, which may be the Homebrew build)
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --scan
"$(xcodebuild -scheme sissy-serverd -showBuildSettings | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-serverd" --scan --scan-provider codex
```

Server start/stop through `SMAppService` must be tested from a normally signed app bundle. `CODE_SIGNING_ALLOWED=NO` is fine for CI compilation/tests, but launching that product locally makes macOS reject `Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist`.

Adding/removing Swift files requires re-running `xcodegen generate` — the project file is generated, not tracked semantically. The daemon target sources live in `app/SissyServer/`; the app target in `app/Sissy/`.

### CI

`.github/workflows/ci.yml` runs shell/YAML/Python lint on ubuntu, then `xcodebuild`, unit tests, and `--self-test` for both Xcode targets on macos-26. `pricing-oracle.yml` asserts cost agreement with `ccusage` on a synthetic fixture, and `release.yml` builds, notarizes and publishes on a pushed tag.

## Architecture

### Data flow (end-to-end)

```
~/.claude/projects/**/*.jsonl ──► ClaudeCodeUsageReader ─┐
                                                          ├─► UsageAggregator ──► UsageEngine ──► FrameData ──► SissyModel
~/.codex/sessions/**/*.jsonl  ──► CodexUsageReader      ─┘
```

`UsageAggregator` sums per-day totals across N `UsageProvider` instances and `UsageEngine` builds a single combined frame from them. One process: the app runs the engine in-process and the frame is a Swift value, not JSON. There is no wire contract to keep in step any more — `FrameData`, `ProviderSlice` and `UsageWindow` live in `app/SissyServer/FrameBuilder.swift` and the app renders those types directly.

The combined `tokens`/`cost`/`burn` scalars are still pre-formatted, a shape inherited from rendering into 128×64 pixels, and the reason `UsageFormat` in the app re-implements its own formatters; only `burn` is still read from the frame. Alongside them the frame carries a raw `providers` array so the header subtitle, the panel's per-provider rows and each provider's rate-limit gauges all come from one payload.

`app/SissyServer/` also still builds `sissy-serverd`, which CI drives for `--self-test`, `--scan`, `--dump-seed` and `--refresh-catalog`. Its NIO half (`SissyServer`, `Hub`, `HTTPRequestHandler`, `WebSocketSinkHandler`, `Auth`) is the last of the two-process design and goes next; nothing ships it to a user and the app never connects to it. A new file in that directory is compiled into the app too, so it must not import NIO or reach for `Hub`.

The mood pop-up, Sissy's state machine and the milestone celebrations are gone as of 0.1.9, and with them `state`, `pickState`, `StateThresholds` and the `MilestoneTracker`. They were the reason the app carried thresholds in dollars, which meant nothing to anyone whose daily spend sat far from them. Don't reintroduce a decorative signal on the cost axis; if the app grows a headline indicator it should sit on rate-limit headroom, which reads the same for every user.

### Daemon modules (`app/SissyServer/`)

The per-file map lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#daemon-modules-appsissyserver) — one table, so a module's note cannot drift between two files.

### macOS app

Menubar-only (`LSUIElement: true`). Sandbox disabled, network-client entitlement on; it reaches the daemon over WebSocket on loopback (`Server/WebSocketClient.swift`). It asks for no other permission — the USB entitlement and the CoreLocation and local-network usage strings existed only for pairing an ESP32 and went with it. Don't reintroduce a permission prompt without a reason a user would accept at first launch.

The app drives the bundled daemon's lifecycle via `Server/ServerServiceController.swift` and `SMAppService.agent(plistName:)`. The LaunchAgent plist is bundled at `Sissy.app/Contents/Library/LaunchAgents/com.radonforge.sissy.server.plist` and points at `Contents/MacOS/sissy-serverd` with `BundleProgram`; the app no longer writes plists into `~/Library/LaunchAgents` or parses `launchctl print` for UI state. `Server/ServerHealthMonitor.swift` polls `/health` every 3 s so the menubar surfaces `Running / Stopped / No JSONL detected`. The app has three surfaces and no windows of its own: a left-click usage panel (`Panel/`, an `NSPopover`), a short right-click `NSMenu` (`Menu/StatusItemController.swift`), and the SwiftUI `Settings` scene (`Settings/`, tabs General/About) — reachable from the app menu's Settings… item (⌘,) and, in code, only through `SettingsLink`, which takes no action closure and is why the panel footer aims the window at a tab through `SissyModel.settingsTab`. Quitting the app does not stop the daemon — that's the whole point of the agent split.

**Two login items, one per half** — [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#lifecycle-and-login-items) says which does what. The rule: neither state is mirrored in `preferences.json`. `SMAppService` is the record, and a user who removes Sissy from System Settings' Login Items would leave a mirrored flag claiming something the system had already undone.

## Conventions specific to this repo

- **A permission is asked for when the user switches on the module that needs it, never at launch.** Sissy's first run asks for nothing, and the README says so out loud; that is the reason someone installs a menu bar app that reads their session logs. A module that is off must not exist as far as the system is concerned — no TCC prompt, no notification authorization, no power assertion, no entitlement that only it needs. The Claude Code limits toggle is the worked example: the keychain prompt happens when the switch is flipped, not at boot.
- **Nothing Sissy does to the machine outlives Sissy.** Sissy counts while it is running and stops when it quits; the numbers live in files that are there either way, so a relaunch resumes from persisted offsets and loses nothing. `KeepAwake` is the worked example: the mode persists in `server.json`, the power assertion does not. A hold nobody can see, on a Mac whose menu bar has no Sissy in it, is a battery complaint with no path back to its cause. "Start at login" is therefore the switch that keeps a day complete, and the reason the [single-process migration](docs/single-process-migration.md) took the app's login item over from the retired agent rather than just unregistering it.
- **One Sissy, two poses.** `SissyModel.sissyAssetName` is the resting silhouette; `sissySleepingAssetName` is the same silhouette with its eye shut, and it is what the menu bar *and* the panel header rest on while nothing is reaching the app. Both are template images, so surfaces tint them and never ship a second copy. The icon is drawn at full opacity in both states — the shut eye replaced a 40% dim, so don't reintroduce one. Sizing is per-surface: the menu bar draws it at 17 pt because the asset carries 20 pt of ink where an unconfigured SF Symbol measures 15, and at native size it reads a third taller than its neighbours. Copy the image before resizing — `NSImage(named:)` returns the catalogue's shared instance.
- **Sissy's motion is one 24-frame sequence.** `Assets.xcassets/SissyMotion` holds a blink rendered at 60 fps as vector imagesets, and `SissyMenuBarMotion` slices it into the whole blink plus its two halves. Frames 6–9 are the byte-identical shut-eye hold, which is why the closing half stops at 6 and the opening half starts at 9. `SissyMenuBarAnimator` owns `button.image` from the moment it exists — anything else assigning it drops the remaining frames of a gesture. A blink fires when a frame lands (`SissyModel.lastFrameAt`, rate-limited by `SissyMenuBarMotion.dataBlinkCooldown`, because the readers coalesce emits only down to `UsageReaderShared.pollEmitThrottle`); the halves play when the pose changes; Reduce Motion, an open menu, or the pose the app launches in snap instead. **Two surfaces play Sissy**, and they are separate implementations because one assigns an `NSImage` and the other is SwiftUI: the status button through `SissyMenuBarAnimator`, and the panel header through `Panel/PanelSissy.swift`, which blinks on the same arrivals so an open popover is not a still Sissy. What they must not each reinvent is the timing — `SissyMenuBarMotion.step(at:)` is the single source of which frame a running gesture is on, and `dataBlinkCooldown` of when the next one is due. The panel plays only the blink: the poses still cross-fade there, since a 24 pt SwiftUI `Image` swap has no menu bar to match. There is no idle animation and no gesture on the cost axis: motion reports arrival, not spend. The frames are derived art — regenerating them needs the motion geometry that lives outside this repo, so a re-traced silhouette means re-rendering all 24.
- **The default port is 5155, and it is not a free choice.** It has to sit below macOS's ephemeral floor (`net.inet.ip.portrange.hifirst`, 49152) or an outbound socket can be handed it before the daemon binds at login, and clear of the ports dev tools claim — 8787, the default through v0.1.8, is `wrangler dev`'s, and a daemon that binds at login and never lets go is the side that wins that race. Moving it again means both `SissyPaths` copies plus the old value in `Preferences.migrateLegacyServerPort()`, or an existing install ends up pointing at a port nothing is bound to.
- **The daemon binds loopback.** It has one client, the app, on `127.0.0.1`. The wildcard bind existed to let an ESP32 on the LAN reach it; putting it back exposes the port to the network for nothing.
- **The git tag is the only version source; never hand-edit a version.** `scripts/version.sh` resolves `MARKETING_VERSION` from the latest tag and `CURRENT_PROJECT_VERSION` from `git rev-list --count HEAD`; `release.sh`, `release.yml` and `dev-build-app.sh` pass both to xcodebuild, which reaches the app and the daemon in one build. Cutting a release is `git tag -a vX.Y.Z && git push --tags` — there is no bump commit. The pair in `app/project.yml` is a `0.0.0` / `0` dev placeholder, and both `Info.plist` files carry only `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Reintroducing a literal in either plist recreates the bug where 0.1.6 and 0.1.7 both shipped build 6; the pre-notarization `verify bundle version` guard in `release.sh` and `release.yml` exists to catch exactly that. The release workflow needs `fetch-depth: 0` — the default shallow clone makes the commit count 1.
- **Bearer token symmetry.** `authToken` in `~/Library/Application Support/Sissy/server.json` is written by the app and read by the daemon. A mismatch 401s the WS handshake with nothing in the UI to say so.
- **There is no hand-maintained rate table, and adding one is a regression.** Rates resolve through three sources: `server.json` `pricingOverride` → the LiteLLM catalog fetched at runtime (`PriceCatalog`, refreshed every 24 h, cached in Application Support) → `PricingSeed.swift`. A provider shipping a new model therefore needs **no Sissy release**. If a model prices at $0, fix the seed or wait for the refresh — do not reintroduce a table.
- **`PricingSeed.swift` is generated, not authored.** Regenerate when cutting a release: `sissy-serverd --dump-seed > app/SissyServer/PricingSeed.swift`. It is produced by the same Swift parser that validates the runtime fetch, so there is no second implementation to drift.
- **ccusage is the cost oracle — specifically the JS package on npm.** It prices from LiteLLM too, so reading LiteLLM directly is what keeps Sissy agreeing with the number users cross-check. Where the two would disagree, match ccusage — subscription users never see a token invoice, so agreeing with the community tool beats agreeing with a hypothetical bill. The `pricing-oracle` workflow asserts exact agreement on a synthetic fixture, and invokes it as `npx ccusage@latest`. Verify pricing questions by **measuring** against ccusage, not by reading pricing pages: two independent readings of the long-context rules (an earlier pass here and a Codex review) both got them wrong, and a three-point measurement settled it in minutes.
- **`brew install ccusage` is a different implementation and is not the oracle.** Upstream ships a Rust rewrite alongside the JS package (`rust/crates/ccusage`), and the Homebrew formula still `cargo install`s that one — checked 2026-09-10 against the current homebrew-core formula, which builds `ccusage/ccusage` v20.0.20 from source. Measured on 1M `ephemeral_1h` opus tokens: the Rust build 20.1.0 bills the 1-hour tier at the 5-minute rate and says $6.25, where npm and Sissy both say $10.00 (re-measured 2026-09-10 against npm 20.0.20; first measured 2026-07-29 against 20.0.19). Claude Code writes ~93% of its cache at the 1h TTL, so on a real day that reads as Sissy over-billing by ~7% — it is not. Before acting on a user-reported gap, check which binary produced their number; About → **Copy diagnostics** names it (`CcusageProbe`, which classifies an install by where its symlinks land — `node_modules` is npm, `Cellar` is Homebrew).
- **A stale `brew` ccusage will never upgrade off itself.** The project moved from `ryoppippi/ccusage` to `ccusage/ccusage` and renumbered *backwards*: the old formula pinned v20.1.0, the current one v20.0.20. Homebrew sorts 20.1.0 as newer, so `brew outdated` stays silent forever and `brew upgrade` is a no-op — a machine that installed it before the move keeps serving the build with the cache-write bug. Only `brew uninstall ccusage` and a fresh install move it. The fix that removes the whole class of confusion is `npm i -g ccusage`, which puts the oracle itself on `PATH`. Note the 1-hour bug is fixed in the current Rust source (`CACHE_CREATE_1H_INPUT_MULTIPLIER = 2.0` in `ccusage-core/src/cost.rs`), so the divergence is version-specific — but that same file bills long context as whole-request substitution where the JS was measured to bill only the tokens above the threshold, so the two implementations still are not interchangeable.
- **Known residual vs ccusage: ~0.35% on real logs** (measured 2026-07-29 against npm 20.0.19; an earlier pass recorded ~0.06%). Sub-agent (`isSidechain: true`) entries are written more than once within a session file and the two tools collapse a handful of them differently — localized to the sub-agent models, with the main model matching exactly. Not worth chasing; the fixture-based oracle is the regression guard.
- **Long-context tiers are deliberately not modelled.** Some models publish an above-200k/272k rate. ccusage bills only the tokens *above* the threshold (measured, not inferred — Anthropic's published table reads as whole-request substitution, so ccusage is arguably wrong). Claude Code compacts before reaching the threshold, so the case is near-unreachable; it was implemented once and removed as unjustified complexity.
- **The plan comes from a different place for each provider, and in neither case the obvious one.** Codex names it on the same `rate_limits` block as its windows (`plan_type`), so `captureWindows` takes both and `codexResume.plan` persists it for the same reason it persists the windows. That source answers only while there are unread bytes, though — a daemon resuming with its offsets at EOF has nothing left to re-read and the row sat without a badge until the user's next turn, so `CodexAuthSource` reads the `chatgpt_plan_type` claim out of the id_token in `~/.codex/auth.json` at boot and any rollout event then overwrites it. That file also holds Codex's tokens: nothing but the claim may ever leave that type, and the JWT's signature is deliberately not verified — the value is a display string read from the user's own disk. Claude Code publishes it nowhere Sissy already looked: the OAuth usage endpoint carries buckets and no plan (measured), and the copy in the login keychain — `subscriptionType`, alongside the token `ClaudeCredentials` reads — sits behind the authorization prompt the `claudeLimits` toggle exists to gate, so reaching for it would put a keychain dialog in front of someone who only switched the daemon on. `ClaudeProfileSource` therefore reads `oauthAccount.organizationType` out of the CLI's own `.claude.json` (`CLAUDE_CONFIG_DIR` or `$HOME`, never derived from `claudeDataDir` — that points at the projects tree) and strips the `claude_` prefix, which lands exactly on the token Claude Code's own label switch takes. Alongside the plan it reads `userRateLimitTier` as `plan_tier` (`max_5x`), which the app folds into the badge only when the tier names the plan it decorates: a Max account reads "Max 5x", while a Team seat metered at the same tier keeps "Team" and puts the tier in the row's tooltip, because "Team 5x" is a plan nobody sells. Every token crosses the wire raw and lowercase; `UsageFormat.plan(_:tier:)` is what words them, so a tier a vendor ships tomorrow needs no release. Neither source is fresh on demand: Claude's updates when the CLI re-fetches its profile, Codex's arrives one turn behind, and that is the ceiling.
- **Codex token convention.** `CodexUsageReader` uses `last_token_usage` as the per-turn delta (verified against real rollout files — summing `last_token_usage` across events equals the final `total_token_usage` cumulative). `output_tokens` is treated as **gross** (it already includes reasoning); `reasoning_output_tokens` is a sub-breakdown surfaced for observability only, never added to output before pricing. Verified on real rollouts: `total_tokens == input_tokens + output_tokens` regardless of `reasoning_output_tokens`. Same convention ccusage uses, so the two should agree within rounding.
- **Per-provider persistence.** `ClaudeCodeUsageReader` writes `usage-state.json` (legacy path) for upgrade smoothness; `CodexUsageReader` writes `usage-state-codex.json` via `UsageStatePersistence.forProvider("codex")`. A schema change in one provider can quarantine its snapshot without invalidating the other.
- **Adding a snapshot field: reach for an optional, not a `schemaVersion` bump.** `UsageStateSnapshot` is shared, so bumping the version discards *both* snapshots — measured 2026-09-10, that costs Claude Code a ~16 s cold scan of `~/.claude/projects` for a change that may tell it nothing. An optional field lets only the reader that needs it treat `nil` as "cold-scan my own tree" (~2 s for Codex); `codexResume` is the worked example. Bump the version only when the change alters how a token count or cost is *derived*, which is what the field is documented for.
- **Codex resume state is not an optimisation.** `codexResume.fileModels` exists because rebuilding the per-file model map means re-reading every byte already consumed, and the reader emits nothing until it finishes — measured at 110 s on a 43 MB tree, during which the panel has no Codex row at all. `codexResume.rateLimitWindows` exists because Codex's limits arrive only on the CLI's own `token_count` events: with offsets at EOF there is nothing to re-read, so without persistence the gauges stay blank until the next turn. Sissy is therefore always one Codex turn behind on those percentages — that is the ceiling, not a bug.
- **Sissy links nothing third-party, and `CREDITS.md` is not a licence file.** The last dependency was SwiftNIO, which the WebSocket server needed; with the server gone the app ships only its own code, so nothing has to travel with the binary and nothing is bundled for it — `AboutTests` fails if a licence file reappears as a resource. `CREDITS.md` at the root credits the projects Sissy *reads* (`ccusage`, LiteLLM), which is courtesy rather than obligation, and About's Acknowledgements sheet lists the same two inline. Adding a dependency means putting the notices back, in both places.

## Local fast feedback (pre-commit)

`pip install pre-commit && pre-commit install` once per clone. Subsequent `git commit` automatically runs `swift-format`, `swiftlint`, `shellcheck`, `ruff` (check+format), and `actionlint` against changed files. Same tools as CI, no version drift.

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
