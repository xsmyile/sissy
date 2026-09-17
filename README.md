<div align="center">

<h1>
  <img src="assets/sissy-icon.png" alt="" width="128" /><br />
  Sissy
</h1>

**The numbers you keep checking, in the macOS menu bar.**

Sissy reads what is already on your Mac and keeps the answer one click away, so
what you would otherwise open a browser or a terminal for sits behind one icon.
No account of its own, no telemetry, and nothing to grant at first launch.

What it answers for today is what your coding agents cost: Claude Code and
Codex, priced as each turn lands, with the rate-limit pressure and the
per-repository split beside it.

[![Release](https://img.shields.io/github/v/release/xsmyile/sissy?style=flat-square&color=black)](../../releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/xsmyile/sissy/ci.yml?branch=master&style=flat-square&color=black&label=ci)](../../actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square)](#install)
[![License](https://img.shields.io/github/license/xsmyile/sissy?style=flat-square&color=black)](./LICENSE)

[Install](#install) • [What you see](#what-you-see) • [Supported CLIs](#supported-clis) • [Privacy](#privacy) • [Uninstall](#uninstall) • [How it works](#how-it-works) • [Configuration](#configuration) • [Build from source](#build-from-source)

<img src="assets/overview.png" alt="The Sissy panel open on the Overview: the day's cost over a period you pick, a rate-limit gauge per account, and where the day went by repository." width="380" />

</div>

## Install

macOS 26 or later, Apple Silicon or Intel.

### Homebrew

```bash
brew install --cask xsmyile/sissy/sissy
```

`brew upgrade` keeps it current.

### Manual

Take the latest `Sissy-x.y.z.dmg` from [Releases](../../releases/latest), open
it, drag **Sissy** into Applications. The build is Developer ID signed and
notarized, so there is no `xattr` workaround and no right-click → Open.

Either way it starts tailing the moment it launches, and lives in the menu bar
rather than the Dock. **The first launch asks for nothing**: no Full Disk
Access, no keychain dialog, no prompt of any kind. That is a rule rather than a
list of what Sissy happens to need today. Anything that costs a permission, or
that writes outside Sissy's own folder, is off until you switch it on, asks at
that moment rather than at launch, and says what it will do before you flip it.
A module left off does not exist as far as the system is concerned.

## What you see

Sissy sits in the menu bar as herself. She blinks when usage lands, shuts her
eye when nothing is reaching the app, and lights it blue while the Mac is being
held awake. There is no number up there and nothing to read at a glance you did
not ask for. Click for the panel, right-click for the short menu.

### The Overview answers two questions

**What has this cost**, over a window you pick (`Today`, `7 days`, `30 days`,
`All`), with the tokens and the burn rate under it. The period is a popup on the
headline's own row, so the panel does not grow a section per timescale. Where
the archive does not go back as far as the window you asked for, a grey line
under the figure says how far it does go.

**Is there room to keep working.** One row per account, each carrying the
rate-limit window it will run out of *first*. That is a question about pace
rather than percentages: a session bucket at 40% that lasts until its reset
matters less than a weekly at 35% that empties in two days. The bar fills with
what has been spent, and the mark on it sits where even consumption would have
reached by now, so you can see you are ahead of pace instead of working it out.
Link a second Claude account and it gets its own row, because "am I about to be
cut off" has one answer per account.

Under that, where the day went **by repository**, not by directory. A worktree
counts against the repository it was cut from, so one project reads as one row
instead of eleven small ones.

<p align="center">
  <img src="assets/provider-claude.png" alt="A Claude account's provider page: the seat and plan, every rate-limit window with what is left and when it resets, and under them the CLI's day and the repositories it went on." width="300" />
  <img src="assets/provider-codex.png" alt="A Codex account's provider page: the plan, the weekly window with its pace, a session window awaiting a reading, and under them the CLI's day and the repositories it went on." width="300" />
</p>

### A provider page per account

Click a row for the account it names: who it is signed in as and on which plan,
every rate-limit window it publishes with the time each resets, and the credit
balance where the vendor reports one. Under those sit that CLI's own day and its
own repositories — the CLI's, not the account's, because a log line carries no
account id and Sissy will not split a day it cannot attribute. The vendor's own
status page is down there too, so "is it me or them" costs no browser tab.

Click a repository for its card: the forge it is pushed to, a link to the page,
and the path on disk.

### Keep awake

The cup in the panel header stops the Mac idling to sleep under a running agent.
Three modes: *Never*, *While agents are working*, *Always*. The middle one is
the one no generic `caffeinate` can offer, because Sissy holds the Mac while
turns are landing and lets go ten minutes after they stop, so nothing has to be
switched back. *Always* stops after eight hours rather than going quiet. Neither
overrides closing the lid, and the hold lasts exactly as long as Sissy runs. Quit
and the Mac sleeps normally again, with nothing left behind to undo.

Sissy's eye glows blue while a hold is on, in the menu bar and in the panel
header. It follows the hold rather than the switch, so under *While agents are
working* it comes and goes with the turns.

### Settings

**⌘,** or the gear in the panel. *General* is where start-at-login lives, along
with whether Sissy animates, whether the gauges print what is spent or what is
left, the session-hook switch, keep-awake, and the usage archive: where it sits,
an export, and a button that deletes it. *Providers* is each CLI's state, the
accounts linked to it, and the vendor status switch. *About* carries **Copy
diagnostics**, which is what an issue needs.

## Supported CLIs

| CLI | Reads |
|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl`, honoring `CLAUDE_CONFIG_DIR` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl`, honoring `CODEX_HOME` |

Sissy reports the same things for both: tokens, cost, the per-repository split,
every rate-limit window the account publishes, the plan, and the credits where
the vendor reports any.

Claude Code is on unless you switch it off; Codex is picked up whenever its
session directory exists. Either can be forced on or off from
Settings ▸ Providers.

Two ceilings worth knowing about. Codex publishes its limits only on its own
turn events, so those gauges are always one turn behind. That is the shape of
the CLI, not a bug. Claude's limits come from the credential Claude Code already
stored, so they are as fresh as the last time that CLI ran; the refresh button
on the provider page re-reads it. That read costs no dialog either way: the
credential is a file in the CLI's own config directory, and where macOS keeps it
in the login keychain instead, Sissy reads it through `/usr/bin/security`, which
is already on that item's access list.

Adding a CLI that writes append-only JSONL is a `SourceAdapter` rather than a
second reader. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy

Your session logs never leave the machine. Sissy reads them, prices them, and
renders a number. It listens on no port, has no account of its own, and does no
analytics and no crash reporting.

Everything it sends over the network is a reading you asked for, and each one
has a switch. As it stands there are four:

| Host | What for | Off switch |
|---|---|---|
| `raw.githubusercontent.com` | LiteLLM's public model price list, once a day | `remotePricing: false` pins pricing to the compiled-in snapshot |
| `api.anthropic.com` | the usage and profile endpoints, with the OAuth token Claude Code already stored — read-only, never refreshed, never written back | switch the Claude Code provider off |
| `claude.ai` | usage and credits for an account you linked yourself | unlink the account |
| `status.claude.com`, `status.openai.com` | each vendor's own public status page, on a poll. No account, no credential, no identity | `statusChecks: false` |

Each row is its own switch and there is no single one behind all four: pinning
the rates leaves the other three running. [SECURITY.md](SECURITY.md) has the
other half — what Sissy reads on disk, and which credential the rate-limit
windows come from.

**What Sissy keeps**: one day-by-model record under
`~/Library/Application Support/Sissy/history/`, so the panel can answer for more
than today. It holds totals, never prompts. Settings names the folder, deletes
it on a button, and `historyRetentionDays` bounds it, with `0` recording
nothing. On a first run Sissy fills that record in once from what the CLIs
already logged, so the wider windows are not empty for a month. Beside it, in a
keychain item of its own, sits a copy of each Claude credential it has seen
active — that is what *Use in CLI* switches between, and
[Uninstall](#uninstall) says how to remove them.

**Anything Sissy writes outside its own folder is off by default** and named
before you switch it on. Today that is one switch and one button: *Name projects
even when Sissy is off*, which adds a line to `~/.claude/settings.json` and one
to `~/.codex/hooks.json` and takes both back out when you switch it off; and
*Use in CLI*, which writes the account you picked into the slot Claude Code
reads its credential from. [Uninstall](#uninstall) says what survives if you
remove Sissy without switching the first one back off.

## Uninstall

```bash
brew uninstall --cask sissy
```

Or drag **Sissy** out of Applications. Either way the counting stops and the Mac
goes back to how it was: no daemon to kill, no power assertion still held,
nothing listening anywhere.

Three things survive, and each has its own way out:

- **The usage archive**, under `~/Library/Application Support/Sissy/`. Settings
  ▸ General deletes it on a button, or remove the folder yourself.
- **Archived Claude accounts.** While Claude Code is metering, Sissy keeps a
  copy of whichever credential it finds active, so *Use in CLI* can put it back
  later. They sit in a keychain item of Sissy's own
  (`com.radonforge.sissy.claude-account`) and have no control of their own yet;
  Keychain Access deletes them. A claude.ai session you linked is a separate
  item (`com.radonforge.sissy.claude-web`), and that one Settings ▸ Providers
  removes on its row.
- **The session hooks**, if you ever switched *Name projects even when Sissy is
  off* on. Switch it back off **before** you uninstall and Sissy takes them out
  itself.

The hooks are the case worth saying plainly, because they are the one thing
that goes on running once Sissy is gone. Uninstall with the switch still on and
two lines stay behind: a `SessionStart` entry in `~/.claude/settings.json` and
one in `~/.codex/hooks.json`, both naming `session-start.sh`. That script lives
in Sissy's own folder rather than in the app bundle, so dragging the app to the
Trash does not take it: every CLI session goes on running it, resolving the
repository and writing a line nothing reads any more. Remove
`~/Library/Application Support/Sissy/` and the script goes with it, after which
the two lines are inert — the shell finds nothing, drains stdin and exits 0.
They are still in files that belong to other programs, so delete the entries by
hand either way.

## How it works

The metering runs in a single process. Sissy watches the log directories,
prices each turn as it lands, and renders the combined reading. No daemon, no
socket, and nothing listening on a port. Counting happens while Sissy runs; the
numbers live in the CLIs' own files either way, so a relaunch resumes at the
byte it stopped at and loses nothing.
*Start at login* is what keeps a day complete.

There is no price table in the source. Rates come from
[LiteLLM](https://github.com/BerriAI/litellm)'s public price list, fetched at
runtime and cached for a day, with a generated snapshot compiled in as the
offline floor. A CLI that ships a new model therefore prices correctly without a
Sissy release. LiteLLM is also what [`ccusage`](https://github.com/ccusage/ccusage)
prices from, which is why the two agree on the same logs; CI asserts that
agreement on every engine change, and weekly regardless.

If Sissy and `ccusage` disagree on your machine, check `ccusage --version`
first: a Homebrew install pinned at 20.1.0 bills 1-hour cache writes at the
5-minute rate and will never upgrade off itself, which looks like Sissy
over-billing by about 7%.

## Configuration

Everything has a default and nothing has to be configured. The app writes
`~/Library/Application Support/Sissy/server.json`; the rows marked ▸ are also in
Settings.

| Key | Default | Effect |
|---|---|---|
| `providers` | auto-detect | force `claudeCode` / `codex` on or off ▸ |
| `claudeDataDir`, `codexDataDir` | `~/.claude/projects`, `~/.codex/sessions` | where to look |
| `statusChecks` | `true` | read each vendor's public status page ▸ |
| `keepAwake` | `off` | `auto` holds the Mac while agents are working and lets go after 10 minutes of silence; `on` holds it until you switch off, or for 8 hours ▸ |
| `keepScreenAwake` | `true` | whether that hold covers the screen too; `false` lets the display sleep and the Mac lock itself while the work carries on ▸ |
| `agentHooks` | `false` | register the `SessionStart` hook with both CLIs so a session names its repository ▸ |
| `historyRetentionDays` | `90` | days of day-by-model history kept under `history/`; `0` records none ▸ |
| `remotePricing` | `true` | fetch rates at runtime; `false` pins to the built-in snapshot |
| `pricingOverride` | none | per-model rates that win over both sources |
| `pollIntervalSeconds` | `60` | safety-net poll between filesystem events |

## Build from source

```bash
brew install xcodegen
cd app && xcodegen generate
xcodebuild -project Sissy.xcodeproj -scheme Sissy -configuration Debug build
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest: the signed dev build that
*Start at login* has to be tested from, the linters, the self-test, and what
Sissy will and will not take. The [code of conduct](CODE_OF_CONDUCT.md) applies
to all of it.

## Credits

As it ships today, nothing third-party links into Sissy. Its reading of the
Claude Code and Codex log formats, and its pricing, follow
[`ccusage`](https://github.com/ccusage/ccusage);
the rates themselves come from [LiteLLM](https://github.com/BerriAI/litellm).
[CREDITS.md](CREDITS.md) says it properly, and covers the vendor marks Sissy
draws to say which CLI a row is about and where a repository is pushed.

## The name

Named after my cat: she naps, judges, demands cuddles (A LOT of cuddles), and
is, objectively, fabulous. The icon is her.

## License

The source code is [MIT](./LICENSE). Sissy's name and her artwork are not, and
[NOTICE](./NOTICE) says what that means. Fork it, ship it, sell it; just not
wearing her face.
