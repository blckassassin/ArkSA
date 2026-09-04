# Terraria — dedicated server for Unraid

[![build](https://github.com/blckassassin/ArkSA/actions/workflows/build.yml/badge.svg)](https://github.com/blckassassin/ArkSA/actions/workflows/build.yml)
[![docker](https://img.shields.io/docker/v/ferment9348/terraria?sort=semver&label=docker%20hub)](https://hub.docker.com/r/ferment9348/terraria)
[![license](https://img.shields.io/badge/license-MIT-blue)](../../LICENSE)

Terraria ships a native Linux server binary, so this container is a lot
smaller and simpler than the ARK image next door: no SteamCMD, no Proton, no
wine. The server is a ~45MB zip from terraria.org, checksummed before it is
unpacked, and a world generates in seconds on first boot.

## Get the image

```bash
docker pull ferment9348/terraria:latest
```

Or build it yourself from the repo root — the Dockerfile expects to be built
with the repo root as context, not this directory:

```bash
git clone https://github.com/blckassassin/ArkSA.git
cd ArkSA
docker build -f games/terraria/Dockerfile -t ferment9348/terraria:latest .
```

`docker-compose.yml` in this folder does the same thing; run it from here with
`docker compose up -d`.

## Install on Unraid

1. Copy `templates/terraria.xml` to
   `/boot/config/plugins/dockerMan/templates-user/`.
2. Docker tab → **Add Container** → pick `Terraria` from the template
   dropdown.
3. Set your paths and world settings, then apply.

## Ports

| Port | Proto | What it does                                             |
| ---- | ----- | --------------------------------------------------------- |
| 7777 | TCP   | Game traffic. The only port to forward.                    |

Terraria uses **TCP** on 7777. An ARK: Survival Ascended server's game port is
**UDP** 7777, so the two can run on the same host with the same port number
and never collide.

## The version pin

Terraria has no auto-updater here — `TERRARIA_VERSION` names the exact build
to install (as it appears in terraria.org's download URL) and `TERRARIA_SHA256`
is the checksum of that build's zip, verified before anything is unpacked.

**Change them together.** If you bump `TERRARIA_VERSION` without also
updating `TERRARIA_SHA256` to match, the checksum check fails and the
container refuses to install anything — it logs the mismatch and exits rather
than running unverified code. With `restart: unless-stopped` that means a
crash loop, not silent corruption, but it will not start until both values
agree.

## Configuration

Almost every setting here is re-read and reapplied on **every** container
start, not just the first one — `serverconfig.txt` is rewritten each boot, so
changing Max Players or the password in the template and restarting takes
effect immediately. World generation options (World Size, Difficulty, World
Seed) are the exception in spirit, if not in mechanism: they only matter the
first time a given world file is generated, since Terraria stores them in the
world itself from then on.

| Variable          | Default  | Notes                                                              |
| ------------------ | -------- | ------------------------------------------------------------------- |
| `WORLD_NAME`       | `World`  | See below — this one does not behave like the others.               |
| `WORLD_SIZE`       | `2`      | `1` small, `2` medium, `3` large. Only used on first generation.     |
| `DIFFICULTY`       | `0`      | `0` classic, `1` expert, `2` master, `3` journey. First gen only.    |
| `WORLD_SEED`       | empty    | Optional. Blank means random. First gen only.                       |
| `MAX_PLAYERS`      | `8`      | Player slots. Applied on every restart.                             |
| `SRV_PWD`          | empty    | Join password. Blank for an open server.                            |
| `MOTD`             | empty    | Shown to players as they join.                                      |
| `SECURE`           | `1`      | Terraria's built-in anti-cheat validation. `1` on, `0` off.          |
| `UPNP`             | `0`      | Ask the router to auto-forward the game port via UPnP. `1` on, `0` off (default) — manual forwarding is more reliable. |
| `TERRARIA_VERSION` | `1458`   | See [The version pin](#the-version-pin).                             |
| `TERRARIA_SHA256`  | pinned   | See [The version pin](#the-version-pin).                             |
| `STOP_TIMEOUT`     | `6`      | Seconds to wait for a save-and-exit before force killing.            |
| `UID` / `GID`      | `99`/`100` | Unraid defaults.                                                    |
| `UMASK`            | `000`    | New files land as `666`, directories as `777`.                      |

### World Name is not a rename

`WORLD_NAME` picks which world file the server loads — `<worlds>/WORLD_NAME.wld`
— it does not rename anything on disk. Change it to a name that does not exist
yet and the server generates a **brand new** world under that name; the old
one is left exactly where it was. The container logs which worlds it found on
disk whenever the configured name does not match one of them, so you will see
this happening rather than wondering where your old world went.

Worlds live at `<serverfiles>/worlds/`, i.e. inside whatever host path you
mapped to `/serverdata/serverfiles`.

## Sending console commands

There is no RCON here — Terraria takes commands on its own console, and this
container wires that console to a named pipe so you can reach it without a
shell:

```bash
docker exec terraria /opt/scripts/console.sh say "restarting in 5 minutes"
docker exec terraria /opt/scripts/console.sh save
docker exec terraria /opt/scripts/console.sh exit
```

Any command Terraria's own console understands works here — it is passed
straight through.

## Reading the log

The container log carries the real Terraria server output, including chat,
joins, leaves, and the save it does on shutdown — all of that passes through
untouched. The one thing that does **not** pass through raw is the progress
counters: world generation prints one line per 0.1% of every phase, and a
save prints similarly dense percentage updates. Left alone, that is tens of
thousands of lines that can outrun the log driver badly enough to look like a
hung server when it is not. This container collapses each phase's counter
down to about one line per whole percentage point instead. Set `VERBOSE_LOG=true`
to get the firehose in the container log itself — every line Terraria emits,
uncollapsed. It cannot slow the server down: the server writes to a plain
file regardless of this setting, and `VERBOSE_LOG` only changes how much of
that file gets mirrored into the log downstream. It is noisy, not risky —
leave it off unless you are diagnosing something.

## Stopping safely

The server saves its world when the container stops — `docker stop` writes
`exit` to the console, which triggers Terraria's own save, then waits up to
`STOP_TIMEOUT` seconds before force-killing. The default `STOP_TIMEOUT` (6s)
is chosen to finish well inside Docker's own 10-second stop grace, so you do
not need to touch Unraid's container stop timeout for a small server. If you
raise `STOP_TIMEOUT`, raise the container's stop timeout to match, or Docker's
own kill can cut the save off first.

## License

MIT — see [LICENSE](../../LICENSE).
