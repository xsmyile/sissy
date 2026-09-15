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
~/.claude/projects/**/*.jsonl ──► LocalUsageProvider(ClaudeCodeAdapter) ─┐
                                                                          ├─► UsageAggregator ──► UsageEngine ──► FrameData
~/.codex/sessions/**/*.jsonl  ──► LocalUsageProvider(CodexAdapter)      ─┘                                             │
                                                                                                                      ▼
                                                                                            UsageEngineHost ──► SissyModel ──► menu bar, panel
```

One tail reads both trees. `LocalUsageProvider` owns everything that is the same
either way — offsets, mtimes, the FSEvents watcher, the safety-net poll, dedup,
day buckets, persistence, the emit throttle — and a `SourceAdapter` per log
format owns the three things that are not: which bytes on a line are worth
parsing, what they cost, and which of its own state has to survive a relaunch.
Each provider pushes today's totals through `onChange` whenever its reading
moves — new tokens, but also a plan, an account or an authorization that
changed, none of which a token count would show. `UsageAggregator` fans those
into a single combined reading, `UsageEngine` builds a `FrameData` from it, and
the engine calls the callback it was handed. The app hands it one that lands the
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

`tokens` / `cost` / `burn` are the day's own numbers — `Int`, `Decimal`, and an
optional rate in tokens per hour. They were pre-formatted strings until the
frame stopped being rendered into 128×64 pixels, and that shape is what made the
app carry a second set of formatters that had to be kept in step with the
engine's by hand. Rounding is now the surface's alone, in `UsageFormat`. `burn`
is `nil` on a day nothing has been spent on: a rate of zero is a claim about
pace rather than the absence of one.

`providers` carries the raw per-provider slices — tokens as `Int`, cost as
`Decimal` — so the header subtitle, the panel's per-provider rows and each
provider's gauges all derive from one payload instead of from two counts that
can disagree. Stable order: `claude-code`, `codex`, then alphabetical. A
provider that has spent nothing today keeps its slice: the slice is also what
carries the plan, the account, the credits and the rate-limit gauges, and
dropping it took a whole provider page off the panel until the next turn. A
provider that has not produced a reading at all has no slice, because no reading
is not a reading of zero. Everything on a slice besides the two totals and the
project split lives on one `ProviderSignals` value, published together so a row
cannot pair one moment's plan with another's windows.

`providers[].windows` carries that CLI's subscription rate-limit windows,
ordered shortest first here rather than by whichever producer filled them —
the panel dims every row after the leading one, so a weekly bucket a vendor
listed first would take the emphasis from the session one that binds sooner.
Each is identified by its `minutes` rather than by its position —
vendors do not agree on an order, and Codex's own `primary` bucket is not always
the session one. `usedPercent` is a percentage of the window's allowance; a
bucket whose reset has passed is dropped before the frame is built. Empty for a
provider that publishes no limits — an API-key user, or a CLI that has not
surfaced a window yet — which is what puts the panel row back on its
share-of-today bar.

`providerStatus` is what each vendor's own status page last said, keyed by
provider. It sits beside the slices rather than on one because a status belongs
to the vendor and not to the log tail: it is the same answer for every account
of that vendor, it costs the tail nothing, and it exists for a provider whose
cold scan has not finished. The age it carries is **Sissy's own fetch time** and
never the feed's `updated_at` — measured 2026-09-15, OpenAI's read `2026-07-09`,
because it moves on incidents rather than on polls. Empty while the readings are
switched off (`statusChecks` in `server.json`, on by default) and for a provider
with no feed to poll.

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

Claude Code's windows come from the credential the CLI is signed in with,
read from `<home>/.credentials.json` where there is one and from the login
keychain where there is not. **Neither costs a permission**, which is why there
is no switch in front of them: a keychain item's ACL names *applications*, and
Claude Code files its own item by shelling out to `security`, so
`/usr/bin/security` is the application on that list and Sissy is not. Reading
through that tool is silent; an in-process `SecItemCopyMatching` raises the
legacy Allow/Deny panel and earns a grant that dies at the next token refresh,
which is what the whole `allowingInteraction` apparatus used to exist for.
`ClaudeKeychainCLI` is that reader, and it grants Sissy nothing the user's own
shell does not already have.

An imported claude.ai session (`ClaudeWebSource`) runs beside it rather than
instead of it, and is the only reading left on a Mac nobody has signed the CLI
into. `ClaudeCodeSignals.merge` prefers whichever source has an actual reading,
asking the CLI's own credential first. Credits come from whichever source is
live; `ClaudeProfileSource` answers for them off the reply the CLI caches in
`.claude.json` when neither is, with no prompt and no network — and that cache
only advances when someone types `/usage`, so it is a fallback and never an
amendment to a live reading.

`ClaudeAccountRegistry` is the account half. It watches the credential the CLI
is signed in with, asks `api.anthropic.com/api/oauth/profile` whose it is
whenever it sees one it has not archived — a switch, a `/login`, or the CLI
rotating a token — and files a copy under that account's uuid in a keychain item
Sissy owns, with an index beside it holding identities and never a token. That
archive is what makes switching safe: the CLI's own slots are scratch, rewritten
with whichever account is active, so a switch that wrote them without an archive
destroyed the account it switched away from. Nothing here is attributed per
account — a log line carries no account id, so the spend is the CLI's.

`keepAwake` carries `{mode, active, since}` and is never optional, including when
off: the panel draws its control from this, and "off" and "nothing reported" must
not collapse into the same value. `mode` is where the user left the switch and
survives in `server.json` — `auto` is the one the agents drive, held while
turns are landing and released `KeepAwakePolicy.idleWindow` after they stop,
which is a thing no generic `caffeinate` can know. What counts as a turn
landing is an event a provider saw *after* its own cold scan finished: the
backfill streams its partial totals out so the panel counts up while it runs,
and reading growth instead took a hold on every launch that met a busy
morning. The window itself is measured from when the reading reached the
engine, not from the stamp on the log line, whose clock and precision belong
to the CLI that wrote it; `active` is whether the Mac is being held awake right
now; `since` is when the hold in force was taken, `nil` whenever nothing is held
and in memory only — a hold dies with the process, so a relaunch that resumes the
mode reports a fresh instant rather than the one from the run before. The panel
counts up from it on its own clock, which is why it is a `Date` and not a
duration: frames arrive when usage changes, not once a second. `coversScreen`
is whether the screen is being held lit alongside the Mac — the effect, where
`keepScreenAwake` in `server.json` is the setting, so a display assertion power
management refused stops the panel promising a screen that is already dimming.
`active` follows the system assertion alone, which is what that claim is about:
a refused display assertion leaves a Mac that stays up behind a screen that
dims, and says so in the log rather than retracting the hold that did take. A
system assertion that could not be taken drops the display one with it, so a
false `active` always means nothing is held.
The two come apart — power management can refuse an assertion — and the panel
renders them as two properties of one glyph, tint for the mode and fill for the
effect, so "switched on and holding nothing" is readable at a glance rather than
silent.

## Engine modules (`app/SissyCore/`)

Compiled into both targets. `main.swift` and `SelfTest.swift` are the tool's own
and excluded from the app; everything else is shared. A new file here is
compiled into the app too.

| File | Job |
|---|---|
| `UsageEngine.swift`             | Actor that owns the aggregator, the limits probe and the keep-awake hold; builds each frame and calls the callback it was handed |
| `UsageProvider.swift`           | Protocol shared by each provider (id, start/stop, current, isWarm, `currentSignals`) |
| `ProviderReadiness.swift`       | `ProviderID`, and how a toggle resolves (`on` / `off` / `auto — detected` / `auto — not found`) alongside each running provider's scan progress |
| `UsageAggregator.swift`         | Sums per-day totals across active providers and rebuilds the per-provider slices |
| `LocalUsageProvider.swift`      | The one tail behind both trees: enumeration, offsets, mtimes, FSEvents, the poll, the dedup ledger, day buckets, snapshot load/save, archive flush, emit throttle. Also `UsageEvent`, `SourceAdapter` and `SourceDescriptor` |
| `ClaudeCodeSource.swift`        | `ClaudeCodeAdapter`: `assistant` lines out of `~/.claude/projects/**/*.jsonl`, keyed by `requestId` — a repeat is the same answer still streaming, so it bills the growth in output and nothing else — priced against the Anthropic slice, with `cwd` resolved to a project; the plan and the probe's windows reach the provider as its `SourceSignals` |
| `CodexSource.swift`             | `CodexAdapter`: `token_count` events out of `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`), `last_token_usage` as per-turn delta, model from `turn_context.payload.model` (fallback `gpt-5-codex`); owns the resume block. Two of those events are not turns: one whose `total_token_usage` has not moved is the previous turn re-emitted, and a session whose `session_meta` names a parent opens with that parent's whole history stamped at its own start — both are dropped, and both keep their bookkeeping in the snapshot because a relaunch can land between a turn and its repeat |
| `UsageReaderShared.swift`       | Tuning constants the tail and its adapters share (`ingestChunkSize`, `pollEmitThrottle`, mtime slack), the token-count bound, and `parseTimestamp` — the one timestamp parser every source and the probe use |
| `UsageAtomics.swift`            | `LockedValue`, the one lock box a provider is read through from outside its actor; `ProviderSignals`, everything a source answers for besides its token totals, published as one value so a reader cannot pair fields from two moments; and `SourceSignals`, the nonisolated protocol the aggregator reads it through |
| `ProviderStatus.swift`          | `ProviderStatusIndicator` / `ProviderStatusComponent` / `ProviderStatusReading`, and `ProviderStatusFeed` — which page each vendor publishes and which of the two component shapes it answers in. Adding a provider's status is a line in that table |
| `StatuspageFeed.swift`          | Statuspage v2: `api/v2/status.json` for the sentence, `api/v2/summary.json` for the sentence and a flat component list in one request. Honours `only_show_if_degraded` and the vendor's own `position`, so the tree is a copy of the page rather than a re-ordering of it |
| `IncidentIOFeed.swift`          | incident.io's `proxy/<host>`, which is the only place OpenAI's components arrive grouped — its own Statuspage emulation drops eight of the 34, `CLI` among them, and folds the two `Login` rows into one. Anything absent from `affected_components` is operational; a group reports the worst of its children |
| `ProviderStatusMonitor.swift`   | Polls each metering vendor's status page — 5 min while agents are working, 30 min once nothing has been seen for an hour, jittered, 10 s timeout. A failed fetch publishes nothing, so the row keeps its last state and its age; a feed that has never answered says `unknown`, never an outage |
| `ClaudeLimitsProbe.swift`       | Polls Anthropic's OAuth usage endpoint for the 5-hour and weekly windows; 5-min refresh, 30-min backoff on 429. Its credential source is injected, so the same probe serves the file, the keychain and a test |
| `ClaudeKeychainCLI.swift`       | The login keychain through `/usr/bin/security`, which is the application Claude Code's own items trust — so no Allow/Deny panel and no grant that a re-signed build invalidates. Also the CLI's service-name rule: `Claude Code-credentials-<sha256(NFC(configDir))[:8]>`, unsuffixed for the default home |
| `ClaudeAccountStore.swift`      | Every Claude account Sissy has seen signed in: the credential in a keychain item Sissy owns, keyed by the account's uuid, and an index beside it holding identities and never a token. `ClaudeAccountProfile` is what turns a token into an identity |
| `ClaudeAccountRegistry.swift`   | Watches the credential the CLI is signed in with, archives every new one, and switches between them. The archive is what makes a switch safe: the CLI's slots are scratch and it rewrites them with whichever account is active |
| `ProviderAccounts.swift`        | `ProviderHome` — the one config home per vendor Sissy meters, and every path resolved from it, so a credential and a log tree can never be read out of two different places |
| `ClaudeCredentials.swift`       | `ClaudeCredentials` and the outcome of looking one up, plus the `SecItem` query `ClaudeWebSessionStore` reads Sissy's own item with. Never writes a credential and never refreshes one: Anthropic's refresh tokens rotate on use, so spending one would sign the user out of their own terminal |
| `ClaudeFileCredentials.swift`   | The credential beside the CLI's config (`<home>/.credentials.json`), and `ClaudeCodeCredentials`, which reads that file and falls back to the login keychain — the two places the signed-in token lives, in one order |
| `ClaudeProfile.swift`           | Reads the plan, the tier, the account and the vendor's own cached credits reply out of the CLI's own `.claude.json` (`CLAUDE_CONFIG_DIR` or `$HOME`); no keychain and no network. A cached reading carries the vendor's own `fetchedAt`, which the panel prints beside it |
| `ClaudeUsagePayload.swift`      | The one parser for the usage body Anthropic answers with, wherever it was read — the OAuth endpoint, claude.ai, or the CLI's cached copy of one. Measured to be the same object in all three, so there is no second reading of `spend` to drift |
| `ClaudeWebCookieImport.swift`   | Reads the `sessionKey` out of Claude.app's Chromium cookie store: `Claude Safe Storage` from the keychain, PBKDF2-SHA1 + AES-128-CBC, `v10` prefix and the 32-byte domain-binding hash stripped. Only ever from the button — Claude.app is the source rather than a browser because that is where a live session is, and its key has not been rewritten since 2024 |
| `ClaudeWebSessionStore.swift`   | The imported session, in a keychain item Sissy owns and nothing else rewrites. Presence is asked without decrypting, so Settings answers on a build whose grant lapsed. Keyed by account, so more than one is a stored row rather than a rewrite |
| `ClaudeWebSource.swift`         | Polls `claude.ai/api/organizations/{org}/usage` for the windows and the credits; same 5-min refresh and 30-min 429 backoff as the OAuth probe. The subscription organization is the one whose `capabilities` name `chat`, and the request needs a `Claude/<version>` User-Agent — both measured |
| `CodexAuth.swift`               | Reads the plan and the account out of the id_token in `~/.codex/auth.json`, for the boot before the first turn. The signature is deliberately not verified — every field taken is a display string off the user's own disk — and the tokens beside them are never read. Also says which of "signed out", "absent" and "will not parse" a read met, because only the first two are a reason to blank the row, plus a digest of the identity claims so a later read can tell one account from the next |
| `FSWatcher.swift`               | Wraps `FSEventStreamCreate` (CoreServices); drives per-provider reader wakes |
| `FrameBuilder.swift`            | `FrameData` / `ProviderSlice` / `UsageWindow` / `ProviderAccount` / `ProviderCredits`, the burn rate, and the slice and project ordering. No formatters: the frame carries raw numbers and the app words them |
| `KeepAwake.swift`               | Actor owning the `PreventUserIdleSystemSleep` assertion and, when `keepScreenAwake` asks for it, the `PreventUserIdleDisplaySleep` one, plus `KeepAwakeMode` / `KeepAwakeState` / `KeepAwakeHold` / `KeepAwakePolicy`; the mode and the screen setting persist in `server.json`, the assertions die with the process |
| `Pricing.swift`                 | Anthropic cost math, `ModelPricing`, `PricingTable`; no rate table of its own |
| `OpenAIPricing.swift`           | OpenAI cost math, same override → catalog → seed precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM rates at runtime; renders the seed for `--dump-seed` |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — offline / first-run floor |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`; carries `providers` toggles, `codexDataDir`, `remotePricing`, `statusChecks`, `historyRetentionDays`, `keepAwake`, `keepScreenAwake`, `agentHooks` and `agentHooksRemovalPending` — the last written before either CLI's configuration is touched, so a removal the user asked for is retried at the next launch instead of being forgotten under a switch that is already off. The engine owns the file, and saves it through a staging file so it is owner-only before it answers to its own name |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); Claude Code stays on the legacy `usage-state.json` for upgrade smoothness. The snapshots sit beside the `server.json` that named the trees they were read from, so a config pointed elsewhere — `--config`, a test — takes its reading with it. Carries two optional blocks, `historyResume` (the archive's per-model split) and `codexResume`, plus `projectCheckouts`, which is read on load and never written again — an install that predates `ProjectLedger` hands its memory over that way |
| `UsageHistory.swift`            | The archive: one directory per provider under `history/`, one whole-file JSON per local day, a row per model per project. Versioned apart from the snapshot so a schema bump cannot delete it, rewritten whole so a re-derived day replaces rather than doubles, pruned to `historyRetentionDays` across every provider directory — the engine's call, since a provider that is off has no tail to make it |
| `AgentHookInstaller.swift`      | Registers Sissy's `SessionStart` entry with `~/.claude/settings.json` and `~/.codex/hooks.json`, and takes it back out. Off unless the user asks. The path in the command is quoted for `sh` and the result passes `sh -n` before it is written; the home it is built from is `getpwuid`'s, not `NSHomeDirectory()`'s, which follows `CFFIXED_USER_HOME`. A file that will not parse is left untouched, a symlinked target keeps its link, the file's own mode is preserved, and the write is abandoned if the file moved between the read and the rename |
| `ProjectResolver.swift`         | Which project a working directory belongs to: up to the first `.git`, and through a worktree's `gitdir:` pointer to the checkout it was cut from, so one repository is one row wherever the work ran. Cached per directory, one cache per provider. A walk that names no repository answers nothing rather than inventing a project out of the path; a walk that fails falls through to the ledger |
| `ProjectLedger.swift`           | What Sissy has read about checkouts, in its own file with its own schema so no snapshot bump can take it: which directory was a checkout of which repository, which is the only thing that can still answer for one that has been deleted. One ledger for every provider. Learns from git as well as from log lines — landing on a repository reads the worktree list git keeps in `.git/worktrees/`, so a worktree is answered for while it is alive rather than looked up once it is gone. Also takes in the `checkout-inbox` a CLI session leaves, read as a boundary — `O_NOFOLLOW`, a regular file this user owns, size-capped, two absolute lines — and `adopt`ed behind what Sissy walked to itself; an entry is consumed on read, which is what bounds the directory |
| `SissyPaths.swift`              | Support-dir and logs-dir resolution (`.dev` bundle id → dev tree) |
| `SissyLog.swift`                | `sissyLog`, stderr plus `Library/Logs/Sissy/sissy.err.log`, capped as it is written (one generation kept); every message is escaped to a single line, because some carry text the CLIs wrote |
| `main.swift`                    | The tool's entry point: `--self-test` / `--scan` / `--scan-provider` / `--config` / `--dump-seed` / `--refresh-catalog`. No flag prints the list and exits 2 |
| `SelfTest.swift`                | The `--self-test` harness: pure formatter, pricing, parser and persistence assertions, run in CI |

Each active provider's initial JSONL backfill finishes in a detached task, so the
app is interactive immediately even on a multi-GB history.
Steady-state CPU is near zero: provider-specific `FSEventStream`s (rooted at
`~/.claude/projects` and `~/.codex/sessions`) wake their providers only when JSONL
actually changes (kernel-coalesced events at ~1 s latency). A low-frequency
safety-net poll (default 60 s, `server.json.pollIntervalSeconds`) catches
missed-event flags (`MustScanSubDirs` / `UserDropped` / `KernelDropped`) and the
midnight day rollover when no JSONL activity straddles the boundary. Claude Code
entries are deduplicated by `requestId` because Claude Code logs each assistant
turn 2-3 times as the message streams; Codex turns are deduplicated implicitly
because `last_token_usage` arrives once per turn.

Each provider retains a 2-day window on disk (today + yesterday). The frame
surfaces today alone; yesterday is retained because the minutes after midnight
are full of lines stamped for the day before, and a bucket that had already been
dropped would bill them to today and hand the archive a day it never metered. Cold scans skip every file with
`mtime < now-48h`, which on real-world trees (~500 MB across hundreds of
projects) parses ~10-20% of the bytes and finishes in low seconds. Bumping this
requires every consumer of `dailyTotals` to actually use the extra history; today
nothing does.

## The app (`app/Sissy/`)

Menu-bar only (`LSUIElement: true`), sandbox disabled. Three surfaces and no
windows of its own: a left-click usage panel (`Panel/`, an `NSPopover`), a short
right-click `NSMenu` (`Menu/StatusItemController.swift`), and the SwiftUI
`Settings` scene (`Settings/`, tabs General/Providers/About) — reachable from the app menu's
Settings… item (⌘,) and, in code, only through `SettingsLink`, which takes no
action closure and is why the panel's own settings button aims the window at a
tab through `SissyModel.settingsTab`.

**The panel is two surfaces behind one popover.** `Panel/PanelOverview.swift`
answers what today costs and whether there is room to keep working — the day's
cost, one headroom gauge, the split by provider as a single stacked bar, the
projects, the archive line. `Panel/PanelProviderPage.swift` answers what one
account is doing: its windows, who it is signed in as, its own day and its own
projects, and the refresh, which is a different action on each provider.
`UsagePanelView` is the shell around them — a contextual header and a `switch`
on the open page — and that `switch` is the whole implementation of the
rule that only the selected page exists. There is no footer: the age of the
reading sits under the header's title, where it dates the numbers beside it,
and the way into Settings sits beside the keep-awake switch, which is where the
app's own controls live. A `TabView` would hold every page's
view graph live, which is precisely the cost `UsagePanelController` drops its
host on close to avoid. `Panel/PanelComponents.swift` holds what both pages
draw, so a bar or a badge cannot drift a point between them.

The one gauge the Overview leads on is the window with the *least* headroom
across every provider, ties going to the shorter window. A session bucket with
room left says nothing while the weekly one behind it is nearly spent, so a
headline led by the roomier of the two would be reassuring and wrong. It is read
off the provider rows rather than off the slices, so the Overview's gauge and
the same gauge repeated on that provider's page are one object down to the pace.

`Models/Preferences.swift` holds only what the app itself remembers
(`sissyMotion`, `retiredServerAgent`) in `preferences.json`. Everything about
metering lives in `server.json`, which the engine owns — the app reads every
such setting back from the engine rather than keeping a copy, because the copy
it used to keep could disagree with the file the readers actually booted from.

**Three readiness states, not one blank panel.** `HeaderSnapshot.make` is a pure
function of `(hasFrame, isWarm, filesWatched)`, which is what the tests target.
Both scalars are folded from `UsageEngineHost.providers`, the per-provider list
the Providers tab renders, so the header cannot disagree with the page that
explains it:

| | Header |
|---|---|
| a frame has landed | Sissy, awake |
| no frame, readers still scanning | "Sissy is waking up" / "Reading your session logs" |
| warm, no files watched | "Sissy is sleeping" / "No session logs found" |
| warm, files watched, nothing today | "Sissy is sleeping" / "Nothing spent yet today" |

The last is the common one first thing in the morning and the only one of the
three that is not a fault. A single "waiting" line sent people hunting for one.

**The Providers tab answers "why is this CLI not in my panel".** A row carries the
resolved activation and, for a provider that is metering, what its scan found —
and the two ways to find nothing are kept apart, because a data dir that is not
there is a different problem from one that is there and empty. Both name the path.
`ProviderRowSnapshot.make` is the pure function the tests target, as
`HeaderSnapshot.make` is for the header. "Show Claude Code limits" lives on the
Claude Code row: it is a property of that provider and reads as one beside that
provider's state. Its caption is split — what the switch shows and that macOS
will ask stay on screen, because a permission prompt the app did not warn about
is what Sissy's first-run promise exists to avoid; the read-only guarantee and
the expect-it-again-after-an-update note sit behind an `info.circle` popover. A
button rather than a `help` tooltip, which only a hovering pointer ever finds.

There is no on/off switch on the page yet — turning a provider off at runtime
means stopping a live tail, and turning it back on means building a new one: a
provider that has stopped stays stopped, the same rule the engine follows. A row
that is off therefore says where the switch that turned it off lives.

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

**Quitting is the only thing that ends a run**, so it is the readers' one chance
to write their offsets. `applicationShouldTerminate` answers `.terminateLater`,
awaits `UsageEngine.stop()` and only then releases the quit — bounded by
`AppDelegate.teardownBudget`, because a teardown that will not finish must not
leave a menu bar app that refuses to quit. Missing the flush costs a few
re-parsed lines that dedup absorbs; refusing to quit costs a Force Quit.

An engine runs once: `UsageEngine.lifecycle` goes `idle → running → stopped` and
`stopped` is terminal. `start()` re-reads it after every suspension, because
`stop()` can land inside one of them — it used to be overtaken by the rest of
`start()`, which would boot the aggregator and the pricing refresh against an
engine already torn down, with no handle left to cancel either. The app builds a
fresh engine when it needs one, so reviving a stopped instance would only ever
mean two of them metering the same trees.

Each provider carries the same three states for the same reason, one level down.
`UsageEngine.stop()` cancels the boot task and then stops every provider, so both
arrive while a cold scan may still be walking a tree — and a scan is nothing but
suspensions, one per `Task.yield()` and one per emit. `LocalUsageProvider.start()`
re-reads `lifecycle` (and `Task.isCancelled`) after the scan rather than taking it
for a complete pass: resuming past that point used to expose a half-built `prev`
and arm an FSEvents stream plus a 60 s loop that the teardown had no handle left
to cancel. The same read is what answers an FSEvents batch that was already in
flight when the watcher was released — one carrying `rootChanged` would otherwise
build a fresh stream after shutdown — and what makes a `stop()` actually interrupt
a cold scan instead of only a cancelled boot task doing so.

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
- **Permissions**: first run asks for nothing, and nothing Sissy does on its own
  asks later either. Claude's limits used to sit behind a switch because reading
  the credential in-process raised a keychain dialog; reading it through
  `/usr/bin/security` does not, so the switch is gone rather than defaulted off.
  The one gesture that can still raise a dialog is the claude.ai import, which is
  a button and says what it does before it is pressed.
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
