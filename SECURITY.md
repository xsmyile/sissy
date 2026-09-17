# Security

## Reporting a vulnerability

Please report privately, not in a public issue:
**[Report a vulnerability](https://github.com/xsmyile/sissy/security/advisories/new)**
(GitHub ▸ Security ▸ Advisories).

Include what you did, what happened, and the Sissy version, which
`Settings ▸ About ▸ Copy diagnostics` has. You will get an acknowledgement, and a fix ships in
the next release unless the issue is being actively exploited, in which case it
ships on its own. Sissy is one person's side project: expect a human reply, not
an SLA.

Only the latest release is supported. There are no backports.

## What Sissy touches, so you know where to look

Sissy is a menu bar app that reads what AI coding CLIs already wrote to disk.
It runs unsandboxed with the network-client entitlement, keeps its metering in
a single process, and binds no port. The surface worth looking at is small, so
here it is:

**Files it reads.** The two session-log trees — `~/.claude/projects` and
`~/.codex/sessions`, or wherever `CLAUDE_CONFIG_DIR` and `CODEX_HOME` point —
the CLIs' own config files beside them, and the credential below. The one place
outside your home directory it reads is Homebrew's `bin`, and only when you
press **Copy diagnostics**, to say which `ccusage` builds are installed.

**Credentials it reads, never mints.** To show rate-limit windows, Sissy reads
Claude Code's own OAuth token. It comes from `<config home>/.credentials.json`
where the CLI keeps one, otherwise from the login keychain through
`/usr/bin/security`, which is on that item's ACL because the CLI filed it by
shelling out to the same tool. Sissy never refreshes that token (Anthropic's refresh tokens rotate, and
spending one would sign you out of your own terminal) and never writes it back,
except on an explicit account switch you asked for.

**Credentials it holds.** Two keychain items are Sissy's own: an archived copy
of each Claude account credential it has seen, so `Use in CLI` can switch
between them, and the claude.ai session created by the in-app login window.
Neither ever reaches the frame, the logs, the diagnostics report or the CSV
export, and there is a test suite whose only job is holding that line.

**The one window that loads someone else's HTML.** `ClaudeWebLoginWindow` is a
`WKWebView` pointed at claude.ai's own login, with a non-persistent cookie jar
that dies with the window, no address bar, no tabs, and link clicks that leave
claude.ai handed to the default browser instead of followed. It opens only from
the button in Settings, never from a poll or at launch.

**Files it writes outside its own folder.** Nothing does so unless you switch
it on. Today one switch can, `Name projects even when Sissy is off`, and it
writes one line in `~/.claude/settings.json` and one in `~/.codex/hooks.json`,
both pointing at a script inside Sissy's own folder. Switching it off takes both
back out.

**Input it does not trust.** The session hook writes into a `checkout-inbox`
that Sissy reads as a boundary: `O_NOFOLLOW`, a regular file owned by this
user, size-capped, two absolute lines, entries consumed on read. Session logs,
vendor status feeds, the LiteLLM price table and every claude.ai reply are all
parsed as foreign input into typed values.

**What it never does.** No analytics, no crash reporting, no account of its own,
no telemetry, no port, no raw log content leaving the machine. The complete list
of hosts Sissy talks to is in the README's *Privacy* section; anything else
reaching the network is a bug worth reporting here.

## Out of scope

- Anything requiring an attacker who is already running code as your user. Every
  credential named above is readable by any process running as you, with or
  without Sissy. That is a property of how the CLIs store them.
- A vulnerability in Claude Code, Codex, `ccusage` or LiteLLM. Please report
  those to the projects that own them.
