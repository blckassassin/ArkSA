# ARK: Survival Ascended — Docker server for Unraid

[![build](https://github.com/blckassassin/ArkSA/actions/workflows/build.yml/badge.svg)](https://github.com/blckassassin/ArkSA/actions/workflows/build.yml)
[![docker](https://img.shields.io/docker/v/ferment9348/ark-survival-ascended?sort=semver&label=docker%20hub)](https://hub.docker.com/r/ferment9348/ark-survival-ascended)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A SteamCMD-based ASA dedicated server container, laid out the way ich777's game
server images are, so it should feel familiar if you were running his: the same
`/serverdata/steamcmd` + `/serverdata/serverfiles` split, the same `UID`/`GID`/
`VALIDATE`/`USERNAME` environment variables, the same "download everything on
first boot so the image stays small" approach.

The one structural difference is Proton. Wildcard still ships no native Linux
server binary for ASA, so this installs the **Windows** depot (SteamCMD is told
`+@sSteamCmdForcePlatformType windows`) and runs `ArkAscendedServer.exe` under
GE-Proton.

## Before you start

- **Disk:** the depot is roughly 60GB. Put it on a cache pool or SSD share, not
  on the array.
- **RAM:** 16GB is a sensible floor for a vanilla map. Mods and players push it
  well past that. ASA is considerably hungrier than ASE.
- **First boot is slow and quiet.** A ~60GB download, then Proton builds its
  prefix, then the server does its own startup. Watch the logs rather than
  assuming it has hung.

## Get the image

```bash
docker pull ferment9348/ark-survival-ascended:latest
```

Tagged releases are published as `:1.2.3` and `:1.2`, and `:latest` always points
at the most recent release rather than at the tip of `main`.

Or build it yourself — on Unraid you can do this on the server itself:

```bash
git clone https://github.com/blckassassin/ArkSA.git
cd ArkSA
docker build -t ferment9348/ark-survival-ascended:latest .
```

If you build under a different name, change `<Repository>` in
`templates/ark-survival-ascended.xml` to match.

## Install on Unraid

1. Copy `templates/ark-survival-ascended.xml` to
   `/boot/config/plugins/dockerMan/templates-user/`.
2. Docker tab → **Add Container** → pick `ARK-Survival-Ascended` from the
   template dropdown.
3. Set your paths, server name and admin password, then apply.

## Ports

| Port  | Proto | What it does                                              |
| ----- | ----- | --------------------------------------------------------- |
| 7777  | UDP   | Game traffic. **The only one you have to forward.**        |
| 7778  | UDP   | Peer port. Rarely needed; worth trying for flaky connects. |
| 27015 | UDP   | Legacy Steam query port. Vestigial in ASA — see below.     |
| 27020 | TCP   | RCON. Forward only if you administer from outside the LAN. |

Server discovery in ASA runs through Epic Online Services, not Steam's A2S query
protocol, so you do **not** need to forward 27015 for your server to appear in
the Unofficial list. It is mapped only because some third-party tooling still
expects it to exist.

## Configuration

Environment variables of note:

| Variable            | Default          | Notes                                                                     |
| ------------------- | ---------------- | ------------------------------------------------------------------------- |
| `SERVER_NAME`       | `ASA Server`     | Session name in the server browser.                                        |
| `MAP`               | `TheIsland_WP`   | Needs the `_WP` suffix — the bare ASE name will not load.                  |
| `MAX_PLAYERS`       | `20`             | Becomes `-WinLiveMaxPlayers`.                                              |
| `SRV_PWD`           | empty            | Join password. Blank for an open server.                                   |
| `SRV_ADMIN_PWD`     | `adminpassword`  | Admin **and** RCON password. Change it.                                    |
| `MODS`              | empty            | Comma-separated CurseForge project IDs.                                    |
| `CROSSPLAY`         | `false`          | `true` adds `-crossplay` so Epic players can join.                         |
| `BATTLEYE`          | `false`          | `false` passes `-NoBattlEye`.                                              |
| `GAME_PARAMS_EXTRA` | empty            | Extra dash flags, space separated.                                         |
| `QUERY_PARAMS_EXTRA`| empty            | Extra `?key=value` pairs, no leading `?`.                                  |
| `CLUSTER_ID`        | empty            | Same value on every server in a cluster.                                   |
| `PROTON_VERSION`    | `latest`         | Or pin a tag like `GE-Proton9-27`.                                         |
| `VALIDATE`          | empty            | `true` makes SteamCMD verify every file on start. Slow.                    |
| `STOP_TIMEOUT`      | `120`            | Seconds allowed for a graceful save before force kill.                     |
| `FIX_PERMS`         | `true`           | Keeps the `Saved` tree editable over SMB. See below.                       |
| `CONFIG_UMASK`      | inherits `UMASK` | umask applied to the `Saved` tree. See below.                              |
| `CONFIG_PERM`       | unset            | Optional chmod expression; overrides `CONFIG_UMASK` when set.              |
| `DATA_PERM`         | `775`            | Mode on the top-level server files folder.                                 |
| `UMASK`             | `000`            | New files 666, new directories 777.                                        |

### The launch-argument traps

ASA moved several settings off the `?`-string and onto dash flags, and the old
forms are **silently ignored** rather than erroring:

- `-WinLiveMaxPlayers=N` sets the player cap. `?MaxPlayers=` does nothing.
- `-port=N` sets the game port. `?Port=` does nothing.
- `ServerAdminPassword` must be the **last** `?` argument — anything after it
  gets swallowed into the password value. The script already handles this, but
  keep it in mind if you add your own `QUERY_PARAMS_EXTRA`.
- Mods are CurseForge project IDs, not Steam Workshop IDs. A Workshop-only mod
  is not an ASA mod.

### INI files

`GameUserSettings.ini` and `Game.ini` live in:

```
<serverfiles>/ShooterGame/Saved/Config/WindowsServer/
```

That path says `WindowsServer` even though you are on Linux — you are running
the Windows binary, and ASA has no `LinuxServer` variant.

For convenience a `config` symlink is created at the top of the game files
folder, so you can also reach them at `<serverfiles>/config/`. If your Samba
setup has `follow symlinks` disabled the shortcut will not show up over the
network — use the full path in that case.

The container seeds `GameUserSettings.ini` with RCON enabled on first run and
then **never touches it again**, so your edits are safe.

**Stop the container before editing.** ARK rewrites `GameUserSettings.ini` when
it shuts down, so changes you make while it is running get overwritten.

## Editing the configs over SMB from Windows

This is set up to work out of the box. Three things have to line up, and the
container handles all of them:

1. **Ownership.** Everything is chowned to your `UID`/`GID`, which on Unraid
   defaults to `99:100` (`nobody:users`) — the ids Unraid's SMB stack expects.
2. **File modes.** `UMASK=000` means files the server creates land as `666` and
   directories as `777`. On top of that, `FIX_PERMS=true` re-applies those modes
   across the `Saved` tree on every start *and* again on shutdown, which repairs
   anything that already exists with a tight mode — a migrated install, or files
   wine created itself.
3. **Traversal.** Permissive files are useless if a parent directory blocks the
   way in, so the chain down to `Saved` is opened up too. This is why
   `DATA_PERM` defaults to `775` and not ich777's `770`: with `770`, an SMB user
   who is neither the owner nor a member of group `100` cannot get in at all.

### Tightening it: `CONFIG_UMASK`

`CONFIG_UMASK` is a plain umask, and it means what you would expect — files
start from `666`, directories from `777`, and the umask bits come off. Leave it
blank and it just follows the container-wide `UMASK`, so by default there is a
single number governing everything.

| `CONFIG_UMASK` | Files | Dirs  | Who can edit over SMB                         |
| -------------- | ----- | ----- | --------------------------------------------- |
| `000` (default)| `666` | `777` | Anyone.                                       |
| `007`          | `660` | `770` | Owner and group `users` only.                 |
| `022`          | `644` | `755` | Nobody but the owner — read-only for you.     |
| `077`          | `600` | `700` | Owner only. Not editable over SMB at all.     |

`007` is the sensible choice if `000` feels too open: Unraid accounts belong to
the `users` group (gid `100`), so SMB editing keeps working while everything
else is shut out. Note that `022` and `077` will make the files **read-only or
invisible** from Windows — that is the intended meaning, but it is the opposite
of what you asked for, so pick them deliberately.

An invalid value falls back to `000` with a warning in the log rather than
failing the boot.

`CONFIG_PERM` remains as an escape hatch for anything a umask cannot express —
set it to a chmod expression like `g+rwX` and it overrides `CONFIG_UMASK`. Set
`FIX_PERMS=false` to skip the pass entirely and manage permissions yourself.

Two things on the Unraid side that this container cannot do for you:

- The **appdata share must be exported over SMB**. It often is not by default.
  Shares → appdata → *SMB Security Settings*.
- If permissions are already tangled from a previous container, run **Tools →
  Docker Safe New Permissions** once with the containers stopped, or start this
  one with `FORCE_CHOWN=true` for a single boot.

Use an editor that respects existing line endings — Notepad++ or VS Code rather
than stock Notepad — for the larger ini files.

## Stopping safely

ARK writes its world on exit, so a hard kill is how people lose hours of
progress. On `docker stop` the container sends `SaveWorld`, then `DoExit` over
RCON, waits up to `STOP_TIMEOUT` seconds, and only then kills the wine prefix.

This depends on RCON being enabled in `GameUserSettings.ini`. If you disable it,
you lose the safe shutdown.

**On Unraid, raise the container stop timeout** (Settings → Docker →
*Default shutdown time-out*) to something above your `STOP_TIMEOUT`, or Unraid
will pull the rug out mid-save during an array stop.

## RCON from the command line

```bash
docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh SaveWorld
docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh ListPlayers
docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh "Broadcast Restart in 5 minutes"
```

Worth knowing: ASA moderation commands take a player's **EOS ID**, not a
Steam64 ID.

## Clusters

Set the same `CLUSTER_ID` on each container and point every one of them at a
shared `CLUSTER_DIR` (map the same host path into each container). Give each
server its own `GAME_PORT` and its own serverfiles path.

## Troubleshooting

**Server never appears in the list.** Check 7777/udp is forwarded to the Unraid
host. If only Epic players cannot see it, set `CROSSPLAY=true`.

**Crashes on startup, or wine errors about file descriptors.** The container
raises its own limit, but the Docker-level ceiling matters too — the template
passes `--ulimit nofile=1048576:1048576` in Extra Parameters. Make sure that
survived any edits you made.

**Cannot open or save the ini files from Windows.** Check the appdata share is
actually exported over SMB, then confirm `FIX_PERMS` is `true` and restart the
container — the recursive fix runs on start. If it is still wrong, the files are
probably owned by the wrong uid; start once with `FORCE_CHOWN=true`.

**Out-of-memory or mmap errors under load.** Unreal engine servers can exhaust
the default `vm.max_map_count`. On the Unraid host:

```bash
sysctl -w vm.max_map_count=262144
```

Add it to your `go` file to make it stick across reboots.

**A Proton update broke something.** Pin `PROTON_VERSION` to the build that
worked. Deleting the proton appdata folder forces a clean prefix rebuild, which
is worth trying before anything drastic — it does not touch your saves.

**SteamCMD keeps failing partway.** Steam's CDN deprioritises anonymous logins
under load. Set `VALIDATE=true` and restart; it resumes rather than starting
over.

## Credit

The structure, environment variable naming and general Unraid ergonomics here
are lifted from [ich777's](https://github.com/ich777/docker-steamcmd-server)
game server containers, which were the standard for this on Unraid for years.

## License

MIT — see [LICENSE](LICENSE).
