# Contributing

Thanks for looking. Sissy is a small, opinionated app, so the most useful thing
this page can do is tell you what it is opinionated *about* before you spend an
evening on a patch.

## Getting it building

You need macOS 26 or later and Xcode 26 or later. Everything else comes from
Homebrew:

```bash
brew install xcodegen swiftlint xcbeautify shellcheck actionlint
```

`Sissy.xcodeproj` is **generated** and not tracked. Regenerate it, and
regenerate it again whenever you add or remove a Swift file:

```bash
cd app
xcodegen generate
xcodebuild -project Sissy.xcodeproj -scheme Sissy   -configuration Debug build
xcodebuild -project Sissy.xcodeproj -scheme sissy-cli -configuration Debug build
```

Never hand-edit `Sissy.xcodeproj`; edit `app/project.yml`. A `cannot find X in
scope` right after switching branches almost always means the project file is
stale.

To run what you have changed, build the signed dev app rather than launching
the plain `xcodebuild` product:

```bash
scripts/dev-build-app.sh
```

It builds into `~/.cache/sissy/build-dev`, clears dev bundles other worktrees
left behind, and relaunches, so exactly one dev Sissy exists whichever branch
you are on. It has its own `Sissy-Dev` support directory, so it never touches
the state of a Sissy you have installed. `Start at login` and the legacy-agent
retirement both go through `SMAppService`, which needs a normally signed bundle:
`CODE_SIGNING_ALLOWED=NO` is fine for CI, not for testing those.

## Before you push

```bash
pip install pre-commit && pre-commit install   # once per clone
```

Every commit then runs `swift-format`, `swiftlint`, `shellcheck` and
`actionlint` against what you changed. They are the same tools CI runs, so
there is no version drift to discover later. `pre-commit run --all-files` does the whole
tree.

The two gates that block a merge are formatting and linting:

```bash
xcrun swift-format lint --recursive --strict app/Sissy app/SissyCore app/SissyTests
swiftlint lint --quiet --lenient
```

Tests are CI's job (`xcodebuild test` is too slow to run per commit), but if you
touched the engine, run the self-test yourself. **Build first**, because
`-showBuildSettings` happily points at whatever the last successful build left
behind:

```bash
cd app
xcodebuild -project Sissy.xcodeproj -scheme sissy-cli -configuration Debug build \
  && "$(xcodebuild -scheme sissy-cli -showBuildSettings \
        | awk -F= '/BUILT_PRODUCTS_DIR/{print $2; exit}' | xargs)/sissy-cli" --self-test
```

## Commits and pull requests

Conventional Commits, one concern per commit, never a refactor mixed into a
feature. Subject-only is the house style: add a body only when the *why* is not
visible from the subject and the diff, and keep it to a few lines. Pull request
descriptions are short too; the title and the commits usually say it.

Do not bump a version anywhere. `scripts/version.sh` derives `MARKETING_VERSION`
from the latest git tag and `CURRENT_PROJECT_VERSION` from the commit count; a
literal in a plist is a bug, and a stray tag anywhere in history becomes the
version.

## What Sissy will and will not take

`AGENTS.md` at the root is the long version: every settled design decision,
with the measurement that settled it. It is written for coding agents but it is
the honest answer to "why is it like that", and it is worth grepping before
proposing a change. The short version:

**Welcome.**

- A new CLI to meter. If it writes append-only JSONL, it is a `SourceAdapter`
  (a few hundred lines) rather than a new reader. See
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). If it does not, it is a new
  `UsageProvider`.
- Anything that makes a reading more accurate, with the measurement that shows
  it. `ccusage` is the oracle: a pricing or parsing change is judged by whether
  Sissy still agrees with `npx ccusage@latest` on real logs, and CI asserts it.
- Bug fixes, accessibility fixes, and copy that says what the app actually does.

**Please open an issue first.**

- Anything that asks the user for a permission at launch. Sissy's first run
  asks for nothing; a module that is off must not exist as far as the system is
  concerned.
- Anything that outlives Sissy on the machine, or writes outside its own
  folder. There are exactly three exceptions today — the usage archive, the
  session hooks and the archived Claude credentials — and every one of them is
  reversible from Settings.
- Anything that opens a port, a socket or a second process.
- A hand-maintained price table. Rates come from LiteLLM at runtime with a
  generated seed as the floor; a new model must not need a release.
- A third-party dependency. Sissy links none today, which is why no licence
  has to travel with the binary and no notice file is bundled.
- A decorative signal on the cost axis. The panel reports pressure, not mood.

## Reporting a bug

Open an issue with the output of **Settings ▸ About ▸ Copy diagnostics**. It
carries the version, the OS, what the readers have found and which `ccusage`
builds are on the machine, and no costs, no project paths and no credentials.
If your report is about a number, say what `ccusage --version` prints: a stale
Homebrew install reports a different figure and will never upgrade off itself.

Security problems do not go in an issue. See [SECURITY.md](SECURITY.md).
