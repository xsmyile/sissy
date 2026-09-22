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
the panel lifts the one window a provider leads on, so a weekly bucket a vendor
listed first would take the emphasis from the session one that binds sooner.
Each is identified by its `minutes` rather than by its position —
vendors do not agree on an order, and Codex's own `primary` bucket is not always
the session one. `usedPercent` is a percentage of the window's allowance. A
bucket whose reset has passed keeps its row and loses its figure: the panel
draws a dash where the percentage was and no bar at all, because every source
is between two readings most of the time, and dropping the window took the row
off the page between a reset and the next one. Empty for a
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

`forge` is what each connected git forge last answered: one row per connection,
carrying the login the token turned out to belong to and four counters per
period — the vendor's own activity total, the pull or merge requests that account
had merged, the issues it opened, and the comments it wrote. It sits beside the
slices for the reason `providerStatus` does and one more: a forge is not a
metering provider, nothing on it is a token or a cost, and a connection exists on
a Mac where neither CLI has ever run. Empty until the user connects one, which is
also the module's only switch.

**The counters are never summed across forges.** GitHub answers with its own
contribution-graph total — measured 2026-09-17, 128 on a day whose itemised
commits, issues and pull requests came to 56, the other 72 being
`restrictedContributionsCount`, the private work the breakdown will not name —
and GitLab publishes no equivalent Sissy can read: `users/<name>/calendar.json`
answered 200 with `{}` on a self-hosted 19.3 instance with a valid token, so the
figure there is the count of events GitLab recorded, taken from the `x-total`
header of `/api/v4/events` with one row requested. Two vendors counting two
things is two readings; adding them would invent a third belonging to neither,
which is the rule `ProviderCredits` already holds for money in two currencies.

**The comment counter is the one neither vendor will total, and the two stand in
opposite relations to the figure beside them.** GitLab files a comment as an
event, so it is the same `x-total` header read with `action=commented` on it and
therefore a *part of* the contributions next to it — measured 2026-09-18, 14 of
one week's 525 events and 62 of the month's 1 036. GitHub counts no comment as a
contribution at all: measured the same day, 2026-08-07 read 14 contributions
against a breakdown of 14 commits and nothing else on a day that carried a
comment, so there the figure is disjoint from its neighbour. It also publishes no
count of it — across all 1 829 types of the live schema, 18 fields return a
comment connection and **none** takes a date, the four rooted on `User` offering
only `orderBy` and paging — and the search that looks like the answer counts
*threads* dated by the thread's own update, reading 35 and 53 against the 44 and
71 actually written. So GitHub's counter is cut out of one page of the account's
own comments instead, and **that page carries its own proof of coverage**: nodes
come back newest-updated first and nothing can be created after it was updated,
so once the oldest `updatedAt` on the page precedes a window's start, nothing
unread can fall inside it. A window the page cannot prove is absent rather than a
lower bound, which is why a GitHub comment count can go missing while the three
beside it answer. Measured 2026-09-18 on an account holding 133 comments: one
page answered 0/44/71 against the 0/44/71 that reading all 133 gives, filling 71
of its 100 rows, and the document it rides in still costs 1 point of 5000/h. On
the widest window GitHub's contributions reach back a year where the counts
beside them reach back for ever, which the row says on the hover rather than
quietly averaging away.

**Every window is a whole day in the forge's own calendar, never an instant.**
Both vendors bucket by UTC days and neither takes a finer filter: measured
2026-09-17 from Europe/Rome, a local midnight rendered as the instant it is
(`2026-09-16T22:00:00Z`) made GitHub's calendar snap down to the start of that
UTC day and answer 326 where the profile's own square for the 17th read 128, and
773 over seven days where the seven squares came to 704 — the error being worth
whatever the extra day held, which is why it was invisible at 30 days (0 on
2026-08-18) and not at 7 (69 on 2026-09-10). So a window is named by its date at
midnight `Z`, and the two filters that *are* instants — GitHub's `merged:>=`
qualifier and GitLab's `mergedAfter` — take the same form rather than sitting on
a window two hours wider than the contributions beside them: measured the same
day, 156 merges against the 155 inside the seven UTC days the contribution figure
is over. The row therefore answers the same squares the user is reading on the
heatmap, and the residual nothing can close is a GitLab whose instance timezone
differs from the profile's, since `after` on the events endpoint takes a date and
applies it in the instance's.

**Three of the four counters have a switch, and it decides what is read rather
than only what is drawn.** `ForgeCounters` in `server.json` carries one optional
flag each for the merged, issue and comment counts — `nil` meaning on, as
`ProviderToggles` means it — and the monitor is *built* with the enabled set, so
switching one off takes its fields out of the document GitHub is sent and its
four header reads off GitLab's poll, taking that from ten requests to six. The
contribution total has none: it is what the section is called, so a row with it
off would be a heading with nothing under it. A counter switched off therefore
reaches the panel as an absent period, which is the same shape a counter the
vendor would not answer arrives in — the row already draws that by leaving the
figure out. Changing one rebuilds the poll the way connecting a forge does,
which costs a round rather than a wait: a fresh monitor asks at once, so a
counter switched back on is a request away rather than an interval away.

**Every forge row is dated, and the row is where it is re-read from.** The poll
runs on a five- to thirty-minute cadence and these counters move the instant the
user pushes, so a figure with no date beside it cannot be told from one taken
before the merge they are looking for — measured 2026-09-18, a merge an hour old
against a row that said nothing about its own age. The caption therefore carries
`read 12m ago` on a healthy row and `could not be reached · last read 2h ago` on
a failed one, both halves rather than the age alone: the age stood in for the
failure only while a healthy row was silent. It is worded from `ForgeRow.readAt`
on a `TimelineView` in the view, never pre-built into the snapshot, because this
block's frame arrives once a cadence — `StatusRow.checkedAt` is the same shape
for the same reason. A row that has never once answered carries no date at all
and prints its reason by itself: `ForgeActivityReading.unavailable` stamps the
*attempt*, and re-stamps it every round, so `hasEverRead` is what the row asks.
Printing the age only past some staleness was the other wording and it has no
honest threshold: the interval is chosen after each round, with jitter, and the
loop keeps it to itself.

The re-read is a **right-click on the row**, named in the hover the way the
keep-awake control names its own, because 340 pt already has the login
truncating before the figures do. Three things about it are settled. It
**joins** a fetch already in flight rather than opening a second — actor
isolation orders the writes and not the results, so a round that started first
and answered slowly would otherwise put its older figures back over a refresh
the user had just watched land. It **reaches a parked connection**, which is
the point: a refused token is otherwise never asked again until the host is
connected a second time, however transient the refusal was; a success unparks,
a refusal that still stands keeps the parking, and a *retryable* answer unparks
too, because a click made off the VPN must not strand the connection on the one
reading nobody can act on. And it leaves the loop's own sleep alone — resetting
it would postpone every other connection to pay for this one. Making the gesture
reachable is also what made GitHub's secondary rate limit worth telling apart:
it answers `403` with a retry deadline and an untouched quota, which read as a
refused token and parked a connection that would have answered on the next poll.

**The poll's own wait is capped at local midnight, and a reading from before it
loses its figures.** Every window is worked out from the instant the vendor was
asked, so a round at 23:50 answers `Today` for the day that is ending; on the
idle cadence that figure would stand under a heading naming the new day for the
next half hour. The cap costs one extra round, on a day whose wait would have
crossed the boundary and on no other. The cap alone is not the whole answer,
because a Mac asleep or offline across midnight wakes with a reading from
yesterday either way — so `makeForge` drops that reading's `Today` figures and
the row falls to the dash, which is the roll-over rule the rate-limit windows
are already on. It **outranks** the rule that a failed reading keeps its
figures: those are stale within a day, and yesterday's numbers under today's
heading are wrong whether or not the last attempt worked. Only `Today` goes,
because only `Today` has *ended* — seven days ending yesterday still covers six
of the seven, thirty covers twenty-nine, and `all` has no start to move at all.
The wider windows are stale rather than wrong, which is what the age on the row
reports, and blanking them would throw away a reading the user can discount.

**And the wait is taken in slices, because the cadence is chosen before the work
starts.** `nextDelay` reads `lastActivity` when a round *finishes*, so a Mac that
was idle then and has agents working a minute later would keep the 30-minute
interval for the rest of that wait — up to half an hour of the idle cadence
running over exactly the stretch the 5-minute one exists for, which is also the
stretch where these counters actually move. `noteActivity` cannot wake a sleeping
loop: it is nonisolated and written from the frame path, which cannot afford to
await the actor. So the wait sleeps in `activityCheck` slices and `waitIsOver`
decides at each one — the delay is the ceiling, and a wait that has already
covered `refreshInterval` ends as soon as agents are working. A slice costs a
timer and no request.

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
| `LocalUsageProvider.swift`      | The one tail behind both trees: enumeration, offsets, mtimes, FSEvents, the poll, the dedup ledger, day buckets, snapshot load/save, archive flush, emit throttle. Four grains are republished on every emit for the aggregator to read without an actor hop: the project split, the model split, the agent counts and the working shape. Also `UsageEvent`, `SourceAdapter` and `SourceDescriptor`. Built with a `backfill` range instead, the same type is the archive backfill: it counts that fixed range rather than the rolling window, is driven by `backfillArchive()` rather than `start()`, writes day files and nothing else, and refuses a day holding a model no rate covers |
| `ClaudeCodeSource.swift`        | `ClaudeCodeAdapter`: `assistant` lines out of `~/.claude/projects/**/*.jsonl`, keyed by `requestId` — a repeat is the same answer still streaming, so it bills the growth in output and nothing else — priced against the Anthropic slice, with `cwd` resolved to a project; the plan and the probe's windows reach the provider as its `SourceSignals` |
| `CodexSource.swift`             | `CodexAdapter`: `token_count` events out of `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`), `last_token_usage` as per-turn delta, model from `turn_context.payload.model` (fallback `gpt-5-codex`); owns the resume block. Two of those events are not turns: one whose `total_token_usage` has not moved is the previous turn re-emitted, and a session whose `session_meta` names a parent opens with that parent's whole history stamped at its own start — both are dropped, and both keep their bookkeeping in the snapshot because a relaunch can land between a turn and its repeat |
| `UsageReaderShared.swift`       | Tuning constants the tail and its adapters share (`ingestChunkSize`, `pollEmitThrottle`, mtime slack), the token-count bound, and `parseTimestamp` — the one timestamp parser every source and the probe use |
| `UsageAtomics.swift`            | `LockedValue`, the one lock box a provider is read through from outside its actor; `ProviderSignals`, everything a source answers for besides its token totals, published as one value so a reader cannot pair fields from two moments; and `SourceSignals`, the nonisolated protocol the aggregator reads it through |
| `ProviderStatus.swift`          | `ProviderStatusIndicator` / `ProviderStatusComponent` / `ProviderStatusReading`, and `ProviderStatusFeed` — which page each vendor publishes and which of the two component shapes it answers in. Adding a provider's status is a line in that table |
| `StatuspageFeed.swift`          | Statuspage v2: `api/v2/status.json` for the sentence, `api/v2/summary.json` for the sentence and a flat component list in one request. Honours `only_show_if_degraded` and the vendor's own `position`, so the tree is a copy of the page rather than a re-ordering of it |
| `IncidentIOFeed.swift`          | incident.io's `proxy/<host>`, which is the only place OpenAI's components arrive grouped — its own Statuspage emulation drops eight of the 34, `CLI` among them, and folds the two `Login` rows into one. Anything absent from `affected_components` is operational; a group reports the worst of its children |
| `ProviderStatusMonitor.swift`   | Polls each metering vendor's status page — 5 min while agents are working, 30 min once nothing has been seen for an hour, jittered, 10 s timeout. A failed fetch publishes nothing, so the row keeps its last state and its age; a feed that has never answered says `unknown`, never an outage |
| `GitIdentity.swift`             | What a repository would sign a commit as, and the rule that judges it: `GitAuthor`, `GitConfigOrigin`, `GitIdentityReading`, `GitIdentityVerdict`, `RepositoryIdentity`, and `GitIdentityConsensus`, which takes the strict majority of each **account on a forge** rather than of the forge — one host holding a personal and an employer organisation would otherwise outvote the smaller one and flag a correct setup — falling back to the host only where every repository on it agrees, which is what judges the first repository seen under a new account. An electorate is judged as a whole rather than each repository against its own neighbours: one wrong repository among eight right ones otherwise left all eight unjudged. Two agreeing repositories are an expectation; one, or a tie, is none |
| `GitIdentityReader.swift`       | Asks git itself who would sign a commit: `rev-parse` proves the path is a repository (`config` and `var` both answer from the global config with none), `config --show-origin --show-scope` names the file a correction has to be made in, and `var GIT_AUTHOR_IDENT` resolves what it is. `var` is never asked *whether* an identity exists: with no `user.email` set it invents one from the gecos field and the hostname, and whether it refuses its own guess depends on the machine — measured, a hostname yielding no domain exits 128 where a CI runner's `.local` one was served an address nobody owns. Runs no hooks, takes no locks, writes nothing, and builds its environment rather than inheriting it, so an ambient `GIT_DIR` or `GIT_AUTHOR_EMAIL` cannot reach the reading. Finds a real `git` before `/usr/bin/git`, which is a Command Line Tools shim that opens a system dialog on a Mac without them |
| `AgentActivity.swift`           | What a log line says happened besides spending tokens: a session somebody started, or an agent that session spawned. Two counters rather than one, because they answer two questions and their sum answers neither — measured 2026-09-18 over 30 days, 442 sessions spawned 189 agents. `AgentActivityKey` namespaces the dedup keys away from the token keys sharing the ledger with them, which is what makes a count survive a streamed turn's four copies and a relaunch between them |
| `ActivityMinutes.swift`         | How long a day was worked, as the minutes of it a turn landed in. **A bitmap rather than a list of intervals**, because the tail reads files newest first and a day's turns therefore arrive out of order: a set is order-independent and idempotent, which is what a day the archive rewrites whole needs. The minute is the grain the reading is *defined* at — measured 2026-09-19 over 12 days, it lands within a median of 7 minutes of summing the exact gaps, about 1%, for 188 bytes a day against 80 KB of instants. `AgentActivityDay` pairs it with the sub-agents' own minutes and applies the same block rule to both, and its `union` is why a window is not a sum: Codex runs almost entirely inside the minutes Claude Code is already working in, so a day that added the two rows read 12h40 against a real 11h15 |
| `TurnEffort.swift`              | At what effort each model's turns ran: `EffortKey` is the `(model, effort)` pair, `EffortTotals` the turns and the four token counters and the cost behind it. Both CLIs write the word on a line the tail already parses — Claude Code at the top level of the assistant line it bills, Codex on the `turn_context` payload it names the model in — so it costs no new read. `perTurnEffort` is the field that looks right and is not: measured 2026-09-22, null on 3096 of 3106 assistant lines where `effort` was set on all of them. The pair rather than a third key on `UsageHistoryRow`, which would freeze every re-derived day on `isCoveredBy` and cost `models × projects × efforts` where this costs `models × efforts`. The word is the vendor's, unmapped — measured 2026-09-22, Claude Code wrote `xhigh`, `high`, `medium`, `low` and Codex `ultra`, `xhigh`, `high`, `medium`, and neither publishes what its ladder means against the other's, which is why a provider's page reads this and nothing sums two |
| `AgentProcesses.swift`          | Reads the agent processes belonging to this user out of the kernel, with what each holds and what its whole tree holds — measured 2026-09-18, 1.94 GB against 4.88 GB, which is why both are carried. Needs no permission: `KERN_PROC_ALL`, `proc_pidpath` and `proc_pid_rusage` all answer for a same-uid process with no entitlement and no prompt, zero refusals across 665 processes. **Identity is the executable's path**, because Claude Code's native build names its executable after the version and the kernel therefore reports `2.1.277` as the process name; `argv[0]` is read only for the handful of processes running under a JS interpreter, since reading it for all of them costs 19.3 ms against 1.2 ms |
| `AgentProcessMonitor.swift`     | Samples that reading every 15 s and keeps an hour of it, per agent, for the chart. In memory and nowhere else — a reading from a Mac that was asleep is no reading, so the series starts when Sissy does and the panel says so. Samples whether or not the panel is open, which the *surface that is not on screen costs nothing* rule permits: that rule is about retained view graphs, and a sweep is 1.2 ms. A Mac already known to be quiet costs no frame; the first sweep always does, because that is the step from having no reading to having one |
| `GitIdentityMonitor.swift`      | Sweeps every repository the ledger names — 10 min while agents are working, an hour once nothing has been seen for one, 30 s budget for the whole round — and publishes the judged readings for the frame. Needs no scan, no configured folder and no permission: the ledger is what the tail already filled. Reads off the cooperative pool, because a `Process` read to end of file blocks. **A repository whose files have not been written since the last round keeps that round's reading**: a process costs ~67 ms whatever it runs — measured 2026-09-17, `/usr/bin/true` costs the same — so 23 repositories cost 5.82 s cold and 0.01 s at rest. `stop` drops what it published, so a warning cannot outlive the engine that took it |
| `ClaudeLimitsProbe.swift`       | Polls Anthropic's OAuth usage endpoint for every window `limits[]` names — the plan-wide 5-hour and weekly buckets, plus a model-scoped weekly on a plan that meters one separately, which the flat keys do not carry; 5-min refresh, 30-min backoff on 429. Its credential source is injected, so the same probe serves the file, the keychain and a test |
| `UsageRequestError.swift`       | What a vendor answers a *limits* reader with instead of a reading — `rateLimited(retryAfter:)`, `badStatus`, `malformedPayload` — shared by the three of them (the CLI credential against `api.anthropic.com`, the claude.ai session, the Codex credential against `chatgpt.com`) because they all refuse in HTTP's vocabulary. The status and forge feeds have error types of their own. Also `backoffSeconds`, which floors a 429 at the poll interval and caps it at an hour, the header being foreign input |
| `LimitsBackoff.swift`           | `LimitsBackoffLedger` (`limits-backoff.json`): when each limits reader may ask again, across runs. A refusal belongs to a credential rather than to a reader, so a relaunch, a provider switched off and on, and every build of a dev loop stop spending a request the vendor has already refused. Its own file, not `server.json`, whose writes these reader actors would race |
| `ClaudeKeychainCLI.swift`       | The login keychain through `/usr/bin/security`, which is the application Claude Code's own items trust — so no Allow/Deny panel and no grant that a re-signed build invalidates. Also the CLI's service-name rule: `Claude Code-credentials-<sha256(NFC(configDir))[:8]>`, unsuffixed for the default home |
| `ClaudeAccountStore.swift`      | Every Claude account Sissy has seen signed in: the credential in a keychain item Sissy owns, keyed by the account's uuid, and an index beside it holding identities and never a token. `ClaudeAccountProfile` turns an OAuth token into an identity and `ClaudeWebAccountProfile` turns a claude.ai reply into the same one — measured, both vendors name an account with one uuid, so a session and a credential file under one key |
| `ClaudeAccountRegistry.swift`   | Watches the credential the CLI is signed in with, archives every new one, and switches between them. The archive is what makes a switch safe: the CLI's slots are scratch and it rewrites them with whichever account is active |
| `ProviderAccounts.swift`        | `ProviderHome` — the one config home per vendor Sissy meters, and every path resolved from it, so a credential and a log tree can never be read out of two different places |
| `ClaudeCredentials.swift`       | `ClaudeCredentials` and the outcome of looking one up, plus the `SecItem` query `ClaudeWebSessionStore` reads Sissy's own item with. Never writes a credential and never refreshes one: Anthropic's refresh tokens rotate on use, so spending one would sign the user out of their own terminal |
| `ClaudeFileCredentials.swift`   | The credential beside the CLI's config (`<home>/.credentials.json`), and `ClaudeCodeCredentials`, which reads that file and falls back to the login keychain — the two places the signed-in token lives, in one order |
| `ClaudeProfile.swift`           | Reads the plan, the tier, the account and the vendor's own cached credits reply out of the CLI's own `.claude.json` (`CLAUDE_CONFIG_DIR` or `$HOME`); no keychain and no network. A cached reading carries the vendor's own `fetchedAt`, which the panel prints beside it |
| `ClaudeUsagePayload.swift`      | The one parser for the usage body Anthropic answers with, wherever it was read — the OAuth endpoint, claude.ai, or the CLI's cached copy of one. Measured to be the same object in all three, so there is no second reading of `spend` to drift |
| `ClaudeWebSessionStore.swift`   | The imported session, in a keychain item Sissy owns and nothing else rewrites. Presence is asked without decrypting, so Settings answers on a build whose grant lapsed. Keyed by account, so more than one is a stored row rather than a rewrite |
| `ClaudeWebSource.swift`         | Polls `claude.ai/api/organizations/{org}/usage` for the windows and the credits; same 5-min refresh and 30-min 429 backoff as the OAuth probe. The subscription organization is the one whose `capabilities` name `chat`, and the request needs a `Claude/<version>` User-Agent — both measured |
| `ClaudeWebAccountLink.swift`    | Turns a claude.ai session into a linked account, by asking claude.ai the two things nothing local can answer: whose session it is, and which of that account's organisations it is read for. One `chat` organisation links outright and the user is asked nothing; several hold the session in the engine, unwritten, until they answer — a link half-written is worse than a login to make again. The choice is labelled by plan rather than by name, because claude.ai auto-generates the personal organisation's name in at least two shapes (measured 2026-09-16 on two accounts) and a regex over vendor English picks wrong |
| `ClaudeWebSessionIndex.swift`   | `claude-web-sessions.json`: the identity and the chosen organisation beside the session the keychain holds, neither derivable when it is needed — an account reached through a session alone has no archived CLI credential, and membership order is the server's. Written after the session and best-effort, so a session with no entry is a state the ordinary path produces; `ClaudeWebAccount.list` is therefore driven by the stored sessions and this file only names them. An adopted session records an identity and no organisation, because nobody was asked |
| `ClaudeWebSessionAdoption.swift`| Re-files the single session an older install imported under a fixed name, under the Anthropic account uuid it belongs to. The old item names no account and nothing on this Mac can say which, so the pass costs one request rather than a rename; a session claude.ai will not identify is left exactly where it is and the next launch tries again |
| `CodexAuth.swift`               | Reads the plan and the account out of the id_token in `~/.codex/auth.json`, for the boot before the first turn, and — through `credential` — the tokens beside them, for the one reader allowed to spend them. The signature is deliberately not verified; every claim taken is a display string off the user's own disk. The refresh token is dropped unless the caller owns what it is reading, which is what makes "Sissy never renews the CLI's credential" a property of the value. Also says which of "signed out", "absent" and "will not parse" a read met, because only the first two are a reason to blank the row, plus a digest of the identity claims so a later read can tell one account from the next |
| `CodexCredentials.swift`        | `CodexCredential` and what one read of it found. Three absences that are three different sentences — no Codex at all, an account signed out of it, and a credential this build is not currently allowed to read — because folding them together sends a user to sign in somewhere they already are |
| `CodexUsagePayload.swift`       | The one parser for `wham/usage`: the windows in seconds rather than minutes, the plan, the account, and the credits through `CodexAdapter.credits`, which is the same block the rollout carries. A window whose length is not whole minutes is dropped rather than rounded into a period the vendor never named |
| `CodexUsageSource.swift`        | Polls `chatgpt.com/backend-api/wham/usage` with one account's credential; same 5-min refresh and 429 backoff as the Claude readers. One reader per credential, the CLI's own built with no account of its own. An expired token keeps the previous reading rather than blanking it — something else renews it — and a 401 says so on the row while leaving the windows, which the turns are still writing |
| `CodexSignals.swift`            | Merges the tail's reading and the readers' by **stamp**: the later wins, so a poll beats the last turn and a stopped reader hands the row back to the turns. Builds the per-account list, and answers the row from a lone linked account where the CLI is signed out — more than one and there is a choice to get wrong |
| `CodexAccountStore.swift`       | A linked Codex account's credential, in a keychain item Sissy owns (`com.radonforge.sissy.codex-oauth`), written in `auth.json`'s own shape so one parser reads both. Owns the renewal too, because ownership is what permits it: the refresh token is one-time and the renewal is filed in the same breath |
| `CodexOAuth.swift`              | The PKCE sign-in the login window drives, and the renewal. The Codex CLI's own public client id and loopback redirect — nothing binds the port, the window cancels the navigation and reads the code off the URL. The `state` is checked where the code is read, because that is the whole of what says a code belongs to this login |
| `CodexAccountLinking.swift`     | Turns a credential into a linked account by asking `backend-api/accounts` which workspaces it can read. One links outright; several hold the credential in the engine, unwritten, until the user answers. A list that could not be read still links, because the credential already names the workspace OpenAI defaults it to — what is lost is a name, not a login |
| `CodexAccountIndex.swift`       | `codex-accounts.json`: the identity and the chosen workspace beside the credential the keychain holds. Holds no token, so it is readable on a build whose grant has lapsed, and `CodexLinkedAccount.list` is driven by the stored credentials so one whose naming failed still gets a row — and a way to remove it |
| `ForgeActivity.swift`           | `ForgeKind`, `ForgeActivity` (the four counters per period), `ForgeActivityReading` and `ForgeReadFailure`. The login is on the *reading* and never on the connection: measured 2026-09-17, `gh`'s own configuration named one account while the token in its keychain item answered as another, so a username taken from a CLI's config is a guess about whose numbers these are. A period that could not be read is absent rather than zero |
| `ForgeConnections.swift`        | `ForgeConnection` (kind plus host — the id, so one host serving two forges is two rows), `ForgeConnectionIndex` (`forge-connections.json`, holding no secret so a lapsed grant still lists what is connected) and `ForgeTokenStore` (`com.radonforge.sissy.forge-token`). No enabled flag: a connection is the switch, and removing it is the off |
| `ForgeTokenImport.swift`        | Reads the tokens `gh` and `glab` already hold, on the press that offers them and nowhere else. `gh`'s is in the login keychain as `go-keyring-base64:<base64>` and is read through `/usr/bin/security` because that tool is on the item's ACL and this process is not — measured 2026-09-17, no dialog. `glab`'s is plaintext in its own config. Neither CLI's storage is ever written |
| `ForgeActivityFeed.swift`       | `ForgeWindow` (the archive's own window arithmetic, plus `vendorDay`, which renders a window start as its own local date at midnight UTC — both forges bucket by whole UTC days and an instant made the calendar snap down and buy a whole extra day) and one reader per forge. GitHub answers every period's contributions, merges, opened issues **and comments** in one GraphQL document costing 1 point of 5000/h — the comments as a page of the account's own, counted here rather than at the vendor, which totals no such thing; the page proves its own coverage through `vendorInstant`, and a window it cannot prove is absent rather than a lower bound. GitLab takes two documents — the second only because the root `issues` field filters on the login the first returns, and that login travels as a GraphQL **variable** rather than spliced into a query — plus two header reads per period, the activity total and the same filtered to `commented`. Each of the three optional counters is asked for only while its switch is on, keyed by `ForgeCounter`. `after` on GitLab's events is **exclusive**, measured, so a window names the day before it starts. A `403` is told from a refused token by two headers rather than one: an exhausted hourly quota leaves a remaining count of zero, a secondary limit leaves the quota alone and sends a retry deadline, and reading only the count filed a throttled account as a refusal that parks |
| `ForgeActivityMonitor.swift`    | The poll: 5 min while agents are working, 30 min once nothing has, jittered, one value published for every connection. A failure keeps the last figures **and their age** — republishing would date a reading nobody took — and a refused or missing token parks the connection until the user acts, which is what separates this loop from `ProviderStatusMonitor`'s. `refreshOnce(id:onRefresh:)` is that user: it reaches a parked connection, and the parking then follows the answer rather than accumulating. Both entry points go through one per-connection fetch, so a click landing mid-round joins it — two requests would answer at two moments and the row would keep whichever finished last rather than whichever was asked last. The fetches are unstructured, so `stop()` cancels them itself and the generation decides what may still publish. `nextDelay` caps its wait at the next local midnight, since every window is worked out from the instant it was asked for, and `wait` takes that delay in `activityCheck` slices so work starting mid-wait is not made to sit out an interval chosen before it began |
| `FSWatcher.swift`               | Wraps `FSEventStreamCreate` (CoreServices); drives per-provider reader wakes |
| `FrameBuilder.swift`            | `FrameData` / `ProviderSlice` / `UsageWindow` / `ProviderAccount` / `ProviderCredits` / `ModelTotals`, the burn rate, and the slice, project and model ordering — models by cost, then by tokens, so a day nothing has a rate for still leads with its largest. No formatters: the frame carries raw numbers and the app words them. `history` is one rollup per `UsagePeriod` the archive answers for, never keyed by `today` — the headline reads that off the live totals beside it |
| `KeepAwake.swift`               | Actor owning the `PreventUserIdleSystemSleep` assertion and, when `keepScreenAwake` asks for it, the `PreventUserIdleDisplaySleep` one, plus `KeepAwakeMode` / `KeepAwakeState` / `KeepAwakeHold` / `KeepAwakePolicy`; the mode and the screen setting persist in `server.json`, the assertions die with the process |
| `Pricing.swift`                 | Anthropic cost math, `ModelPricing`, `PricingTable`; no rate table of its own |
| `OpenAIPricing.swift`           | OpenAI cost math, same override → catalog → seed precedence |
| `PriceCatalog.swift`            | Fetches, validates and caches LiteLLM rates at runtime; renders the seed for `--dump-seed` |
| `ProviderPricing.swift`         | `ProviderPricing` resolves a provider id to its vendor's lookup, through `Pricing.price` / `OpenAIPricing.price` rather than beside them, for readings taken after the events; `CacheReading` is the share of input the cache answered and what it saved at list price, `cache read × (input − cache read)` per model. The archive keeps counters and no saving, so a window is priced when it is read, at the engine's current catalog |
| `PricingSeed.swift`             | **Generated** LiteLLM snapshot embedded at build time — offline / first-run floor |
| `ServerConfig.swift`            | Codable, loaded from `~/Library/Application Support/Sissy/server.json`; carries `providers` toggles, `codexDataDir`, `remotePricing`, `statusChecks`, `historyRetentionDays`, `keepAwake`, `keepScreenAwake`, `agentHooks` and `agentHooksRemovalPending` — the last written before either CLI's configuration is touched, so a removal the user asked for is retried at the next launch instead of being forgotten under a switch that is already off. The engine owns the file, and saves it through a staging file so it is owner-only before it answers to its own name |
| `UsageStatePersistence.swift`   | Per-provider snapshot URL builder (`forProvider("codex")`); Claude Code stays on the legacy `usage-state.json` for upgrade smoothness. A snapshot this build cannot read is moved aside rather than deleted, and only the newest `quarantineKeep` copies of one are kept — a schema bump quarantines every install's at once, and nothing used to remove the last one's. The snapshots sit beside the `server.json` that named the trees they were read from, so a config pointed elsewhere — `--config`, a test — takes its reading with it. Carries two optional blocks, `historyResume` (the archive's per-model split) and `codexResume`, plus `projectCheckouts`, which is read on load and never written again — an install that predates `ProjectLedger` hands its memory over that way |
| `UsageHistory.swift`            | The archive: one directory per provider under `history/`, one whole-file JSON per local day, a row per model per project, plus the day's session and agent counts, its worked minutes and its turns per model per effort beside the rows — a count belongs to the provider's day and to no model, and it is optional so a file written before it existed reads as *not counted* rather than as none. Versioned apart from the snapshot so a schema bump cannot delete it, rewritten whole so a re-derived day replaces rather than doubles, pruned to `historyRetentionDays` across every provider directory — the engine's call, since a provider that is off has no tail to make it. `UsagePeriod` and `rollups(for:)` live here: the windows nest, so one pass decodes each day once and adds it into every window whose cutoff admits it |
| `UsageHistoryExport.swift`      | The archive as a CSV a spreadsheet can pivot: one row per day, provider, model and project, at the archive's own decimal cost rather than `UsageFormat`'s, which rounds for 340 points of menu bar. No period lives here — a month or a quarter is an aggregation of these rows, and a pivot table does it without Sissy implementing it twice. It carries `project` **and** `project_path`, because two unrelated repositories share a basename and a sheet grouping on the label alone sums them into one row; that path is also what makes the file personal data in a way the panel is not, which the button naming it says before it is pressed. **Formula injection is measured and deliberately not escaped.** Only `project` can begin `=`, `+`, `-` or `@` — the path always starts `/`, model ids start with a letter, the token and cost columns are numeric — and measured 2026-09-15 against a real archive, none of its 5 project names or 4 models did. Quoting is not a mitigation (Excel evaluates a quoted formula); the only one that works is a `'` prefix, which corrupts the value for every parser that is not a spreadsheet, on every affected row, against a vector that also needs the reader to have re-enabled DDE by hand — Excel for Mac disables it by default and Numbers has no equivalent, so the worst case on the platform Sissy ships to is a cell that looks wrong. Revisit if a real project name trips it, or if a column ever carries a value that is not Sissy's own; the answer that corrupts nothing is dropping `project` and letting the sheet derive it from `project_path` |
| `UsageBackfill.swift`           | When the archive is filled in from logs the tail never reached. `ArchiveBackfill.window` is the whole span — from the retention cutoff to where the tail's rolling window begins, taken from `LocalUsageProvider.liveWindowStart` so the two agree across a daylight shift and never write the same day. `uncovered` narrows it to what nothing has answered for yet, which is the later of what a pass covered and how far the tail was running (the snapshot file's own mtime): that is what lets a Mac that was off for a fortnight come back for those days while a plain relaunch reads nothing. `ArchiveBackfillLedger` is the per-provider record, in its own file beside the snapshots and never inside `history/` — deleting the archive must not have the next launch re-deriving it |
| `AgentHookInstaller.swift`      | Registers Sissy's `SessionStart` entry with `~/.claude/settings.json` and `~/.codex/hooks.json`, and takes it back out. Off unless the user asks. The path in the command is quoted for `sh` and the result passes `sh -n` before it is written; the home it is built from is `getpwuid`'s, not `NSHomeDirectory()`'s, which follows `CFFIXED_USER_HOME`. A file that will not parse is left untouched, a symlinked target keeps its link, the file's own mode is preserved, and the write is abandoned if the file moved between the read and the rename |
| `ProjectResolver.swift`         | Which project a working directory belongs to: up to the first `.git`, and through a worktree's `gitdir:` pointer to the checkout it was cut from, so one repository is one row wherever the work ran. Cached per directory, one cache per provider. A walk that names no repository answers nothing rather than inventing a project out of the path; a walk that fails falls through to the ledger |
| `ProjectLedger.swift`           | What Sissy has read about checkouts, in its own file with its own schema so no snapshot bump can take it: which directory was a checkout of which repository, which is the only thing that can still answer for one that has been deleted. One ledger for every provider. Learns from git as well as from log lines — landing on a repository reads the worktree list git keeps in `.git/worktrees/`, so a worktree is answered for while it is alive rather than looked up once it is gone. Also takes in the `checkout-inbox` a CLI session leaves, read as a boundary — `O_NOFOLLOW`, a regular file this user owns, size-capped, two absolute lines — and `adopt`ed behind what Sissy walked to itself; an entry is consumed on read, which is what bounds the directory |
| `SissyPaths.swift`              | Support-dir, logs-dir and keychain-service resolution (`.dev` bundle id → dev tree and `com.radonforge.sissy.dev.*` items), so a Debug build never shares a credential with the index that names it in the other build |
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

Menu-bar only (`LSUIElement: true`), sandbox disabled. Three surfaces sit on the
status item: a left-click usage panel (`Panel/`, an `NSPopover`), a short
right-click `NSMenu` (`Menu/StatusItemController.swift`), and the SwiftUI
`Settings` scene (`Settings/`, tabs General/Providers/Forge/About) — reachable from the app menu's
Settings… item (⌘,) and, in code, only through `SettingsLink`, which takes no
action closure and is why the panel's own settings button aims the window at a
tab through `SissyModel.settingsTab`.

**The fourth is a window, and it opens once, to link an account.**
`Accounts/VendorLoginWindow.swift` is a `WKWebView` on the vendor's own login —
claude.ai's for a Claude account, `auth.openai.com`'s for a Codex one — because
a credential cannot be had without one. One window for both: `Vendor.session`
and `Vendor.code` are the two closures that say whether the sign-in ends in a
cookie the jar receives or in a redirect carrying an authorization code, and
everything around them is shared. It floats and the activation policy goes to
`.regular` while it is up, because an email-code login requires leaving it and
an `LSUIElement` app has no Dock icon and no ⌘-Tab entry to come back through —
and the control that opens it is never disabled, a second press bringing the
existing window forward rather than opening a second one.

**The panel is six pages behind one popover.** `UsagePanelView.Page` is the
enum, and the `switch` on it is the whole implementation of the rule that only
the selected page exists — a `TabView` would hold every page's view graph live,
which is precisely the cost `UsagePanelController` drops its host on close to
avoid.

`Panel/PanelOverview.swift` answers what the selected window cost and whether
there is room to keep working: the cost, one row per account carrying the window
that binds, what the agents running now are holding, the projects, a row per
connected forge, and — only when there is one — a repository committing under a
name its forge does not expect. The headline is over a period the user picks
(`UsagePeriod`: today, 7d, 30d, all), persisted in `preferences.json` because it
changes what is rendered and nothing about what is metered; the frame carries
every window at once so switching costs no round trip to the engine. Today is
never rolled up from the archive — the archive's copy of it is written behind
the tail's flush. It replaced a fixed 7-day line at the foot of the Overview,
which included today without saying so: measured 2026-09-15, 24.7% of that line
was the headline above it.

Six pages sit one level in from it:

| Page | File | Answers |
|---|---|---|
| `.provider` | `PanelProviderPage.swift` | that account's windows, identity and credits, beside **the CLI's** day, its split by model and its projects — the slice is per provider, since a log line names no account — and the refresh, which is a different action on each provider. The model split is a row of `ModelPill`s **under** the strip, two tiers each, because it is the caption of the day the bars are about rather than a second list in the idiom `By project` already owns — and it follows the pointer, since every `DayRow` carries its own split off bytes `UsageHistoryStore.series` had already decoded |
| `.services` | `PanelProviderStatusPage` in `PanelProviderStatus.swift` | that vendor's own service tree, one level in from its page |
| `.effort` | `PanelEffortPage.swift` | that vendor's week by model and effort, a bar per model, one level in from the `By effort` row on its page, which opens only when the split says more than the row |
| `.projects` | `PanelProjectsPage.swift` | every repository the day names rather than the folded three, with the unattributed remainder as a line at the foot rather than a row in the list |
| `.identities` | `PanelIdentities.swift` | which repositories commit under a name their forge does not expect, findings on the page and the rest behind a disclosure |
| `.stats` | `PanelStats.swift` | what is running now, and over a window of its own how many sessions and agents have run and how long the day was worked |

`.provider`, `.services`, `.effort` and `.projects` carry the account they were opened
from, so the way back lands on the page that was left rather than on that
vendor's first account. `.identities` carries the repository it was opened
about instead, and `.stats` carries nothing: its window is its own, local to
the page, because sharing the headline's moved the money figure behind the
user's back.

There is no footer: the age of the reading sits under the header's title, where
it dates the numbers beside it, and the way into Settings sits beside the
keep-awake switch, which is where the app's own controls live.
`Panel/PanelComponents.swift` holds what the pages draw in common, so a bar or a
badge cannot drift a point between them.

The Overview carries a gauge per readable account rather than one across every
provider. A single one reports the tightest and silently implies the rest are
fine — measured on a day with Claude and Codex both at 100%, it named Codex and
Claude vanished — and with two accounts linked the question has two answers,
which is the whole reason for linking the second. Which window an account leads
on is `UsagePanelSnapshot.binding`: the one its current rate empties before its
own reset, soonest first, ties to the shorter period, and the percentage only as
the fallback for windows that project nothing. A window that has rolled over is
never a candidate. The rows are read off the provider rows rather than off the
slices, so a gauge on the Overview and the same gauge on that provider's page
are one object down to the pace.

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
`HeaderSnapshot.make` is for the header. There is no "Show Claude Code limits"
switch: it existed to make a keychain prompt expected, and there is no prompt —
the limits read Claude Code's own credential, from its config directory or
through `/usr/bin/security`, so the row states the source instead of offering a
choice about it. What the tab does carry beside each row is the account work:
the claude.ai sessions linked to it, and `Add account…`, which opens the one
window Sissy ever shows.

Each provider has an on/off switch, and flipping it is a new engine rather than
a mutated one: `UsageEngine`'s lifecycle is terminal, so `setProvider` persists
the toggle and then tears the engine down and builds another from the file. It
costs what a relaunch costs, which is nothing — every reader resumes from its
own snapshot's offsets.

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
  The one gesture that opens anything is linking a claude.ai account, which puts
  the vendor's own login in a window — from that button and from nothing else,
  never from a poll or a launch.
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
