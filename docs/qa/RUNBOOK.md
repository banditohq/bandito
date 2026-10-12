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
- `sheet newAgent|account|addServer|reportProblem|readyTeam:<bundle id>`, `dismiss`
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

## Phone access (QA of the iPhone listener)

Check it on a QA pair (never the installed daemon). The listener needs an address that is not loopback, so a QA daemon
turns it on with `phone_access = lan` (port 7879 by default; give `phone_port` another one if two QA daemons run).

1. `scripts/qa/server.sh up 1`, then ask the QA daemon over its own socket: `bandito --home ~/.cache/bandito-qa/1/home pair --phone`
   says "phone access is off" (nothing listens besides 127.0.0.1:17881).
2. In the QA app copy: Settings → Servers → the QA server → iPhone. Choose "On the local network". The line under the switch
   says "Listening on [::]:7879, 0.0.0.0:7879" (or the failure). Look at German and Russian at the narrowest window.
   `tailscale` with no Tailscale on the machine says "No Tailscale address…" and listens on nothing.
3. `~/.cache/bandito-qa/1/home/tls/` holds `phone-cert.pem` and `phone-key.pem`, both mode 0600; the folder 0700.
   `openssl x509 -in …/phone-cert.pem -outform der | shasum -a 256` equals `tls_fingerprint` in `daemon.info` and `fp=` in the link.
4. "Connect iPhone" shows the QR code, the six words and the addresses. `bandito … pair --phone` prints the same kind of link
   (`bandito://pair?v=1&code=…&fp=…&name=…&host=…`). A phone, or `openssl s_client -connect <lan ip>:7879 -tls1_3`, reaches the
   TLS handshake; `openssl s_client -tls1_2` and plain `curl http://<lan ip>:7879/v1/health` get nothing.
5. Without a device token every route but the anonymous hello and `pair.redeem` is refused: `curl -k https://<lan ip>:7879/v1/files/raw?path=/etc/hosts` is 401.
   Eleven anonymous WebSocket upgrades from one address within ten minutes: the eleventh is 429.
6. Switch the setting off: the port closes at once and open phone connections end; switch it on again: the fingerprint is the same.
   Restart the QA daemon (`server.sh down 1`, `up 1`): the same.
7. Disconnect a device in the list: its open connection ends and the next request with its token is 401.

The daemon's own tests do all of this on loopback (`cargo test phone`); the app's rules are in `PhoneAccessRulesTests` and
`PhonePairLinkTests`, the layout in the `settings-server-detail` and `sheet-phone-pair` cases of the layout audit.

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
