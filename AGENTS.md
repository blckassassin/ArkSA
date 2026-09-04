# AGENTS.md

Dedicated game server containers for Unraid. Two games live here today: **ARK:
Survival Ascended** (Debian + SteamCMD pulling the Windows depot, run under
GE-Proton) and **Terraria** (Debian, native Linux binary — no SteamCMD, no
Proton). Target platform is Unraid; each game's `docker-compose.yml` is for
local testing only.

## Layout

| Path                                   | What it is                                          |
| --------------------------------------- | --------------------------------------------------- |
| `games/<slug>/Dockerfile`              | Image definition for that game. Built with the repo root as context. |
| `games/<slug>/docker-compose.yml`      | Local testing only. Uses uid/gid 1000, not Unraid's 99/100. |
| `games/<slug>/scripts/`                | Game-specific scripts, copied to `/opt/scripts` in the image. |
| `games/<slug>/docs/dockerhub.md`       | Docker Hub long description, synced by CI on release. |
| `games/<slug>/README.md`               | That game's guide — except ASA, see Constraints.    |
| `games/ark-survival-ascended/scripts/rcon.py` | Minimal Source RCON client. No dependencies beyond stdlib. |
| `games/ark-survival-ascended/scripts/rcon-cli.sh` | Thin wrapper for `docker exec` use.             |
| `games/terraria/scripts/console.sh`    | Sends a command through Terraria's FIFO console.    |
| `shared/scripts/start.sh`              | Common root entrypoint, runs as root. Reconciles the `steam` uid/gid, fixes ownership, then `gosu` to that game's `start-server.sh`. |
| `templates/<slug>.xml`                 | Unraid Community Apps template for that game. CA requires one XML per app under `templates/`. |
| `ca_profile.xml`                       | CA repository profile, covering every game here. Must be at the root with a non-empty `<Profile>`, or submission is blocked. |
| `icon.png` / `icon.svg`                | ASA's icons, referenced by `ca_profile.xml` and its template. |
| `terraria.png` / `terraria.svg`        | Terraria's icons.                                    |
| `tools/icongen/`                       | Generates the per-game icon PNGs from source art.    |
| `tests/unit.sh`                        | Plain-assertion unit tests, no framework.            |
| `tests/e2e-terraria.sh`                | Boot/shutdown end-to-end test against a built Terraria image. |
| `.github/workflows/build.yml`          | CI: lints, builds every game, publishes on a `<slug>/v<version>` tag. |

## Build

```sh
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
docker build -f games/terraria/Dockerfile -t terraria-test .
```

## Test

There is no unit test framework beyond plain assertions. The checks that must
pass before a change ships:

```sh
shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh tests/*.sh
python3 -m py_compile games/ark-survival-ascended/scripts/rcon.py
bash tests/unit.sh
bash tests/e2e-terraria.sh terraria-test     # Terraria only; ASA's boot pulls ~13GB
```

Terraria's install is ~46MB and its e2e test above covers a real boot and
shutdown, so it needs no manual check beyond that. ASA is the opposite: a full
boot pulls ~13GB, so it stays a manual smoke run — start it and confirm it
reaches the SteamCMD step and prints the resolved uid/gid, then stop it there:

```sh
docker run --rm -e UID=1000 -e GID=1000 asa-test
```

## Constraints

- **Release tags are `<slug>/v<version>`.** e.g. `ark-survival-ascended/v1.5.0`.
  A bare `v1.2.3` triggers nothing at all.
- **ASA has no `games/ark-survival-ascended/README.md`.** Its guide is the root
  `README.md`, because every installed CA template's `<ReadMe>` freezes that
  URL and those users never receive a new template. This is deliberate, not an
  oversight — do not add one and do not point the ASA template's `<ReadMe>`
  anywhere else. Every other game gets `games/<slug>/README.md`.
- **Terraria's `STOP_TIMEOUT` is `6`, not ASA's `120`.** `6` plus a bounded 3s
  wait for the log reader must stay under Docker's 10s default stop grace
  (6+3=9s). Do not copy ASA's value over.
- **Both images run as the account `steam`, Terraria included**, because
  `shared/scripts/start.sh` hardcodes it in the `gosu` call.
- **`UID` is also a bash variable.** In `shared/scripts/start.sh` it is read
  into `TARGET_UID` rather than used directly, and `PUID`/`PGID` are accepted
  as aliases. Do not "simplify" that back to bare `${UID}`.
- **Terraria's stdout never gets piped to a live reader.** The runner
  (`games/terraria/scripts/start-server.sh`) writes the server's stdout to a
  plain file and mirrors a collapsed view of it into the container log
  separately. This is not cosmetic: Terraria emits one line per 0.1% of every
  worldgen/save phase, and piping that live into a reader makes the server
  itself run roughly 20x slower and can wedge the container log entirely.
  `VERBOSE_LOG=true` bypasses the collapsing for diagnosis without touching how
  the server itself is run. Do not "simplify" this into a live pipe.
- **Windows depot, not Linux (ASA only).** ASA has no native Linux server
  binary. SteamCMD is given `+@sSteamCmdForcePlatformType windows` and the exe
  runs under Proton. amd64 only — an arm64 image would be meaningless.
- **`ServerAdminPassword` must be the last `?` argument (ASA).** Anything after
  it is swallowed into the password value. See the ordering in
  `games/ark-survival-ascended/scripts/start-server.sh`.
- **Dash flags, not query params (ASA).** `-WinLiveMaxPlayers=` and `-port=`
  are the real settings; `?MaxPlayers=` and `?Port=` are silently ignored by
  ASA.
- **The config seed is write-once (ASA).** `GameUserSettings.ini` is written
  only when absent. Never make the container rewrite a file the user may have
  edited. Terraria's `serverconfig.txt` is the opposite by design — it is
  regenerated every boot, since Terraria only reads it at startup.
- **`HOME` is repointed at `<serverfiles>/home` (ASA).** `gosu` sets it from
  passwd, so `start-server.sh` overrides it after the privilege drop, not via
  `ENV`. SteamCMD's `depotcache` lives there and holds the manifest an
  incremental update diffs against. On the default `/home/steam` it is lost
  whenever the container is recreated, and the next update dies with
  `Access Denied` on the delta-source manifest because Steam does not issue
  request codes for superseded manifests. Do not move it back.
- **Graceful shutdown depends on RCON (ASA).** `SaveWorld` then `DoExit` over
  RCON, then a timed wait, then kill the wine prefix. A hard kill loses world
  state. Terraria has no RCON; its shutdown writes `exit` into a FIFO console
  instead (`games/terraria/scripts/console.sh`).
