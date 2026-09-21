<div align="center">

<h1>
  <img src="assets/sissy-icon.png" alt="" width="128" /><br />
  Sissy
</h1>

**The numbers you keep checking, in the macOS menu bar.**

What your coding agents cost, how close you are to a rate limit, where the work
went, what the sessions running now are holding, and what you pushed — read from
the logs already on your Mac and the services you connect. No account of its
own, no telemetry, nothing to grant at first launch.

[![Release](https://img.shields.io/github/v/release/xsmyile/sissy?style=flat-square&color=black)](../../releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/xsmyile/sissy/ci.yml?branch=master&style=flat-square&color=black&label=ci)](../../actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square)](#install)
[![License](https://img.shields.io/github/license/xsmyile/sissy?style=flat-square&color=black)](./LICENSE)

[Install](#install) • [What it shows](#what-it-shows) • [What it reads](#what-it-reads) • [Privacy](#privacy) • [Uninstall](#uninstall) • [How it works](#how-it-works) • [Configuration](#configuration) • [Build](#build-from-source)

</div>

## Install

macOS 26 or later, Apple Silicon or Intel.

```bash
brew install --cask xsmyile/sissy/sissy
```

Or take the `.dmg` from [Releases](../../releases/latest). It is Developer ID
signed and notarized, so there is no `xattr` workaround and no right-click →
Open.

Sissy lives in the menu bar, not the Dock, and starts reading on launch. **The
first launch asks for nothing** — no Full Disk Access, no keychain dialog, no
prompt of any kind. Anything that costs a permission, or writes into another
program's files, is off until you switch it on and says what it will do first.

## What it shows

Left-click the icon for the panel, right-click for a short menu. There is no
number in the menu bar.

**The Overview**

- What the period cost — `Today`, `7 days`, `30 days` or `All` — with the tokens,
  and the burn rate on Today.
- A rate-limit gauge per account, on its most pressing window. The mark on the
  bar is where even consumption would have reached by now, so being ahead of
  pace is visible instead of calculated.
- How many agents are running and how much memory they hold.
- Where the day went, by repository. A worktree counts against the repository it
  was cut from, so one project is one row.
- What you contributed on each connected forge, over the period you picked —
  though on `All` each vendor answers over its own range, not the archive's.
- A repository committing under a different name from your others on the same
  forge — and only when there is one.

**Click a row** for the page behind it — an account's plan, windows and credits;
every repository of the day; the processes running now and how long the day was
worked; the commit-identity findings; the vendor's own service tree.

**Keep awake** is the cup in the panel header: *Never*, *While agents are
working* (holds the Mac while turns land, lets go ten minutes after they stop),
or *Always* (eight hours, then off). Neither overrides a closed lid, and the
hold dies with Sissy — quit and the Mac sleeps normally, with nothing to undo.

**Settings** is ⌘, or the gear — General, Providers, Forge, About. **Copy
diagnostics** lives in About and is what a bug report needs.

## What it reads

| Source | Where |
|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl`, or wherever `claudeDataDir` points |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl`, honoring `CODEX_HOME` |
| GitHub, GitLab | each vendor's API, with a token you connect in Settings ▸ Forge |
| Your repositories | `git`, to resolve a project and read its commit identity |

Both CLIs report the same things: tokens, cost, the per-repository split, the
sessions and agents behind them, every rate-limit window, the plan and the
credits. Claude Code is on unless you switch it off; Codex is picked up whenever
its session directory exists.

Rate-limit windows come from each vendor's own usage endpoint, read with the
credential its CLI already stored, and cost no dialog either way: Codex's is a
file in its config directory, and Claude's is that or — where macOS keeps it in
the login keychain instead — an item read through `/usr/bin/security`, which is
already on its access list. Sissy never refreshes either of those — the one
credential it renews is its own copy, minted when you link an account in the
app — and replaces one only when you pick an account with *Use in CLI*.

A forge connection reuses the token `gh` or `glab` already holds, or one you
paste. Sissy warns first that a CLI's token usually carries write access to
every repository, copies it into a keychain item of its own, and never writes to
either CLI or to any repository.

## Privacy

Your session logs never leave the machine. Sissy binds no port, has no account
of its own, and does no analytics and no crash reporting.

Every request it makes is a reading you asked for, and each has its own switch:

| Host | For | Off |
|---|---|---|
| `raw.githubusercontent.com` | LiteLLM's public price list, daily | `remotePricing: false` |
| `api.anthropic.com` | usage and profile, with Claude Code's own token | switch the Claude Code provider off |
| `claude.ai` | usage and credits for a Claude account you linked | unlink the account |
| `chatgpt.com` | the Codex usage endpoint | switch the Codex provider off, or unlink |
| `auth.openai.com` | signing a Codex account in, and renewing that credential afterwards | unlink the account |
| `api.github.com`, or the Enterprise / GitLab host you connected | your own activity counts | disconnect it in Settings ▸ Forge |
| `status.claude.com`, `status.openai.com` | each vendor's public status page | `statusChecks: false` |

**What Sissy keeps** is one day-by-model archive under
`~/Library/Application Support/Sissy/history/`: totals, repository paths, session
counts and how long each day was worked — never prompts, and never a line of your
logs. Settings names the folder, deletes it on a button, and
`historyRetentionDays` bounds it, with `0` recording nothing. On a first run it is
filled in once from what the CLIs already logged, so the wider windows are not
empty for a month. Credentials sit in keychain items of Sissy's own, listed under
[Uninstall](#uninstall).

**What it writes elsewhere** is off by default. *Name projects even when Sissy is
off* adds one line to `~/.claude/settings.json` and one to `~/.codex/hooks.json`,
and takes both out when you switch it off. *Use in CLI* writes the Claude account
you picked into the slot the CLI reads its credential from.

[SECURITY.md](SECURITY.md) has the full surface: what Sissy reads, what it runs
and what it holds.

## Uninstall

```bash
brew uninstall --cask sissy
```

Or drag **Sissy** out of Applications. Either way the counting stops: no daemon
to kill, no power assertion still held, nothing listening anywhere.

What survives, and the way out of each:

| Survives | Remove with |
|---|---|
| The usage archive | Settings ▸ General ▸ Delete |
| Everything else under `~/Library/Application Support/Sissy/` | delete the folder |
| Logs under `~/Library/Logs/Sissy/` | delete the folder |
| Archived Claude credentials (`com.radonforge.sissy.claude-account`) | Keychain Access — no control of its own yet |
| A linked claude.ai session (`…claude-web`) | Settings ▸ Providers, on its row |
| Linked Codex accounts (`…codex-oauth`) | Settings ▸ Providers, on its row |
| Connected forge tokens (`…forge-token`) | Settings ▸ Forge, on its row |
| Any CSV you exported | wherever you saved it |
| The Claude account *Use in CLI* last wrote to the CLI | uninstalling does not put the previous one back; `/login` or another switch does |
| The session hooks, if you switched them on | switch them off **before** uninstalling |

The hooks are the one thing that keeps running once Sissy is gone: the script
they name lives in Sissy's folder, not the app bundle, so dragging the app to the
Trash does not stop them. Delete the folder and they go inert — but they are
still lines in another program's config, so take them out by hand.

## How it works

One process. Sissy watches the log directories and prices each turn as it lands;
the readings that are not a log tail — limits, forge counters, vendor status,
commit identity — are polls beside it. Counting happens while Sissy runs and
resumes at the byte it stopped at, so *Start at login* is what keeps a day
complete.

There is no price table in the source. Rates come from
[LiteLLM](https://github.com/BerriAI/litellm) at runtime, with a generated
snapshot compiled in as the offline floor, so a CLI that ships a new model prices
correctly without a Sissy release. [`ccusage`](https://github.com/ccusage/ccusage)
prices from LiteLLM too, which is why the two agree; CI asserts it.

If they disagree on your machine, check `ccusage --version` first — a Homebrew
install pinned at 20.1.0 misprices 1-hour cache writes and never upgrades off
itself.

## Configuration

Nothing has to be configured. The app writes
`~/Library/Application Support/Sissy/server.json`; rows marked ▸ are also in
Settings.

| Key | Default | Effect |
|---|---|---|
| `providers` | auto-detect | force `claudeCode` / `codex` on or off ▸ |
| `claudeDataDir`, `codexDataDir` | `~/.claude/projects`, `~/.codex/sessions` | where to look |
| `forgeCounters` | all on | which of `merged` / `issues` / `comments` a forge row reads; one off is not fetched ▸ |
| `statusChecks` | `true` | read each vendor's public status page ▸ |
| `keepAwake` | `off` | `auto` holds while agents work, releasing after 10 min of silence; `on` holds for 8 hours ▸ |
| `keepScreenAwake` | `true` | whether that hold covers the screen ▸ |
| `agentHooks` | `false` | register the `SessionStart` hook with both CLIs ▸ |
| `historyRetentionDays` | `90` | days of history kept; `0` records none ▸ |
| `remotePricing` | `true` | fetch rates at runtime; `false` pins to the built-in snapshot |
| `pricingOverride` | none | per-model rates that win over both sources |
| `pollIntervalSeconds` | `60` | safety-net poll between filesystem events |

Forge connections are not here — they live in `forge-connections.json`, with
their tokens in the keychain, and Settings ▸ Forge is the way to change them.

## Build from source

```bash
brew install xcodegen
cd app && xcodegen generate
xcodebuild -project Sissy.xcodeproj -scheme Sissy -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` is what builds it without an Apple Developer account,
and what CI passes. Drop it and set `DEVELOPMENT_TEAM` to yours for a signed
bundle. [CONTRIBUTING.md](CONTRIBUTING.md) has the dev build, the linters, the
self-test, and what Sissy will and will not take.

## Credits

Nothing third-party links into Sissy. Its reading of the Claude Code and Codex
log formats, and its pricing, follow
[`ccusage`](https://github.com/ccusage/ccusage); the rates come from
[LiteLLM](https://github.com/BerriAI/litellm). [CREDITS.md](CREDITS.md) says it
properly and covers the vendor marks Sissy draws.

## The name

Named after my cat: she naps, judges, demands cuddles (A LOT of cuddles), and is,
objectively, fabulous. The icon is her.

## License

The source code is [MIT](./LICENSE). Sissy's name and her artwork are not, and
[NOTICE](./NOTICE) says what that means. Fork it, ship it, sell it; just not
wearing her face.
