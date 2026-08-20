# ARK: Survival Ascended — dedicated server

A SteamCMD-based ASA dedicated server. Wildcard ships no native Linux server
binary, so this installs the **Windows** depot and runs `ArkAscendedServer.exe`
under GE-Proton. Both SteamCMD and Proton are fetched on first start, which
keeps the image small.

Built for Unraid, but it is an ordinary container and runs anywhere.

```bash
docker run -d --name ark-sa \
  -p 7777:7777/udp -p 27020:27020/tcp \
  --ulimit nofile=1048576:1048576 \
  --stop-timeout 150 \
  -e SERVER_NAME="My Server" \
  -e SRV_ADMIN_PWD="change-this" \
  -v /path/to/serverfiles:/serverdata/serverfiles \
  -v /path/to/steamcmd:/serverdata/steamcmd \
  ferment9348/ark-survival-ascended:latest
```

## Before you start

- **Disk:** about 15GB installed, growing with saves and mods. Prefer an SSD —
  ARK is heavy on random I/O, so spinning disks slow startup and world saves.
- **RAM:** 16GB is a sensible floor. A stock `TheIsland_WP` server settles
  around 10GB.
- **First boot is slow and quiet.** A ~13GB download, then Proton builds its
  prefix. After that the server starts in well under a minute.

## Ports

| Port  | Proto | Purpose                                                  |
| ----- | ----- | -------------------------------------------------------- |
| 7777  | UDP   | Game traffic. **The only one you must forward.**          |
| 7778  | UDP   | Peer port. Worth trying for flaky connects.               |
| 27015 | UDP   | Legacy Steam query port. Vestigial — ASA discovery is EOS. |
| 27020 | TCP   | RCON. Forward only to administer from outside the LAN.     |

## Common settings

| Variable        | Default          | Notes                                              |
| --------------- | ---------------- | -------------------------------------------------- |
| `SERVER_NAME`   | `ASA Server`     | Session name in the server browser.                 |
| `MAP`           | `TheIsland_WP`   | Needs the `_WP` suffix; the ASE name will not load. |
| `MAX_PLAYERS`   | `20`             | Becomes `-WinLiveMaxPlayers`.                       |
| `SRV_ADMIN_PWD` | `adminpassword`  | Admin **and** RCON password. Change it.             |
| `MODS`          | empty            | Comma-separated CurseForge project IDs.             |
| `CROSSPLAY`     | `false`          | `true` lets Epic players join.                      |
| `PROTON_VERSION`| `GE-Proton10-34` | Pinned deliberately — see below.                    |
| `DEBUG`         | `false`          | `true` captures verbose wine and Proton logs.       |
| `UID` / `GID`   | `99` / `100`     | Unraid defaults.                                    |

Full list in the [README](https://github.com/blckassassin/ArkSA).

## Worth knowing

**Proton is pinned, not tracking `latest`.** `PROTON_VERSION` defaults to the
build this image was tested against, so an upstream Proton release cannot break
your server overnight. The container warns in its log if you run a different
one. There are third-party reports of GE-Proton 11 regressing on
`ArkAscendedServer.exe`, but this image has not confirmed them — treat newer
builds as untested here rather than known-bad.

**Stopping saves the world.** On `docker stop` it sends `SaveWorld` over RCON,
then `DoExit`, and only force-kills after `STOP_TIMEOUT`. Give the container a
stop timeout above that — on Unraid, Settings → Docker → *Default shutdown
time-out* — or it gets killed mid-shutdown.

**The engine log is in the container log**, so `docker logs` shows what ARK is
actually doing, not just the wrapper.

**ARK writes your passwords into `ShooterGame.log`** in clear text. Nothing here
can prevent that; treat that file as sensitive before pasting it anywhere.

## Tags

`latest` tracks the newest release. **The `1.0.x` tags and the `1.0` tag are
broken and withdrawn** — they predate a fix without which the server never
starts. Use `1.1.0` or later.

## Unraid

Add `templates/ark-survival-ascended.xml` from the repository, or find
**ARK-Survival-Ascended** in Community Applications.

## Source and issues

[github.com/blckassassin/ArkSA](https://github.com/blckassassin/ArkSA) — MIT.
Structure and environment-variable naming follow
[ich777's](https://github.com/ich777/docker-steamcmd-server) game server
containers.
