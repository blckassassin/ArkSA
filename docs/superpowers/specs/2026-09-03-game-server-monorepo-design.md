# Design: multi-game Unraid server monorepo

Status: approved 2026-09-03. Supersedes the single-game layout of `ArkSA` at `v1.4.0`.

## Goal

Turn `blckassassin/ArkSA` — today a single ARK: Survival Ascended container — into a
monorepo hosting several Unraid Community Applications game server containers, and
add Terraria as the second game in the same pass.

The repo is renamed to `unraid-game-servers`. Terraria publishes as
`ferment9348/terraria`. ASA keeps `ferment9348/ark-survival-ascended` unchanged.

## Why a monorepo

Unraid CA indexes **per repository**. `ca_profile.xml` is repo-level and one repo can
hold many templates, so game three is a new file rather than a new CA feed
submission, a second profile, and a second approval wait.

Code reuse is *not* a reason. ASA (SteamCMD, Windows depot, GE-Proton, RCON) and
Terraria (native Linux binary, no Steam, no RCON) share almost nothing. The only
genuinely shared file is `shared/scripts/start.sh`.

## Verified facts

Established by probing, not assumed. Re-verify before relying on any of these.

- Steam app 105600 is Terraria the game, `"is_free": false`, $9.99. SteamCMD
  anonymous login cannot download it. There is no free dedicated-server app id.
- The dedicated server is a free unauthenticated zip from
  `https://terraria.org/api/download/pc-dedicated-server/terraria-server-<VER>.zip`.
  1449 through 1458 return `application/zip`; 1459 returns a real `text/plain` 404.
- Current version **1458**, 46,415,317 bytes,
  sha256 `f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334`.
- The zip holds Windows, Mac and Linux trees (140MB unpacked, 99 files). Only
  `<VER>/Linux/` is wanted: 33 entries, including `TerrariaServer.bin.x86_64`
  (6,021,208 bytes) plus bundled Mono and `lib64/`. Native Linux, no Proton.
  `serverconfig.txt` ships only under `<VER>/Windows/`, so extraction cannot clobber
  a user's config.
- Vanilla Terraria has no RCON. It reads console commands on stdin; `exit` saves and
  quits.
- `raw.githubusercontent.com` serves renamed repos transparently — the old path
  `GoogleCloudPlatform/kubernetes` returns HTTP 200 with the same 4236 bytes as
  `kubernetes/kubernetes`. A repo rename therefore does not break URLs frozen into
  already-installed CA templates. A **file move** within the repo does.

## 1. Layout

```
ca_profile.xml                     # CA repo profile, must stay at root
README.md                          # ASA guide + short index. Frozen <ReadMe> target
icon.png  icon.svg                 # ASA icon. Frozen <Icon> targets
terraria.png  terraria.svg         # all icons live at root, one convention
LICENSE  AGENTS.md  .dockerignore  .gitignore
templates/
  ark-survival-ascended.xml
  terraria.xml
shared/scripts/start.sh            # uid/gid reconcile + gosu, copied into both images
games/
  ark-survival-ascended/
    Dockerfile  docker-compose.yml
    docs/dockerhub.md
    scripts/{start-server.sh,rcon.py,rcon-cli.sh}
  terraria/
    Dockerfile  docker-compose.yml  README.md
    docs/dockerhub.md
    scripts/{start-server.sh,console.sh}
tools/icongen/{build.py,terraria.py}
.github/workflows/build.yml
docs/superpowers/specs/
```

Build context is the repo root, `-f games/<slug>/Dockerfile`, so each image can
`COPY shared/scripts/` and its own `scripts/`.

Slugs are `ark-survival-ascended` and `terraria`, used identically as the directory
name, the template filename, the git tag prefix, and the Docker Hub repo name. No
mapping table anywhere.

**ASA has no `games/ark-survival-ascended/README.md`.** Its guide stays at the root
`README.md` because the live template's `<ReadMe>` is frozen there and existing
installs never receive a new template. Terraria and every later game get
`games/<slug>/README.md`. This asymmetry is deliberate; record it in `AGENTS.md`.

### `.dockerignore` must change

Current contents are `*` then `!scripts/`. Under the new layout nothing is in the
build context and the first `COPY` fails. New contents:

```
*
!shared/scripts/
!games/*/scripts/
```

It is a shared registry every future game touches. Name it in the "adding a game"
checklist.

## 2. Shared code boundary

Only `shared/scripts/start.sh` is shared. No base image, no per-game abstraction
layer — there is nothing to abstract.

Its directory loop is the one change. It currently hardcodes four ASA paths. It
becomes:

```bash
for DIR in "${SERVER_DIR}" "${SERVER_DIR}/home" ${STEAMCMD_DIR:+"${STEAMCMD_DIR}"} ${PROTON_DIR:+"${PROTON_DIR}"}; do
```

`${VAR:+"${VAR}"}` is safe under `set -u` (line 5) when unset, and every element
stays quoted so nothing word-splits. Terraria's Dockerfile simply never sets
`STEAMCMD_DIR` or `PROTON_DIR`. The same treatment applies to the `mkdir -p` above it.

This keeps **all four independent `stat -c %u` drift checks** for ASA. Collapsing to
`SERVER_DIR` alone would mean a root-owned `${SERVER_DIR}/home` is only repaired when
`SERVER_DIR`'s top level also looks wrong — reintroducing the depotcache bug fixed in
`aa28fe5` after a `tar` or `docker cp` restore.

Do not introduce an `EXTRA_DATA_DIRS` env var, a `data-dirs` file, or an argv
contract. All three answer "how do we pass the list" when `:+` removes the need for a
list at all.

Both images keep the account name `steam`, including Terraria, because `start.sh`
hardcodes it and renaming buys nothing. Do not duplicate `start.sh` per game: roughly
half of it is the uid/gid reconciliation including the `UID`-is-readonly trap that
`AGENTS.md` forbids simplifying, and two copies of a privilege drop is how one
silently keeps running as root.

## 3. CI and tagging

Tags become `<slug>/v<version>`, e.g. `ark-survival-ascended/v1.5.0`. Existing
`v1.0.0`..`v1.4.0` stay untouched; ASA's numbering continues, only the prefix is new.
Trigger becomes `tags: ['*/v*']`.

### The four guards

`build.yml` keys four decisions on `refs/tags/v` — line 38 (`latest`), 50 (Docker Hub
login), 61 (`push:`), 71 (description sync). `refs/tags/ark-survival-ascended/v1.5.0`
does not start with `refs/tags/v`, so all four go false and a release builds green
and publishes nothing. All four become `startsWith(github.ref, 'refs/tags/')`, which
is sufficient because only prefixed tags trigger the workflow.

### Version extraction

```yaml
type=semver,pattern={{version}},match=^${{ matrix.slug }}/v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$
type=semver,pattern={{major}}.{{minor}},match=^${{ matrix.slug }}/v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$
```

Verified against `docker/metadata-action`'s `src/meta.ts`:

- `match` is applied **before** the prerelease check, so `procSemver`'s narrow
  `:latest` gating survives. `v1.5.0` publishes `1.5.0`, `1.5` and `:latest`;
  `v1.6.0-rc.1` publishes only `1.6.0-rc.1` and moves neither `1.6` nor `:latest`
  (on a prerelease `procSemver` force-overrides the pattern to `{{version}}`).
- Do **not** use `type=match`. `procMatch` ends
  `... this.flavor.latest == 'auto' ? true : ...` — hardcoded `true` — so it would
  push `:latest` from a release candidate to every installed CA user.
- `match` is mandatory. Without it `procSemver` runs `vraw.replace(/\//g,'-')`,
  yielding `ark-survival-ascended-v1.5.0`, which fails `semver.valid` and emits a
  warning while publishing nothing, on a green run.
- Requiring a digit after `v` is load-bearing: the regex is scanned unanchored at the
  group level and "sur**v**ival" contains a `v`. `v(.+)$` captures
  `ival-ascended/v1.5.0`. Preserve both the `^${{ matrix.slug }}/` anchor and the
  `\d` if anyone edits this.
- `tmatch[1]` is hardcoded, so the pattern needs exactly one capture group. There is
  no `group=` attribute for `type=semver`.

### Jobs

`setup` derives the game list. On a tag push it takes the slug from the prefix,
**validates it against the known slug list and exits 1 naming the valid slugs** if it
does not match. On a `main` push or PR it emits every game and sets push=false.
Validation matters because `'*/v*'` also matches `docs/v2` and typo'd slugs, and a
failed `match` produces a green run that publishes nothing.

`build` runs the matrix, which carries **`slug` and `title` only**. The image name is
computed as `ferment9348/${{ matrix.slug }}`, and `images:` must be exactly that one
value — `generateTags` applies the resolved version to *every* entry in `images:`, so
a static two-repo list would publish a Terraria version into the ASA repo. Do not
carry `image` as a matrix column: copying an entry for game three and forgetting to
update it overwrites a live image.

`docs/dockerhub.md`, `short-description`, and the OCI `labels:` are all per-game and
come from `matrix.slug` / `matrix.title`. The description sync is
`continue-on-error: true`, so a wrong path fails silently.

Add a GitHub Actions cache for the Terraria zip keyed on `TERRARIA_VERSION` so the
end-to-end test does not hit terraria.org on every PR.

## 4. Terraria container

Base image `debian:trixie-slim` with `ca-certificates curl unzip gosu tini`. No
lib32, no wine dependencies.

Install pins both a version and a hash:

```
TERRARIA_VERSION=1458
TERRARIA_SHA256=f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334
```

`sha256sum -c` before `unzip`, refusing to extract on mismatch — matching what
`start-server.sh:199-211` already does for GE-Proton tarballs, and also catching
truncation. Extract only `<VER>/Linux/*`. Install to `/serverdata/serverfiles/<VER>/`
and flip a `/serverdata/serverfiles/active` symlink only after extraction succeeds;
launch via the symlink so a failed or partial upgrade cannot leave a half-written
binary running. The symlink target is also the installed-version marker: re-download
only when it does not resolve to `<TERRARIA_VERSION>`, so no separate `.version` file
is needed and a half-finished install can never look complete. Bumping the version requires editing both values, which is correct.

Volume paths reuse `/serverdata/serverfiles`. Do not invent `/serverdata/terraria` —
see the frozen ABI below. Port is 7777/tcp only; ARK's 7777 is UDP so the two do not
collide.

### Shutdown

This is the real design work. No RCON.

```bash
FIFO=/run/terraria.fifo          # /run, never the mounted volume
mkfifo "$FIFO"
exec 3<>"$FIFO"                  # O_RDWR: never blocks, never SIGPIPEs, no EOF

"$SERVER_BIN" -config "$CONF" < "$FIFO" &
SERVER_PID=$!
SHUTTING_DOWN=false              # must be initialised: start.sh runs under set -u

graceful_shutdown() {
    [ "$SHUTTING_DOWN" = true ] && return
    SHUTTING_DOWN=true
    echo "---Shutdown requested---"
    echo exit >&3

    local waited=0
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID" 2>/dev/null

    wait "$SERVER_PID" 2>/dev/null   # reap; a second wait yields the real status
    exit 0
}
trap graceful_shutdown SIGTERM SIGINT SIGQUIT
```

Every line above is load-bearing and was verified empirically:

- **`exec 3<>` not `3>`.** A write-only open blocks until a reader opens. The startup
  case is fixable by ordering, but the *shutdown* case is not: once the server has
  died there is no reader, and a handler that re-opens the path (`echo exit > "$fifo"`)
  blocks forever inside its own trap and becomes SIGTERM-proof, requiring SIGKILL. A
  write-only fd instead takes SIGPIPE and dies with 141 mid-shutdown. `3<>` holds a
  read end in the shell itself, so both failures are structurally impossible.
- **Write to `>&3`, never re-open the path.** This is the reason for `3<>`; a comment
  should say so, or someone will "simplify" it back to `3>` citing start ordering.
- **Never a bare `wait` in the handler** — no timeout, hangs until SIGKILL.
- **`wait` returns `128+signum`** on a trapped signal without reaping the child, so
  the second `wait` yields the true status.
- **The FIFO lives in `/run`.** On a mounted volume the inode survives restarts and
  `mkfifo` returns EEXIST on every boot after the first. Worse, if the path is ever
  restored as a *regular* file, `mkfifo` fails but the open succeeds, so shutdown
  commands append to a file nobody reads and the save silently never happens. Unraid
  appdata is on `shfs`. `/run` is fresh every boot and `docker exec` shares the mount
  namespace, so `console.sh` still reaches it. (No data is at risk in a leftover
  FIFO — pipe contents live in memory, so a stale inode is always empty.)

**`STOP_TIMEOUT` defaults to 8, not 120.** Docker's default stop grace is 10 seconds,
so ASA's 120 is already mostly theatre — it gets SIGKILLed at 10 unless the operator
sets `--stop-timeout`. Terraria saves in well under a second. Document
`--stop-timeout` for anyone wanting more.

### Config and world

`serverconfig.txt` is **regenerated from env on every boot**, so Max Players,
password, MOTD and difficulty are actually editable from the Unraid template. This
departs from ASA's write-once rule, and deliberately: ASA rewrites
`GameUserSettings.ini` on shutdown so write-once protects user edits, whereas
Terraria only ever reads its config.

`autocreate` is set **unconditionally**. Terraria honours it only when the world file
is missing, so there is no first-boot branch, no "runs twice" case, and no rename
case. This is safe precisely because regeneration cannot switch worlds on its own.

Two guards around it:

- If the configured `.wld` exists but is **zero bytes**, move it aside to
  `<name>.wld.corrupt-<timestamp>` and log loudly. A truncated world satisfies "a file
  exists", so autocreate stays off, the load fails, and Unraid's
  `--restart unless-stopped` hammers forever — a transient crash made permanent by
  the recovery logic. Test `-s`, never `-e`.
- If the configured `.wld` is absent while **other** `.wld` files exist, log them by
  name before generating. Changing `WORLD_NAME` otherwise looks like the user's base
  vanished.

`world=` and `autocreate=` must both always be written. If either is missing
TerrariaServer falls back to its interactive setup, prints "Choose World:", and reads
`exit` from the FIFO as a menu selection, looping on invalid input.

Known and accepted, consistent with ASA: the server password lands in
`serverconfig.txt` at mode 666 under `UMASK=000` on an SMB-visible share, exactly as
`GameUserSettings.ini` does.

## 5. CA continuity

### Frozen ABI — changing any of these breaks existing installs

| Reference | Note |
|---|---|
| `/serverdata/serverfiles`, `/serverdata/steamcmd` | Every user's volume mounts |
| The 24 env `Target=` names, `SERVER_NAME` through `UMASK` | Nothing new may become *required* |
| `<Repository>` `ferment9348/ark-survival-ascended:latest` | What §3's guards threaten |
| `<Icon>` `raw.../main/icon.png`, ca_profile `<Icon>` `.../main/icon.svg` | Both frozen; keep both paths |
| `<ReadMe>` `raw.../main/README.md` | URL and *content* — see below |
| `<TemplateURL>` `raw.../main/templates/ark-survival-ascended.xml` | Path unchanged; see sequencing |
| Ports 7777, 7778, 27015 udp and 27020 tcp; `<ExtraParams>`; `<Shell>bash` | Frozen |

`<Support>` and `<Project>` are `github.com` HTML URLs and survive the rename by
redirect. `.gitignore` needs nothing — `data/` matches at any depth.

**URL survival is not content survival.** The root `README.md` must stay an ASA guide
with a short "other servers in this repo" section near the top, not become a bare
index. An existing user clicking ReadMe in Unraid's Docker tab gets that file
permanently, since §5's own premise is that they never receive a new template.

### Migration order — the ordering *is* the risk

`<TemplateURL>` is a self-referential declaration of where CA should fetch the
template, and the appfeed regenerates on its own schedule (hours). Rewriting it in the
same commit as the rename opens a window where the declared and crawled URLs disagree,
which at worst drops the entry and removes ASA from Community Applications.

1. Restructure and rename, leaving both templates' `<TemplateURL>` on the **old** repo
   path. It redirects and stays consistent with what the feed crawls.
2. Get the appfeed entry re-pointed at `unraid-game-servers`; confirm the feed has
   regenerated against the new name.
3. Only then rewrite `<TemplateURL>` in a follow-up commit.

Do not reuse the name `blckassassin/ArkSA` for any new repository. GitHub frees an old
name for the same owner, and reusing it would hijack every frozen raw URL.

`ca_profile.xml`'s `<Profile>` prose enumerates games and needs rewording for two.

## 6. Testing

ASA's bar is unchanged: `docker build` succeeds, `shellcheck --severity=warning`,
`python3 -m py_compile`, and a smoke run reaching the SteamCMD step. A full boot pulls
~13GB, so it stays manual.

Terraria gets a real end-to-end test in CI — 46MB install, world generates in seconds:

1. Boot the container and assert the log reaches the listening line **without** a
   "Choose World:" prompt.
2. Stop it with `docker stop` under the **default** stop grace. Do not write to the
   FIFO directly: that exercises `console.sh`, while the path that breaks in
   production is the SIGTERM trap. Do not raise the grace, or the test passes where
   production fails.
3. Assert on the world file's **size and mtime**. Do **not** assert "exited zero" —
   `start-server.sh:520` hardcodes `exit 0` in the handler, so that assertion passes
   whether or not the save happened.

## 7. Adding game three

New files: `games/<slug>/{Dockerfile,README.md,docker-compose.yml,docs/dockerhub.md,scripts/}`,
`templates/<slug>.xml`, and an icon at the repo root. Plus a Docker Hub repo on the
same account.

Edits to five shared files: `.dockerignore`, the workflow's game list, root
`README.md`, `ca_profile.xml`, `AGENTS.md`. Tagging needs nothing — `'*/v*'` covers
any prefix.

Five central edits is honest. **Do not build a `game.json` registry to avoid them.**
Only the workflow list can fail silently, and the `setup` slug validation defuses that.

## 8. Deliberately not building

No shared base image. No per-game abstraction layer. No `game.json` registry. No
`EXTRA_DATA_DIRS` protocol. No `tools/icongen/common.py` split — leave `build.py`
alone and add `terraria.py` beside it. No TShock support. No auto-update for Terraria;
the version is a pin. No repo-wide version scheme.

## 9. Blocking before the first prefixed tag

Everything else can land after, but a release must not ship without these:

1. All four `refs/tags/v` guards updated.
2. FIFO `exec 3<>` with the handler writing `>&3`.
3. The slug-anchored `type=semver` pattern, with `images:` scoped to one repo.
4. `STOP_TIMEOUT` under Docker's stop grace.
5. `.dockerignore` updated, or nothing builds at all.

## Review provenance

Reviewed 2026-09-03 by DeepSeek (`deepseek-v4-pro`, direct API), Kimi (`k2.7-code`
via `delegate`), and two Claude agents — one architectural, one mechanical. All four
returned APPROVE WITH CHANGES; every change above is folded in.

Corrections made to reviewer findings, recorded so they are not re-litigated:

- `type=match` does **not** evaluate the full `refs/tags/...` ref, and `type=semver`
  has no prefix-stripping `prefix` attribute. Both claims were wrong; `match=` is the
  mechanism, confirmed in `src/meta.ts`.
- The Terraria zip cannot clobber `serverconfig.txt` — that file ships only in the
  Windows tree.
- A stale FIFO risks no data loss; pipe contents are in memory. The real problems are
  EEXIST and regular-file restore, both solved by `/run`.
- Write-once `serverconfig.txt` was recommended by one reviewer and rejected here, on
  the grounds that unconditional `autocreate` makes regeneration unable to switch
  worlds, which was that recommendation's only justification.
