# Terraria — dedicated server

A native-Linux Terraria dedicated server. No SteamCMD, no Proton, no wine —
the server is a small checksummed download from terraria.org, and a world
generates in seconds on first boot.

Built for Unraid, but it is an ordinary container and runs anywhere.

```bash
docker run -d --name terraria \
  -p 7777:7777/tcp \
  -e WORLD_NAME="World" \
  -e MAX_PLAYERS=8 \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  ferment9348/terraria:latest
```

Or with compose:

```yaml
services:
  terraria:
    image: ferment9348/terraria:latest
    restart: unless-stopped
    ports:
      - "7777:7777/tcp"
    environment:
      WORLD_NAME: "World"
      MAX_PLAYERS: "8"
    volumes:
      - ./data/terraria:/serverdata/serverfiles
```

## Ports

| Port | Proto | Purpose                                              |
| ---- | ----- | ----------------------------------------------------- |
| 7777 | TCP   | Game traffic, the only port to forward.                |

Terraria uses TCP on 7777 — an ARK server's 7777 is UDP, so the two coexist
fine on the same host and port number.

## Common settings

| Variable           | Default | Notes                                                    |
| ------------------- | ------- | ---------------------------------------------------------- |
| `WORLD_NAME`        | `World` | Picks which world file loads. A new name generates a NEW world; it never renames one. |
| `WORLD_SIZE`        | `2`     | 1 small, 2 medium, 3 large. Only used the first time a world generates. |
| `DIFFICULTY`        | `0`     | 0 classic, 1 expert, 2 master, 3 journey. First generation only. |
| `MAX_PLAYERS`       | `8`     | Applied on every restart.                                   |
| `SRV_PWD`           | empty   | Join password. Blank for an open server.                    |
| `TERRARIA_VERSION`  | `1458`  | Server build to install. Change with `TERRARIA_SHA256`, see below. |
| `TERRARIA_SHA256`   | pinned  | Checksum of the build above. Must match, or the container refuses to install anything. |
| `STOP_TIMEOUT`      | `6`     | Seconds for a save-and-exit before force kill.               |
| `UID` / `GID`       | `99` / `100` | Unraid defaults.                                        |

Full list in the [README](https://github.com/blckassassin/ArkSA/blob/main/games/terraria/README.md).

## Worth knowing

**Change the version and checksum together.** `TERRARIA_VERSION` and
`TERRARIA_SHA256` are a pair. Bump one without the other and the checksum
check fails before anything is unpacked — the container logs the mismatch and
exits rather than running an unverified binary.

**Settings reapply on every restart**, except World Name, which points at a
different world file rather than renaming the current one. The log lists the
worlds it finds on disk whenever the name you set does not match one of them.

**Send console commands with `docker exec`** — there is no RCON:

```bash
docker exec terraria /opt/scripts/console.sh say hello
```

**Worldgen and save progress are collapsed in the log**, on purpose. Terraria
prints a line per 0.1% of every generation phase — tens of thousands of lines
for one world — which can outrun a log driver badly enough to look like a
hung server. Everything else, including chat and joins/leaves, passes through
untouched.

**The server saves on stop.** `docker stop` tells Terraria to save and exit,
then waits up to `STOP_TIMEOUT` (default 6s) before force-killing — chosen to
finish inside Docker's own 10s stop grace, so the default container stop
timeout is fine as-is.
