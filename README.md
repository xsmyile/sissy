<div align="center">

<img src="docs/assets/sissy.png" alt="Sissy" width="200" />

# Sissy

A menubar companion for **Claude Code** and **Codex**.

A pixel-art cat watches your token meter and gets moodier the more you spend.

Named after my cat — she naps, judges, demands cuddles (A LOT of cuddles), and is, objectively, fabulous.

[Install](#install) • [How it works](#how-it-works) • [Build from source](#build-from-source) • [Desk companion](#desk-companion)

</div>

## Install

macOS 26+ on Apple Silicon or Intel.

1. Grab the latest `Sissy-x.y.z.dmg` from [Releases](../../releases/latest).
2. Open the DMG and drag **Sissy** into Applications.
3. Launch Sissy. The cat lives in the menubar.
4. Menubar → **Start Server** to begin tailing token usage.

The DMG is Developer ID signed and notarized — no `xattr` workaround, no right-click → Open.

## How it works

A small daemon on your Mac tails each supported CLI's session log, sums the day's spend across all of them, and shows the combined total in the menubar.

Currently supports Claude Code (`~/.claude/projects/`) and Codex (`~/.codex/sessions/`, also honors `CODEX_HOME`). Codex auto-enables when the rollout directory has activity in the last 7 days; force it on or off via `providers` in `~/Library/Application Support/Sissy/server.json`. When two or more providers are active the menubar grows a **Breakdown** submenu with the per-CLI split.

## Build from source

```bash
scripts/dev-build-app.sh
open app/build-dev/Build/Products/Debug/Sissy.app
```

Menubar → **Server** toggles the bundled LaunchAgent. When switched on it registers the daemon so it restarts on login; turning it off unregisters the agent. That control requires a normally signed app build — `CODE_SIGNING_ALLOWED=NO` is fine for CI but not for testing Server start/stop locally.

## Desk companion

A hardware companion — a tiny pixel-art cat on an OLED that mirrors the menubar — is in development. Code lives in [`firmware/`](firmware) and is not built into the release. Watch this repo for updates.

## Credits

Usage parsing follows [`ccusage`](https://github.com/ryoppippi/ccusage) — both the JSONL schemas (Claude Code and Codex rollouts) and per-model pricing come from there. The daemon's WebSocket server is [SwiftNIO](https://github.com/apple/swift-nio).

Status: alpha.

## License

[MIT](./LICENSE).
