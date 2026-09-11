# Single-process migration

Sissy is folding `sissy-serverd` back into the app. This is the working ledger:
what is decided, what has landed, what is left. Delete it with the last PR.

## Why

The daemon was a **network server for an ESP32**. `companion`'s
`docs/ARCHITECTURE.md` opens with it: *"Two halves: a native Swift daemon on the
host machine, and ESP32 firmware that pulls frames from it over WebSocket."*
Wildcard bind, bearer token, multi-client fan-out with last-frame replay, and
scalars pre-formatted for 128×64 pixels. The macOS app was the second client,
and it arrived later.

The companion left in 0.1.9. The sentence in `docs/ARCHITECTURE.md` was rewritten
to *"They are separate processes so the daemon keeps counting after the app
quits"* — a justification found after the fact, and it does not survive contact
with the code:

- **"Keeps counting while the app is closed"** costs nothing to give up. Every
  resume mechanism already exists to survive *daemon* restarts —
  `usage-state.json`, `codexResume.fileModels`, per-file offsets, the cold scan
  that skips `mtime < now-48h`. A launchd restart and an app relaunch are the
  same event to that code. The JSONL on disk is the truth and it does not move.
- **"KeepAwake must outlive the app"** was self-imposed, and rejected: a user
  who quits Sissy and finds their Mac still held awake by an invisible process
  has a bug, not a feature.
- **Crash isolation** (`KeepAlive`/`SuccessfulExit=false`) is real and small.
  Accepted as a loss.

What it costs instead: ~1,400 lines that exist only so two processes can talk,
plus a per-feature tax paid in three places with no shared schema. KeepAwake —
one boolean — cost 14 files and 495 lines (`a10cb04`, `e7a6234`). Roughly 160 of
those are the feature; the rest is transport, persistence of a mode across the
wire, an optimistic-ack window, and a gate on link state.

## Target shape

```
app/SissyServer/  the engine: readers, pricing, aggregator, FSWatcher,
                  persistence, formatters — no NIO. Compiled into both.
Sissy.app  (app)  UI + the engine in-process
sissy-cli  (tool) --self-test / --scan / --dump-seed / --refresh-catalog
```

Only four daemon files import NIO (`main`, `SissyServer`, `HTTPRequestHandler`,
`WebSocketSinkHandler`). Everything of value is already transport-free and moves
unchanged. `FSWatcher` uses `FSEventStreamSetDispatchQueue` on a `.utility`
queue — chosen deliberately over `ScheduleWithRunLoop` — so it drops into an
AppKit process with no run-loop work.

**The engine is shared as sources, not as a module.** A framework or static
library would mean annotating ~25 files with `public` for a boundary that
exists for one release: the daemon target is deleted in PR 5, after which there
is one consumer and a thin CLI. Both targets listing the same directory costs a
second compile of code that is about to have one home, and no annotation churn
in files #35 is rewriting at the same time. The directory keeps its name until
PR 5 for the same reason — a rename now would conflict with every line of that
work.

## PR ledger

| # | PR | State |
|---|---|---|
| — | `docs`: this ledger | merged (#50) |
| 0 | `fix(daemon)`: the keep-awake hold follows the app | merged (#51) |
| 1 | `refactor`: the engine compiles into the app | merged (#52) |
| 2 | `feat(cli)`: `--refresh-catalog`, and the oracle pointed at it | merged (#53) |
| 3 | `refactor(app)`: render the engine's frame types | merged (#54) |
| 4 | `refactor(app)`: run the engine in-process, retire the LaunchAgent | **in review** |
| 5 | `refactor`: drop the wire | todo |
| 6 | `refactor`: drop the OLED residue | todo |
| 7 | `chore`: notices and acknowledgements | todo |
| 8 | `ci`: drop the daemon scheme | todo |
| 9 | `docs`: architecture and the rules that go with it | todo |

The order of 2 → 4 → 5 is not cosmetic: it is the sequence in which CI never
goes red. PR 2 has to give the oracle its replacement entry point *before* PR 5
removes the server mode the oracle currently boots.

**PRs 3 and 4 as first planned were not separable, and are now split
differently.** The app cannot run the engine while the daemon is still
registered: two processes would tail the same trees, write the same
`usage-state.json`, hold two power assertions and run two probes against
Anthropic's endpoint. So retiring the LaunchAgent is part of the engine swap,
not a step after it. What *is* separable is the type unification — the app
rendering the engine's own `FrameData` instead of a mirror of it — which is
behaviour-neutral and shrinks the swap. That is PR 3; the swap is PR 4.

### What each PR covers

**0 — the keep-awake hold follows the app.** Ships before the merge because it
is a live bug. The `mode` stays where the user left it; the assertion is held
only while a client is connected. That is exactly the `{mode, active}` split
`KeepAwakeState` already documents, so it costs a presence hook on `Hub` and a
condition in `applyKeepAwake`. After PR 3 it is free — the process dies, the
assertion dies with it.

**1 — the engine compiles into the app.** The app target lists
`app/SissyServer` too, excluding the nine files that are the *daemon* rather
than the engine: `main`, `SelfTest`, `SissyServer`, `Hub`,
`HTTPRequestHandler`, `HTTPResponses`, `WebSocketSinkHandler`, `Auth`,
`SissyPaths`. Two things had to give first — `daemonLog` moved out of
`main.swift` into `DaemonLog.swift`, since seven engine files call it; and the
app's mirror of `KeepAwakeMode`/`KeepAwakeState` was deleted in favour of the
engine's, which is a strict superset. Nothing calls the engine yet: that is
PR 3. The only other name clashes were `HealthResponse` and `SissyPaths`, both
excluded, both gone by PR 5.

**2 — `--refresh-catalog`.** `pricing-oracle.yml:83-98` currently **boots the
daemon in server mode**, greps its log for the catalog line, then `kill -TERM`s
it. That step does not survive PR 5, so `--refresh-catalog` replaces it: one
fetch, validated through the same `isUsable` gate the runtime refresh uses,
written to `pricing-catalog.json`, non-zero exit if no attempt lands a usable
catalog. The workflow now runs the flag and fails on its exit code instead of
grepping a background daemon's log for a readiness line.

**3 — the engine's frame types.** `DisplayFrame` and its three nested types
were a field-for-field mirror of the engine's `FrameData`, `ProviderSlice`,
`UsageWindow` and a `PrevTotals` pair — the same initialisers, down to
`planTier` being dropped when `plan` is nil. The app now uses the engine's,
and `Identifiable` moved onto them so SwiftUI keys rows by `minutes` and by
provider id as before. `ts` left the frame: it describes the transport, not
the reading, so `FrameDecoder` returns it beside the frame as `builtAt` and
`applyFrame` takes it as an argument. Behaviour-neutral, still over the
WebSocket.

**4 — run the engine in-process, retire the LaunchAgent.** `UsageEngine` is
the non-NIO half of `SissyServer`, extracted so both the app and the tool run
one implementation; `SissyServer` is now a 144-line NIO shell over it and
`UsageEngineHost` is the app's one hop between that actor and `@MainActor`.
Gone: `WebSocketClient`, `ServerHealthMonitor`, `FrameDecoder`,
`Server/HTTPResponses`, `ServerServiceController`, both plists, the
`copyFiles` phases, the Server toggle and its five states, the port
migration, the bearer-token generator's call sites, and
`app/Sissy/Server/` entirely.

What replaced the five server states is three readiness states, because they
are the three things that are actually true when the panel is blank: the
readers are still walking the trees, they walked them and found no session
logs, or they found logs and today is still empty. `HeaderSnapshot.make` is a
pure function of `(hasFrame, isWarm, filesWatched)` and is what the tests
target. The third state is the common one first thing in the morning and the
only one of the three that is not a fault — a single "waiting" line sent
people hunting for one.

`fmtBurn`'s placeholder moved onto `FrameBuilder.placeholder`, where the
formatter that produces it lives; `burn` is still read straight off the frame
so nothing else had to move.

Two notes for whoever reviews the migration path:
- It runs from `SissyModel.start()`, which means it also runs under
  `xcodebuild test` — the test host launches the real app. It touches nothing
  unless launchd actually knows about an agent, so a machine with no
  registration is unaffected, but a dev machine with the `.dev` agent
  registered will have it retired by a test run. That is the correct
  production behaviour arriving early rather than a bug.
- The log prefix is still `sissy-serverd:`. Renaming it touches every engine
  file and would collide with #35; it goes with the directory rename in PR 9.

**5 — drop the wire.** `Hub`, `WebSocketSinkHandler`, `HTTPRequestHandler`,
`Auth`, `SwiftNIO`. `sissy-serverd` becomes `sissy-cli`. Config collapses:
`server.json` and `preferences.json` become one file, which is a deliberate
choice because the README documents `server.json` as hand-editable. Drops from
`Preferences`: `serverHost`, `serverPort`, `authToken`, `primaryMetric`,
`minimumSecretLength`, the CSPRNG token generator, `ensureAuthToken`,
`migrateLegacyServerPort`, `serverConfigPort`, `legacyDefaultServerPort` — and
with them `PreferencesTests` and `SissyModelPortMigrationTests`. Drops from
`ServerConfig`: `host`, `port`, `authToken`, `primaryMetric` and their merge
arms. `SelfTest` loses `runHubEncodeTests` and `runHubKeepAwakeEncodeTest`; the
other ~1,400 lines survive.

`filesWatched()` and `isWarm()` **stay** — the panel's "warming" and "no JSONL"
states need them. They just stop travelling over HTTP. That overlaps with
#35's per-source `/health` work; the two merge.

**6 — OLED residue.** `primary`, `primary_label` and `primaryMetric` are dead
end to end: the preference has no UI anywhere, the daemon computes the pair from
it, the app decodes them into `DisplayFrame` and never draws them. Only tests
assert them.

**7 — notices.** `THIRD-PARTY-NOTICES.md` covers SwiftNIO and its three
transitive Apple packages, and nothing else. Without NIO the licence sections,
the `project.yml` resource copy, `ThirdPartyNotices`, `AcknowledgementsView`,
`AcknowledgementsTests` and About's Acknowledgements sheet are all dead. The
`## Credits` section (ccusage, LiteLLM) is not a licence obligation and is worth
keeping, so this shrinks the file rather than deleting it.

**8 — CI and scripts.** The `sissy-serverd` scheme steps in `ci.yml`,
`release.yml` and `pricing-oracle.yml`; the daemon signing arms in
`release.sh:112,126-131`. `scripts/dev-build-app.sh` exists *entirely* because
SMAppService demands a normally signed bundle — it goes back to a plain
`xcodebuild`, and the AGENTS.md rule about it goes with it. The Homebrew cask's
`uninstall launchctl:` and its `~/Library/LaunchAgents/…plist` zap path stay for
at least one release to clean up existing installs.

**9 — docs.** `docs/ARCHITECTURE.md`, and four conventions in `AGENTS.md` that
stop being true: the daemon-ownership rule, the port rule, the bearer-token
symmetry rule, the two-login-items rule.

## Decisions

**The login-item migration has two steps.** Today "Server" and "Start at login"
are independent switches, and Server ON with the app *not* at login is a
legitimate configuration. Unregistering the agent alone would silently stop
counting for those users. PR 4 must, when it finds a registered server agent:
unregister it **and** register the app through `SMAppService.mainApp`. It has to
run whether or not the user opens Settings, be idempotent, and record that it
ran so it never fights a user who later removes Sissy from Login Items.

**Config becomes one file.** Two files exist because two processes needed
different things. The README documents `server.json` as hand-editable, so the
collapse is a documented change, not a silent one.

**`credentials.json` reopens.** #35 chose a 0600 file over the keychain, and the
recorded reason is *"a background agent reads the value unattended with nobody
there to answer a prompt."* With no background agent the premise is gone and the
answer goes back to the keychain.

**Notices shrink, they do not disappear.** See PR 7.

## Consequences for the open issues

**#35** loses step 3 outright (`set_providers`, the locked provider box,
per-source `/health` over HTTP — a registry mutation becomes an actor call),
keeps step 4's UI but not its plumbing, and halves step 2 (one display table
instead of the app's plus the daemon's, and the title-case fallback for unknown
ids protects against a version skew that cannot happen in one process). Steps
7–12 each stop paying the `FrameBuilder → Hub.encode → FrameDecoder` tax plus a
`SelfTest` wire arm — six times.

**Step 1 of #35 is safe to run in parallel.** Extracting `LocalUsageProvider` +
`SourceAdapter` touches `ClaudeCodeUsageReader`, `CodexUsageReader`,
`UsageProvider` and `UsageReaderShared`, which overlap this work only in
`SelfTest.swift` and `main.swift`. Landing PR 1 first makes the trees disjoint.

**#37's second founding rule** — *"The daemon owns what has to survive the app
quitting"* — has to be rewritten. None of its ten sub-issues needs a daemon, and
#45 (self-update) is actively harder with one: the LaunchAgent has to be
unregistered and re-registered, and the keychain grant re-prompts on every
re-sign.

**#39** shipped its manual half as PR #48; only the agent-detection half is open.

**#47 (widget)**: a WidgetKit extension is always sandboxed and cannot link the
in-process engine — it needs a snapshot in an App Group container. True with or
without the daemon, but after the merge the app is the writer.

## Do not

- Reintroduce a network bind, a bearer token or a port. If a second consumer
  ever appears, that is a new decision with a new design, not a revival.
- Add a file to `app/SissyServer/` that imports NIO or reaches for `Hub`. The
  app target compiles that directory too, minus the tool's own nine files.
- Fold `SelfTest`'s surviving 1,400 lines into XCTest as part of this work. It
  is worth doing once the daemon target is gone; it is not this refactor.
