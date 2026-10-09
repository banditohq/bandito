<p align="center">
  <img src="brand/logo/bandito-icon.svg" width="120" alt="Bandito">
</p>

<h1 align="center">Bandito</h1>

<p align="center"><b>Your AI crew. On your own server.</b><br>
Claude Code, Codex and Grok agents that keep working after you close the laptop.</p>

<p align="center">
  <a href="https://bandito.dev">bandito.dev</a> ·
  <a href="https://x.com/banditohq">@banditohq</a>
</p>

---

> **Status:** early development, building in public. The daemon installs with one command (below); the Mac app is on its way.

## What it is

- **A tiny daemon on your server.** Rust, one binary, runs as a service. No Electron, no headless browser.
- **Native apps.** SwiftUI for Mac and iPhone. Close the lid, your crew keeps working; approve risky steps from the lock screen.
- **The agents you already use.** Claude Code, Codex and Grok through their official CLIs, or straight API keys.
- **A crew, not a chat.** Agents with roles and schedules that message each other and report back to you.

## Install

On Linux or macOS (x86_64 or arm64), one command:

```sh
curl -fsSL https://bandito.dev/install.sh | sh
```

It puts `bandito` in `~/.local/bin`, checks the release SHA-256, and starts the daemon as a user service (systemd on Linux, launchd on macOS). Then open the Bandito app, choose **Add server**, and run `bandito pair` on the server to get the code.

Manual install: download `bandito-<target>.tar.gz` and its `.sha256` from the latest release, run `sha256sum -c bandito-<target>.tar.gz.sha256`, unpack, and move `bandito` into a directory on your `PATH`.

```sh
bandito service install [--listen 127.0.0.1:7878]  # start now and at login / boot
bandito service status [--json]
bandito service uninstall                           # stops the service, keeps your data
bandito info [--json]                               # version, data dir, daemon state
bandito pair [--json]                               # one-time code for the app
```

On Linux the service stops at logout unless lingering is on. The installer prints the command when it can't enable it: `sudo loginctl enable-linger <user>`. Without systemd (WSL without `systemd=true`, containers) Bandito runs as a plain background process and does not survive a reboot.

## Repository layout

| Path | What |
|---|---|
| `daemon/` | The server daemon (Rust) |
| `apps/` | Mac and iPhone apps (SwiftUI) |
| `docs/` | Documentation |
| `brand/` | Logos and press kit |

## License

[Functional Source License 1.1, ALv2 Future License](LICENSE.md). Use it, read it, change it, self-host it. You can't sell a competing product built from it. Every release becomes Apache 2.0 two years after it ships.
