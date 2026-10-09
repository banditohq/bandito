# QA runbook: isolated test copies

Overnight and manual QA runs use pairs of a **QA daemon** and a **QA copy of the app**. A pair never touches the
installed Bandito: not `/Applications/Bandito.app`, not `~/.bandito`, not `~/.local/bin/bandito`, not the launchd
service `dev.bandito.daemon`, not `dev.bandito.mac` or `dev.bandito.mac.debug` defaults. Up to five pairs (n = 1..5).

## What lives where (n = 1..5)

| Thing | Where / name |
| --- | --- |
| QA daemon home | `~/.cache/bandito-qa/<n>/home` |
| QA daemon | `bandito --home … daemon --listen 127.0.0.1:(17880+n)` |
| Daemon log, pid, token | `~/.cache/bandito-qa/<n>/daemon.log`, `daemon.pid`, `token` (mode 0600) |
| QA app copy | `~/.cache/bandito-qa/<n>/Bandito QA<n>.app` |
| QA bundle id | `dev.bandito.mac.debug.qa<n>` (Keychain names `dev.bandito.debug.qa<n>.*`, debug secret files of the same prefix) |
| Command channel | DistributedNotification `dev.bandito.qa.dev.bandito.mac.debug.qa<n>` |
| Builds | `~/.cache/bandito-build/qa-xcode` (app), `~/.cache/bandito-build/qa-target` (daemon) |

The QA app is a DEBUG build. Its QA hooks (`apps/mac/BanditoKit/Sources/BanditoUI/App/QAHooks.swift`) do not exist in
a release build. A QA copy never installs Bandito on this Mac: `LocalInstaller` refuses to run in it.

## Order of a run

```sh
scripts/qa/server.sh up 1              # daemon on 127.0.0.1:17881, paired; token file written, not printed
scripts/qa/app.sh build                # Debug build once (xcodegen + xcodebuild), prints the app path
scripts/qa/app.sh launch 1             # copy to Bandito QA1.app, bundle id qa1, open with -qa.server/-qa.tokenFile
scripts/qa/shot.sh 1 /tmp/qa/team.png  # screenshot of the main window (needs Screen Recording for the terminal)
scripts/qa/cmd.sh 1 mode files         # command channel, see below
scripts/qa/cmd.sh 1 window 900x600
scripts/qa/sweep.sh 1 ~/Desktop/qa-run # every mode and sheet at 900x600, 1200x800, 1600x1000
scripts/qa/app.sh quit 1
scripts/qa/server.sh down 1
```

`scripts/qa/app.sh launch 1 --onboarding` starts the copy with no server and onboarding from zero (its defaults are
deleted first). Extra arguments are passed to the app, for example `-qa.mode files -qa.window 1200x800`.

## Commands (`cmd.sh <n> <command>`)

- `mode team|files|terminals|browser|screen|server`
- `sheet newAgent|account|addServer`, `dismiss`
- `window <W>x<H>`: resizes and centres the main window (SwiftUI keeps at least 900×600)
- `files <path>`: opens Files at a folder on the QA server
- `tab overview|workspaces|secrets|ports|devices|updates|journal`: opens Server mode on that section
- `settings`, `onboarding`

Unknown commands are logged by the app as `QA unknown command …` (Console.app, or `log stream`).

## Isolation rules

- Never run `Bandito.app` from the build; only the copies named `Bandito QA<n>.app` are launched.
- `app.sh` and `server.sh` refuse any bundle id that does not end in `.qa<digit>`, and any n outside 1..5.
- `server.sh down` stops only the pid in `daemon.pid` whose command line names this QA home.
- `app.sh quit` and `shot.sh` act only on processes whose executable path is the copy's own path.
- Do not point a QA copy at a real server: `-qa.server` takes a loopback URL made by `server.sh`.
  The onboarding flow can reach the account service; do not sign in with a real account from a QA copy.

## Cleaning up

```sh
scripts/qa/app.sh quit 1
scripts/qa/app.sh reset 1      # defaults, saved state, container/support/cache of dev.bandito.mac.debug.qa1,
                               # and its debug secret files (dev.bandito.debug.qa1.*); the copy stays built
scripts/qa/server.sh down 1
scripts/qa/server.sh up 1 --fresh   # only when the daemon home itself must start empty
rm -rf ~/.cache/bandito-qa/1        # everything of pair 1 (home, token, log, app copy)
```

`reset` does not touch the debug secret folder of other debug builds (`Bandito Debug/secrets/`): only the files whose
names start with `dev.bandito.debug.qa<n>.`. After `server.sh up <n> --fresh` the daemon has new tokens: run
`app.sh reset <n>` before the next launch, otherwise the copy keeps the token of its saved server.

## Known limits

- Screenshots need Screen Recording permission for the terminal that runs `shot.sh`. Without it `screencapture`
  writes a blank image without an error: check the picture.
- `window` cannot go below SwiftUI's minimum (900×600).
- A QA copy runs the app's normal update check (Sparkle) against the public appcast; the QA tooling does not isolate it.
