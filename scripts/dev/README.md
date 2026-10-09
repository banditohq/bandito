# Developer scripts

Local helpers for working on Bandito. None of them touches a real host, and none of them changes your `~/.ssh`.

## Test server in Docker

A clean Ubuntu 24.04 with sshd and no systemd, to rehearse the install over SSH the way the Mac app does it.

```sh
sh scripts/dev/testbed.sh up        # build the image, start the container, print how to connect
sh scripts/dev/testbed.sh ssh       # log in as dev
sh scripts/dev/testbed.sh status
sh scripts/dev/testbed.sh logs -f   # sshd log
sh scripts/dev/testbed.sh down      # remove the container (the image stays)
```

- Listens on `127.0.0.1:2222` only. Change it with `TESTBED_PORT=2223 sh scripts/dev/testbed.sh up`.
- Login is by key only: `~/.cache/bandito-testbed/id_ed25519`. The key and `known_hosts` live in that cache dir.
- `dev` has a password for `sudo` (in `~/.cache/bandito-testbed/dev-password`). The app must ask for it in its terminal, not in Bandito. For passwordless sudo build the other variant: `SUDO_NOPASSWD=1 sh scripts/dev/testbed.sh up` (separate image tag, `bandito-testbed:nopasswd`).
- The host key is made when the image is built, so it stays the same across `down` and `up`. Each sudo variant has its own `known_hosts` file. If you rebuild an image, ssh will warn that the host key changed. Remove the old entry with the command `up` prints, for example `ssh-keygen -R '[127.0.0.1]:2222' -f ~/.cache/bandito-testbed/known_hosts`.
- `up` prints a block for `~/.ssh/config`. The script does not write it; add it yourself if you want it.

## Linux daemon binary

```sh
sh scripts/dev/linux-binary.sh
```

Builds `bandito` for the Docker host's architecture (aarch64 on Apple silicon) in a `rust:1-bookworm` container. Target and cargo registry live in named volumes, so rebuilds are incremental. It writes `~/.cache/bandito-testbed/bandito-<target>` and a release-style `bandito-<target>.tar.gz` (binary, `LICENSE.md`, `README.md`), and prints both paths.

## Rehearsal

```sh
sh scripts/dev/rehearse.sh
```

Runs the server side of the install against the testbed: the archive is copied in, `install.sh --archive … --no-service` runs, then `service install --json`, `info --json` and `pair --json`. The container is removed at the end. Each run starts from a fresh container. Options:

- `REHEARSE_ARCHIVE=<path.tar.gz>` skips the build and uses that archive.
- `REHEARSE_KEEP=1` leaves the container running afterwards.
- The full log is in `~/.cache/bandito-testbed/rehearse.log`.

Requirements: Docker running, `ssh`, `scp`, `openssl`, and `lsof` or `nc` for the port check.
