# AGENTS.md

ARK: Survival Ascended dedicated server container. Debian + SteamCMD pulling the
Windows depot, run under GE-Proton. Target platform is Unraid; the compose file
is for local testing.

## Layout

| Path                          | What it is                                          |
| ----------------------------- | --------------------------------------------------- |
| `Dockerfile`                  | Image definition. Copies `scripts/` to `/opt/scripts`. |
| `scripts/start.sh`            | Entrypoint, runs as root. Reconciles the steam uid/gid, fixes ownership, then `gosu` to `start-server.sh`. |
| `scripts/start-server.sh`     | The real runner. SteamCMD, Proton, config seed, launch args, graceful shutdown. |
| `scripts/rcon.py`             | Minimal Source RCON client. No dependencies beyond stdlib. |
| `scripts/rcon-cli.sh`         | Thin wrapper for `docker exec` use.                  |
| `templates/ark-survival-ascended.xml` | Unraid Community Apps template. CA requires one XML per app under `templates/`. |
| `ca_profile.xml`              | CA repository profile. Must be at the root with a non-empty `<Profile>`, or submission is blocked. |
| `icon.svg`                    | Repository icon referenced by `ca_profile.xml` and the template. |
| `docker-compose.yml`          | Local testing only. Uses uid/gid 1000, not Unraid's 99/100. |

## Build

```sh
docker build -t ferment9348/ark-survival-ascended:latest .
```

## Test

There is no unit test suite. The checks that must pass before a change ships:

```sh
docker build -t asa-test .                 # must succeed; this is the bar
shellcheck --severity=warning scripts/*.sh
python3 -m py_compile scripts/rcon.py
```

Then a smoke run, which should reach the SteamCMD step and print the resolved
uid/gid. Stop it there — a full boot downloads ~13GB of game files.

```sh
docker run --rm -e UID=1000 -e GID=1000 asa-test
```

## Constraints

- **Windows depot, not Linux.** ASA has no native Linux server binary. SteamCMD
  is given `+@sSteamCmdForcePlatformType windows` and the exe runs under Proton.
  amd64 only — an arm64 image would be meaningless.
- **`UID` is also a bash variable.** In `start.sh` it is read into `TARGET_UID`
  rather than used directly, and `PUID`/`PGID` are accepted as aliases. Do not
  "simplify" that back to bare `${UID}`.
- **`ServerAdminPassword` must be the last `?` argument** in the query string.
  Anything after it is swallowed into the password value. See the ordering in
  `start-server.sh`.
- **Dash flags, not query params.** `-WinLiveMaxPlayers=` and `-port=` are the
  real settings; `?MaxPlayers=` and `?Port=` are silently ignored by ASA.
- **The config seed is write-once.** `GameUserSettings.ini` is written only when
  absent. Never make the container rewrite a file the user may have edited.
- **`HOME` is repointed at `<serverfiles>/home`.** `gosu` sets it from passwd,
  so `start-server.sh` overrides it after the privilege drop, not via `ENV`.
  SteamCMD's `depotcache` lives there and holds the manifest an incremental
  update diffs against. On the default `/home/steam` it is lost whenever the
  container is recreated, and the next update dies with `Access Denied` on the
  delta-source manifest because Steam does not issue request codes for
  superseded manifests. Do not move it back.
- **Graceful shutdown depends on RCON.** `SaveWorld` then `DoExit` over RCON,
  then a timed wait, then kill the wine prefix. A hard kill loses world state.
