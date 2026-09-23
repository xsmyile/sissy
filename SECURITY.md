# Security

## Reporting a vulnerability

Please report privately, not in a public issue:
**[Report a vulnerability](https://github.com/xsmyile/sissy/security/advisories/new)**
(GitHub ▸ Security ▸ Advisories).

Include what you did, what happened, and the Sissy version, which
`Settings ▸ About ▸ Copy diagnostics` has. You will get an acknowledgement, and a
fix ships in the next release unless the issue is being actively exploited, in
which case it ships on its own. Sissy is one person's side project: expect a
human reply, not an SLA.

Only the latest release is supported. There are no backports.

## The surface

Sissy runs unsandboxed with the network-client entitlement, in a single process,
and binds no port.

**Files it reads.** The two session-log trees: `~/.claude/projects` and
`~/.codex/sessions`, or wherever `claudeDataDir` and `CODEX_HOME` point. Also
each CLI's own profile and credential files beside them. In every repository a
session has worked in, the `.git` entry and the worktree list under it; those
repositories can be anywhere on disk. On the press of the button that offers
them, `~/.config/gh/hosts.yml` and `~/.config/glab-cli/config.yml`. Outside your
home directory it stats the usual `git` install prefixes (below), and reads
Homebrew's `bin` when you press **Copy diagnostics**, to say which `ccusage`
builds are installed.

**What it asks the kernel.** `KERN_PROC_ALL`, `proc_pidpath`,
`proc_pid_rusage` and `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. The last of these
returns the working directory, which is how a running agent is named after its
repository. `KERN_PROC_ALL` enumerates the whole process table, not only
yours; another user's entry is dropped there, on the credential in its table
entry, before any of the three per-process calls run, and those run only for
processes **running as you**. `KERN_PROCARGS2`, the one call that can return a
command line, is asked only of a process whose executable is a JavaScript
interpreter, which is the install shape where `argv[0]` names the CLI. No
entitlement, no TCC prompt, and any process running as you can ask the same.

**Programs it runs.** Each at an absolute path, never resolved through `PATH`:

| Program | For |
|---|---|
| `/usr/bin/security` | keychain items a CLI filed by shelling out to the same tool: Claude Code's credential, `gh`'s token. The tool is on those items' ACL and this process is not, so there is no Allow/Deny panel |
| `git` | what a repository would sign a commit as. From `/opt/homebrew`, `/usr/local` or `/opt/local`, falling back to `/usr/bin/git` only once `xcode-select -p` confirms the Command Line Tools are there. The shim opens an install dialog otherwise |
| `/usr/bin/xcode-select` | that one check |
| `/bin/sh -n` | **parses** the hook line before it is written, executing none of it. Runs when hooks are installed or reaffirmed, including at launch while the switch is on |

The `git` child's environment is replaced, not inherited: an inherited `GIT_DIR`
would answer for a repository the reader was never pointed at, and
`GIT_AUTHOR_EMAIL` would substitute itself for the reading. Those calls have a
10 s timeout and a `SIGKILL` two seconds after the `SIGTERM`; the `security`
calls have a 5 s timeout and no escalation, the tool having no dialog to wait
behind.

**Credentials it reads, never mints.** Claude Code's OAuth token from
`<config home>/.credentials.json`, or the login keychain through
`/usr/bin/security`; Codex's from `~/.codex/auth.json`. Sissy never refreshes
either, and never writes one back except on a Claude account switch you asked
for: both vendors rotate refresh tokens, and spending one would sign you out
of your own terminal. Codex's file is never written. A forge token is
offered, never taken: Sissy shows what `gh` or `glab` holds, warns that such a
token usually carries write access to every repository, and copies it only on
the press.

**Credentials it holds.** Four keychain items are Sissy's own:

| Item | Holds |
|---|---|
| `com.radonforge.sissy.claude-account` | a copy of each Claude credential seen active, so `Use in CLI` can switch back |
| `com.radonforge.sissy.claude-web` | the claude.ai session from the in-app login window |
| `com.radonforge.sissy.codex-oauth` | each linked Codex account's OpenAI credential, Sissy's own copy and the only one it renews |
| `com.radonforge.sissy.forge-token` | each forge connection's token, used to read activity counts and nothing else |

A Debug build files the same four under `com.radonforge.sissy.dev.*`, so a
development copy never reads or overwrites what the released app holds.

**Nothing on the wire is kept.** Every request goes through one ephemeral
session with no HTTP cache, cookie jar or credential store. A redirect to
another origin drops its credential headers, and one that would resend a
request body there is not followed. A refusal from that other origin is
reported as a failed request and never as the vendor refusing the credential,
so it signs nothing out. At each launch Sissy deletes the
`Cache.db`, `fsCachedData` and `HTTPStorages` cookie files that versions up to
0.2.3 left under `~/Library` for both bundle ids, and logs any of those
directories it could not list.

None reaches the frame, the logs, the diagnostics report or the CSV export. No
type the panel renders carries a token field, and
`ClaudeWebSessionSecrecyTests` plus the secrecy cases in `CodexAccountLinkTests`
hold that line for the two that are whole sessions.

**The one window that loads someone else's HTML.** `VendorLoginWindow` is a
`WKWebView` on a vendor's own login: claude.ai's, or OpenAI's for a Codex
account. It runs with a non-persistent cookie jar that dies with it, no address
bar, no tabs, and off-vendor links handed to the default browser instead of
followed. It opens only from a button, never from a poll or at launch. The
Codex sign-in is PKCE whose redirect is cancelled and read in the window:
nothing listens on the loopback port it names. Connecting a forge opens no
window at all.

**What it writes outside its own folder.** Four things. Only the logs happen on
their own; nothing touches another program's configuration or credentials
unless you ask for it:

| Written | When |
|---|---|
| a line in `~/.claude/settings.json` and one in `~/.codex/hooks.json` | only under `Name projects even when Sissy is off`; both point at a script in Sissy's own folder and both come out when you switch it off |
| Claude Code's keychain slot and its `.credentials.json` mirror | only when you pick an account with *Use in CLI*. Uninstalling does not switch it back |
| `~/Library/Logs/Sissy/`, rotated | always, and it outlives an uninstall |
| CSV files | only into the folder you choose when you press Export |

Nothing writes to a repository, a git config or a forge. The Identities page's
correction is a `git config --unset` put on your clipboard for you to run.

**Input it does not trust.** The session hook writes into a `checkout-inbox`
read as a boundary: `O_NOFOLLOW`, a regular file owned by this user, size-capped,
two absolute lines, consumed on read. The hook script strips its environment
before asking git anything, and accepts a checkout only where it is the
directory the session started in or an ancestor of it. Session logs, status
feeds, the LiteLLM price table, vendor and forge API replies, and the output of
each `git` call are all parsed as foreign input into typed values.

**What it never does.** No analytics, no crash reporting, no account of its own,
no telemetry, no port, no raw log content leaving the machine. The README's
*Privacy* section lists every host Sissy itself requests; a further destination
reached by one of those requests is a bug worth reporting. The login window is
the exception by construction: it renders the vendor's own page, so it loads
whatever that page loads and follows the redirects its sign-in needs.

## Out of scope

- Anything requiring an attacker already running code as your user. Sissy grants
  such an attacker no access it did not already have: the CLIs' credential files
  and every reading Sissy takes from the kernel are open to any process running
  as you, with or without Sissy.
- A vulnerability in Claude Code, Codex, `gh`, `glab`, `ccusage` or LiteLLM.
  Report those to the projects that own them.
