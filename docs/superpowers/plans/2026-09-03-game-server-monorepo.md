# Multi-Game Unraid Monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure this repo into a monorepo hosting several Unraid Community
Applications game server containers, and add a Terraria server as the second game.

**Architecture:** Per-game directories under `games/<slug>/`, one shared entrypoint
in `shared/scripts/start.sh`, CA templates in `templates/`, and a CI matrix keyed on
slug-prefixed git tags. ASA keeps its existing image name and every path frozen into
already-installed CA templates.

**Tech Stack:** Bash, Docker (debian:trixie-slim), GitHub Actions,
`docker/metadata-action@v6`, Unraid Community Applications XML.

**Spec:** `docs/superpowers/specs/2026-09-03-game-server-monorepo-design.md`

## Global Constraints

- Branch is `monorepo-restructure`. Do not commit to `main`. Do not push; the repo is
  owned by the `blckassassin` GitHub account and pushing needs `gh auth switch`.
- **This is a live Unraid CA app.** `ferment9348/ark-survival-ascended:latest` runs on
  strangers' servers. A broken `:latest` is other people's broken game server.
- ASA image name stays exactly `ferment9348/ark-survival-ascended`. Terraria is
  exactly `ferment9348/terraria`.
- Slugs are `ark-survival-ascended` and `terraria`, used identically as directory
  name, template filename, git tag prefix, and Docker Hub repo name.
- Terraria pins: `TERRARIA_VERSION=1458`,
  `TERRARIA_SHA256=f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334`.
- `STOP_TIMEOUT` for Terraria defaults to `8`, not ASA's `120`. Docker's default stop
  grace is 10 seconds.
- Frozen paths that must keep resolving: root `README.md`, root `icon.png`, root
  `icon.svg`, `templates/ark-survival-ascended.xml`, `/serverdata/serverfiles`,
  `/serverdata/steamcmd`, and the 24 env `Target=` names in the ASA template.
- Every shell script must pass `shellcheck --severity=warning`. Every Python file must
  pass `python3 -m py_compile`.
- Do not create `EXTRA_DATA_DIRS`, a `data-dirs` file, a `game.json` registry, or
  `tools/icongen/common.py`. The spec rejects all four by name.

---

### Task 1: Restructure ASA into the monorepo layout

Moves ASA's files without changing a byte of their contents, and fixes the
`.dockerignore` that would otherwise make every build fail. ASA must build identically
after this task.

**Files:**
- Modify: `.dockerignore` (whole file)
- Move: `Dockerfile` to `games/ark-survival-ascended/Dockerfile`
- Move: `docker-compose.yml` to `games/ark-survival-ascended/docker-compose.yml`
- Move: `docs/dockerhub.md` to `games/ark-survival-ascended/docs/dockerhub.md`
- Move: `scripts/start-server.sh`, `scripts/rcon.py`, `scripts/rcon-cli.sh` to
  `games/ark-survival-ascended/scripts/`
- Move: `scripts/start.sh` to `shared/scripts/start.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the directory layout every later task writes into. The image build
  command becomes
  `docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .`
  run from the repo root.

- [ ] **Step 1: Move the files with git mv**

```bash
mkdir -p games/ark-survival-ascended/scripts games/ark-survival-ascended/docs shared/scripts
git mv Dockerfile               games/ark-survival-ascended/Dockerfile
git mv docker-compose.yml       games/ark-survival-ascended/docker-compose.yml
git mv docs/dockerhub.md        games/ark-survival-ascended/docs/dockerhub.md
git mv scripts/start-server.sh  games/ark-survival-ascended/scripts/start-server.sh
git mv scripts/rcon.py          games/ark-survival-ascended/scripts/rcon.py
git mv scripts/rcon-cli.sh      games/ark-survival-ascended/scripts/rcon-cli.sh
git mv scripts/start.sh         shared/scripts/start.sh
```

`docs/` still exists — it holds `docs/superpowers/`. Do not delete it.

- [ ] **Step 2: Rewrite .dockerignore**

The current file is `*` then `!scripts/`, which excludes every new path. Replace the
whole file with:

```
# The build only needs the entrypoint and the game's own scripts. Keep the data
# tree, the docs and the other games out of the context.
#
# Every new game must add nothing here: games/*/scripts/ already covers it.
*
!shared/scripts/
!games/*/scripts/
```

- [ ] **Step 3: Point the Dockerfile COPY at the new paths**

In `games/ark-survival-ascended/Dockerfile`, replace the single line:

```dockerfile
COPY scripts/ /opt/scripts/
```

with:

```dockerfile
COPY shared/scripts/ /opt/scripts/
COPY games/ark-survival-ascended/scripts/ /opt/scripts/
```

Order matters only in that both land in `/opt/scripts/`; there are no filename
collisions between the two directories.

- [ ] **Step 4: Fix the compose file's build context**

In `games/ark-survival-ascended/docker-compose.yml`, replace `build: .` with:

```yaml
    build:
      context: ../..
      dockerfile: games/ark-survival-ascended/Dockerfile
```

- [ ] **Step 5: Verify the build still works**

Run from the repo root:

```bash
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
shellcheck --severity=warning shared/scripts/*.sh games/ark-survival-ascended/scripts/*.sh
python3 -m py_compile games/ark-survival-ascended/scripts/rcon.py
```

Expected: build succeeds, shellcheck silent, py_compile silent. If the build fails
with `COPY failed: no source files were specified`, `.dockerignore` is wrong.

- [ ] **Step 6: Verify the entrypoint still resolves inside the image**

```bash
docker run --rm --entrypoint ls asa-test -1 /opt/scripts
```

Expected output contains exactly: `rcon-cli.sh`, `rcon.py`, `start-server.sh`,
`start.sh`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Move ASA into the games/ layout"
```

---

### Task 2: Make the shared entrypoint game-agnostic

`shared/scripts/start.sh` hardcodes four ASA directories. Terraria has neither
`STEAMCMD_DIR` nor `PROTON_DIR`, and the script runs under `set -u`.

**Files:**
- Modify: `shared/scripts/start.sh:63` and `shared/scripts/start.sh:68`
- Create: `tests/unit.sh`

**Interfaces:**
- Consumes: the layout from Task 1.
- Produces: `start.sh` tolerating unset `STEAMCMD_DIR` / `PROTON_DIR`. Terraria's
  Dockerfile in Task 4 relies on simply not setting them.

- [ ] **Step 1: Write the failing test**

Create `tests/unit.sh`:

```bash
#!/bin/bash
# Plain assertions, no framework. Run: bash tests/unit.sh
set -u
fail=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        echo "         expected: [$2]"
        echo "         actual:   [$3]"
        fail=1
    fi
}

# --- start.sh directory loop -------------------------------------------------
# The loop must survive STEAMCMD_DIR and PROTON_DIR being unset under `set -u`,
# must not word-split a path containing spaces, and must still emit all four
# directories for ASA so each keeps its own ownership-drift check.

dirs_for() {  # dirs_for <SERVER_DIR> [STEAMCMD_DIR] [PROTON_DIR]
    (
        set -u
        SERVER_DIR="$1"
        [ $# -ge 2 ] && STEAMCMD_DIR="$2"
        [ $# -ge 3 ] && PROTON_DIR="$3"
        for DIR in "${SERVER_DIR}" "${SERVER_DIR}/home" ${STEAMCMD_DIR:+"${STEAMCMD_DIR}"} ${PROTON_DIR:+"${PROTON_DIR}"}; do
            printf '[%s]' "${DIR}"
        done
    )
}

check "terraria: both unset, no crash, two dirs" \
    "[/sd][/sd/home]" \
    "$(dirs_for /sd)"

check "asa: all four dirs present" \
    "[/sd][/sd/home][/steam][/sd/proton]" \
    "$(dirs_for /sd /steam /sd/proton)"

check "path with spaces is not split" \
    "[/a b][/a b/home]" \
    "$(dirs_for "/a b")"

exit "$fail"
```

- [ ] **Step 2: Run it to make sure it passes standalone**

```bash
bash tests/unit.sh
```

Expected: three `ok` lines, exit 0. This test encodes the target behaviour; it passes
on its own because it inlines the loop. Its job is to lock the idiom so a later edit
to `start.sh` that breaks it is caught by review against this file.

- [ ] **Step 3: Apply the same idiom to start.sh**

In `shared/scripts/start.sh`, replace line 63:

```bash
mkdir -p "${STEAMCMD_DIR}" "${SERVER_DIR}" "${PROTON_DIR}" "${SERVER_DIR}/home"
```

with:

```bash
mkdir -p "${SERVER_DIR}" "${SERVER_DIR}/home" ${STEAMCMD_DIR:+"${STEAMCMD_DIR}"} ${PROTON_DIR:+"${PROTON_DIR}"}
```

and replace line 68:

```bash
for DIR in "${STEAMCMD_DIR}" "${SERVER_DIR}" "${PROTON_DIR}" "${SERVER_DIR}/home"; do
```

with:

```bash
for DIR in "${SERVER_DIR}" "${SERVER_DIR}/home" ${STEAMCMD_DIR:+"${STEAMCMD_DIR}"} ${PROTON_DIR:+"${PROTON_DIR}"}; do
```

- [ ] **Step 4: Add the comment explaining why, above the loop**

Insert directly above the `for DIR` line:

```bash
# ${VAR:+"${VAR}"} expands to nothing when the variable is unset, which is safe
# under `set -u`, and stays quoted when it is set, so a path with spaces is not
# split. Terraria sets neither STEAMCMD_DIR nor PROTON_DIR.
#
# All four entries stay listed on purpose. Each gets its own `stat -c %u` drift
# check below; folding the nested two into SERVER_DIR would mean a root-owned
# ${SERVER_DIR}/home is only repaired when SERVER_DIR's top level also looks
# wrong. That is the depotcache bug from aa28fe5 coming back after a tar or
# docker cp restore.
```

- [ ] **Step 5: Verify**

```bash
bash tests/unit.sh
shellcheck --severity=warning shared/scripts/start.sh
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
docker run --rm -e UID=1000 -e GID=1000 asa-test 2>&1 | head -20
```

Expected: tests pass; shellcheck silent (`SC2086` is intentional here — if shellcheck
flags the `:+` expansions, add `# shellcheck disable=SC2086` with a one-line reason
directly above each, not repo-wide); the smoke run prints `---Preparing container---`
and reaches `---Starting as user steam (1000:1000)---`.

- [ ] **Step 6: Commit**

```bash
git add shared/scripts/start.sh tests/unit.sh
git commit -m "Let the shared entrypoint run a game with no SteamCMD or Proton"
```

---

### Task 3: Rewrite CI for per-game builds and slug-prefixed tags

The single largest source of silent failure in this restructure. Four separate
`refs/tags/v` guards currently gate publishing, and a prefixed tag satisfies none of
them.

**Files:**
- Modify: `.github/workflows/build.yml` (whole file)
- Modify: `tests/unit.sh` (append a section)

**Interfaces:**
- Consumes: the layout from Task 1.
- Produces: a workflow whose matrix carries `slug` and `title` only. Task 4 and Task 7
  add `terraria` to the `SLUGS` list in the `setup` job.

- [ ] **Step 1: Write the failing test for the tag regex**

Append to `tests/unit.sh`, immediately before the final `exit "$fail"`:

```bash
# --- release tag regex -------------------------------------------------------
# This is the exact `match=` value used in .github/workflows/build.yml. It must
# extract the version, reject a Terraria tag when scoped to the ASA slug, and
# refuse to match the `v` inside "sur[v]ival".

extract() {  # extract <slug> <tag>
    printf '%s' "$2" | sed -nE "s|^$1/v([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$|\1|p"
}

check "asa release version extracts" \
    "1.5.0" "$(extract ark-survival-ascended ark-survival-ascended/v1.5.0)"
check "asa prerelease version extracts" \
    "1.6.0-rc.1" "$(extract ark-survival-ascended ark-survival-ascended/v1.6.0-rc.1)"
check "terraria tag does not match the asa pattern" \
    "" "$(extract ark-survival-ascended terraria/v1.0.0)"
check "terraria release version extracts" \
    "1.0.0" "$(extract terraria terraria/v1.0.0)"
check "a bare tag does not match" \
    "" "$(extract ark-survival-ascended v1.5.0)"
check "a typo'd slug does not match" \
    "" "$(extract ark-survival-ascended ark-survival-acended/v1.5.0)"
```

- [ ] **Step 2: Run it**

```bash
bash tests/unit.sh
```

Expected: nine `ok` lines total, exit 0.

- [ ] **Step 3: Replace .github/workflows/build.yml entirely**

```yaml
name: build

on:
  push:
    branches: [main]
    # Releases are <slug>/v<version>, e.g. ark-survival-ascended/v1.5.0.
    # A bare v1.5.0 no longer triggers anything; the setup job explains that.
    tags: ['*/v*']
  pull_request:
    branches: [main]

jobs:
  # Decides which games this run builds, and whether it publishes. A tag builds
  # exactly the game its prefix names; main and PRs build everything and publish
  # nothing.
  setup:
    runs-on: ubuntu-latest
    outputs:
      games: ${{ steps.pick.outputs.games }}
    steps:
      - uses: actions/checkout@v7

      - name: Pick the games to build
        id: pick
        run: |
          set -euo pipefail
          # The one list to edit when adding a game. Keep slug and title paired.
          ALL='[
            {"slug":"ark-survival-ascended","title":"ARK: Survival Ascended Dedicated Server"},
            {"slug":"terraria","title":"Terraria Dedicated Server"}
          ]'

          if [ "${GITHUB_REF_TYPE}" != "tag" ]; then
            echo "games=$(echo "$ALL" | jq -c .)" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          SLUG="${GITHUB_REF_NAME%%/*}"
          # Without this, a typo'd slug is a green run that publishes nothing:
          # the tag glob still matches, and metadata-action treats a failed
          # `match` as "no tags" rather than an error.
          if ! echo "$ALL" | jq -e --arg s "$SLUG" 'any(.[]; .slug == $s)' >/dev/null; then
            echo "::error::'${SLUG}' is not a known game slug."
            echo "::error::Valid slugs: $(echo "$ALL" | jq -r '[.[].slug] | join(", ")')"
            echo "::error::Release tags look like <slug>/v1.2.3 — a bare v1.2.3 publishes nothing."
            exit 1
          fi
          echo "games=$(echo "$ALL" | jq -c --arg s "$SLUG" '[.[] | select(.slug == $s)]')" >> "$GITHUB_OUTPUT"

  build:
    needs: setup
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        game: ${{ fromJSON(needs.setup.outputs.games) }}
    steps:
      - uses: actions/checkout@v7

      # shellcheck and python3 are both preinstalled on ubuntu-latest.
      - name: Lint the scripts
        run: |
          shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh
          for f in games/*/scripts/*.py; do [ -e "$f" ] && python3 -m py_compile "$f"; done
          bash tests/unit.sh

      - uses: docker/setup-buildx-action@v4

      # amd64 only: ASA runs a Windows depot under Proton, and the Terraria
      # server ships an x86_64 binary. An arm64 image would build and not run.
      - name: Tags and labels
        id: meta
        uses: docker/metadata-action@v6
        with:
          # Exactly one repo. generateTags applies the resolved version to every
          # entry here, so listing both would publish one game into the other's
          # Docker Hub repo.
          images: ferment9348/${{ matrix.game.slug }}
          # type=semver with match=, NOT type=match. procMatch hardcodes
          # latest=true, so it would move :latest for a release candidate.
          # procSemver applies match= before the prerelease check, so the narrow
          # :latest gating survives. The pattern is anchored on the slug and
          # requires a digit after v — unanchored v(.+) matches the v in
          # "survival" and captures garbage.
          tags: |
            type=semver,pattern={{version}},match=^${{ matrix.game.slug }}/v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$
            type=semver,pattern={{major}}.{{minor}},match=^${{ matrix.game.slug }}/v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$
            type=ref,event=branch
            type=ref,event=pr
          labels: |
            org.opencontainers.image.title=${{ matrix.game.title }}
            org.opencontainers.image.source=https://github.com/blckassassin/unraid-game-servers

      # Every guard below is refs/tags/ and not refs/tags/v. A prefixed tag does
      # not start with refs/tags/v, and missing even one of these produces a
      # green run that publishes nothing, or publishes without moving :latest.
      - name: Log in to Docker Hub
        if: startsWith(github.ref, 'refs/tags/')
        uses: docker/login-action@v4
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Fail if a tag build produced no version tags
        if: startsWith(github.ref, 'refs/tags/')
        run: |
          set -euo pipefail
          TAGS='${{ steps.meta.outputs.tags }}'
          echo "$TAGS"
          echo "$TAGS" | grep -q ':latest$' || {
            echo "::error::No :latest tag was computed. The CA template pins :latest,"
            echo "::error::so publishing without it strands every installed user."
            exit 1
          }

      - name: Build
        uses: docker/build-push-action@v7
        with:
          context: .
          file: games/${{ matrix.game.slug }}/Dockerfile
          platforms: linux/amd64
          push: ${{ startsWith(github.ref, 'refs/tags/') }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # Cosmetic, and it runs after the push so it can never block a release.
      # continue-on-error means a wrong readme-filepath fails silently, so the
      # path is derived from the slug rather than hardcoded.
      - name: Sync the Docker Hub description
        if: startsWith(github.ref, 'refs/tags/')
        continue-on-error: true
        uses: peter-evans/dockerhub-description@v5
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
          repository: ferment9348/${{ matrix.game.slug }}
          readme-filepath: ./games/${{ matrix.game.slug }}/docs/dockerhub.md
```

The `:latest` assertion in "Fail if a tag build produced no version tags" is the
safety net for the whole tag scheme: every other failure mode here is green.

- [ ] **Step 4: Validate the workflow parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('yaml ok')"
bash tests/unit.sh
```

Expected: `yaml ok`, and the unit tests pass. If `actionlint` is available, run it too;
it is not required.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/unit.sh
git commit -m "Build each game from its own slug-prefixed tag"
```

---

### Task 4: Terraria image and installer

**Files:**
- Create: `games/terraria/Dockerfile`
- Create: `games/terraria/scripts/install.sh`

**Interfaces:**
- Consumes: `shared/scripts/start.sh` from Task 2, which `exec`s
  `/opt/scripts/start-server.sh` as the `steam` user.
- Produces: `install_terraria()`, sourced by `start-server.sh` in Task 5. It sets no
  variables; on success `${SERVER_DIR}/active/TerrariaServer.bin.x86_64` exists and is
  executable.

- [ ] **Step 1: Write games/terraria/Dockerfile**

```dockerfile
# Terraria ships a native Linux server with bundled Mono, so this image needs
# none of ASA's Proton, wine or lib32 machinery.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="Terraria Dedicated Server" \
      org.opencontainers.image.description="Terraria dedicated server, native Linux binary, Unraid friendly." \
      org.opencontainers.image.source="https://github.com/blckassassin/unraid-game-servers" \
      org.opencontainers.image.licenses="MIT"

# STEAMCMD_DIR and PROTON_DIR are deliberately not set. shared/scripts/start.sh
# skips them when unset, which is how one entrypoint serves both games.
ENV DEBIAN_FRONTEND="noninteractive" \
    SERVER_DIR="/serverdata/serverfiles" \
    TERRARIA_VERSION="1458" \
    TERRARIA_SHA256="f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334" \
    WORLD_NAME="World" \
    WORLD_SIZE="2" \
    DIFFICULTY="0" \
    WORLD_SEED="" \
    MAX_PLAYERS="8" \
    GAME_PORT="7777" \
    SRV_PWD="" \
    MOTD="" \
    LANGUAGE="en/US" \
    SECURE="1" \
    UPNP="0" \
    UID="99" \
    GID="100" \
    DATA_PERM="775" \
    FIX_PERMS="true" \
    UMASK="000" \
    STOP_TIMEOUT="8"

RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        procps \
        gosu \
        tini \
        locales && \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen && \
    useradd -u ${UID} -d /home/steam -m -s /bin/bash steam && \
    mkdir -p ${SERVER_DIR} && \
    apt-get -y autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

COPY shared/scripts/ /opt/scripts/
COPY games/terraria/scripts/ /opt/scripts/
RUN chmod -R 755 /opt/scripts

# 7777/tcp game traffic. Terraria uses TCP; ARK's 7777 is UDP, so the two
# containers do not collide on a default Unraid box.
EXPOSE 7777/tcp

VOLUME ["/serverdata/serverfiles"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
```

Note the `LANGUAGE` collision: the locale block sets `LANGUAGE="en_US:en"` after the
game block sets `LANGUAGE="en/US"`. Rename the game variable to `GAME_LANGUAGE` in
both the `ENV` block above and everywhere in Task 5, and use `GAME_LANGUAGE` for
Terraria's `language=` config key.

- [ ] **Step 2: Write games/terraria/scripts/install.sh**

```bash
#!/bin/bash
# Terraria server installer. Sourced by start-server.sh.
#
# There is no SteamCMD here: app 105600 is the paid game and cannot be fetched
# anonymously. The dedicated server is a free zip from terraria.org, so the
# version is a pin rather than an auto-update, and it is checksummed before it
# is unpacked — the same rule install_proton() applies to GE-Proton tarballs.

install_terraria() {
    local want="${SERVER_DIR}/${TERRARIA_VERSION}"
    local active="${SERVER_DIR}/active"
    local bin="${want}/TerrariaServer.bin.x86_64"

    # The symlink target is the installed-version marker. No separate .version
    # file, and a half-finished install can never look complete because the
    # link is only flipped after a successful extract.
    if [ "$(readlink -f "${active}" 2>/dev/null)" = "${want}" ] && [ -x "${bin}" ]; then
        echo "---Terraria ${TERRARIA_VERSION} already installed---"
        return 0
    fi

    local url="https://terraria.org/api/download/pc-dedicated-server/terraria-server-${TERRARIA_VERSION}.zip"
    local zip="/tmp/terraria-${TERRARIA_VERSION}.zip"
    local staging="/tmp/terraria-staging-$$"

    echo "---Downloading Terraria ${TERRARIA_VERSION}---"
    if ! curl -fL "${url}" -o "${zip}"; then
        echo "---Download failed. Is TERRARIA_VERSION=${TERRARIA_VERSION} a real release?---"
        rm -f "${zip}"
        return 1
    fi

    echo "---Verifying checksum---"
    if ! echo "${TERRARIA_SHA256}  ${zip}" | sha256sum -c --status; then
        echo "---Checksum MISMATCH, refusing to extract---"
        echo "---Expected ${TERRARIA_SHA256}"
        echo "---Actual   $(sha256sum "${zip}" | cut -d' ' -f1)"
        echo "---If you changed TERRARIA_VERSION you must change TERRARIA_SHA256 too---"
        rm -f "${zip}"
        return 1
    fi

    # Only the Linux tree. The archive also carries Windows and Mac builds,
    # about 140MB unpacked across all three.
    echo "---Extracting---"
    rm -rf "${staging}"
    mkdir -p "${staging}"
    if ! unzip -q "${zip}" "${TERRARIA_VERSION}/Linux/*" -d "${staging}"; then
        echo "---Extract failed---"
        rm -rf "${staging}" "${zip}"
        return 1
    fi

    rm -rf "${want}"
    mv "${staging}/${TERRARIA_VERSION}/Linux" "${want}"
    rm -rf "${staging}" "${zip}"

    chmod +x "${bin}"
    ln -sfn "${want}" "${active}"
    echo "---Terraria ${TERRARIA_VERSION} installed---"
}
```

- [ ] **Step 3: Build the image**

```bash
docker build -f games/terraria/Dockerfile -t terraria-test .
shellcheck --severity=warning games/terraria/scripts/*.sh
```

Expected: build succeeds, shellcheck silent.

- [ ] **Step 4: Verify the installer against the real download**

This test is why Terraria gets an end-to-end check and ASA does not: the whole
install is 46MB.

```bash
docker run --rm --entrypoint bash terraria-test -c '
  set -e
  export SERVER_DIR=/tmp/sd TERRARIA_VERSION=1458
  export TERRARIA_SHA256=f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334
  mkdir -p $SERVER_DIR
  source /opt/scripts/install.sh
  install_terraria
  test -x $SERVER_DIR/active/TerrariaServer.bin.x86_64 && echo INSTALL-OK
  test ! -d $SERVER_DIR/1458/../Windows && echo LINUX-ONLY-OK
'
```

Expected: `---Checksum verified---` is not printed (the script prints
`---Verifying checksum---` then proceeds), followed by `---Terraria 1458 installed---`,
`INSTALL-OK`, and `LINUX-ONLY-OK`.

- [ ] **Step 5: Verify a bad checksum is fatal**

```bash
docker run --rm --entrypoint bash terraria-test -c '
  export SERVER_DIR=/tmp/sd TERRARIA_VERSION=1458 TERRARIA_SHA256=deadbeef
  mkdir -p $SERVER_DIR
  source /opt/scripts/install.sh
  install_terraria && echo "BAD: returned success" || echo "GOOD: refused"
'
```

Expected: `---Checksum MISMATCH, refusing to extract---` and `GOOD: refused`.

- [ ] **Step 6: Commit**

```bash
git add games/terraria/Dockerfile games/terraria/scripts/install.sh
git commit -m "Add the Terraria image and a checksummed installer"
```

---

### Task 5: Terraria runner — config, world guards, FIFO shutdown

The core of the new game. Every construct here is load-bearing; the spec's §4 explains
each and should be read before editing this file.

**Files:**
- Create: `games/terraria/scripts/start-server.sh`
- Create: `games/terraria/scripts/console.sh`

**Interfaces:**
- Consumes: `install_terraria()` from Task 4.
- Produces: a container that boots, generates a world, and saves on SIGTERM. Task 6's
  end-to-end test drives it.

- [ ] **Step 1: Write games/terraria/scripts/start-server.sh**

```bash
#!/bin/bash
# Terraria dedicated server runner.
#
# Two things differ from the ASA runner and drive everything below.
#
# 1. There is no RCON. Terraria reads console commands on stdin, and "exit" is
#    what makes it save and quit. So the server's stdin is a FIFO that this
#    script holds open, and the shutdown handler writes "exit" into it.
# 2. serverconfig.txt is regenerated on every boot rather than seeded once.
#    ASA seeds write-once because the server rewrites GameUserSettings.ini on
#    shutdown; Terraria only ever reads its config, so write-once would make the
#    Unraid template's fields silently do nothing after first boot.

set -u
umask "${UMASK:-000}"

# shellcheck source=/dev/null
source /opt/scripts/install.sh

WORLD_DIR="${SERVER_DIR}/worlds"
CONF="${SERVER_DIR}/serverconfig.txt"
WORLD_FILE="${WORLD_DIR}/${WORLD_NAME}.wld"

# /run, never the mounted volume. On a volume the inode survives restarts and
# mkfifo returns EEXIST on every boot after the first. Worse, if the path is
# ever restored as a regular file, mkfifo fails but the open succeeds, so
# shutdown commands append to a file nobody reads and the save never happens.
# Nothing is lost by not persisting it: pipe contents live in memory.
FIFO="/run/terraria.fifo"

SERVER_PID=""
SHUTTING_DOWN="false"

# -----------------------------------------------------------------------------
# World safety
#
# A truncated .wld still satisfies "a world file exists", so autocreate stays
# off, the load fails, and Unraid's --restart unless-stopped hammers forever. A
# transient crash becomes permanent because of the recovery logic. Test -s, not
# -e. Moving a zero-byte file aside loses nothing, by definition.
# -----------------------------------------------------------------------------
check_world() {
    mkdir -p "${WORLD_DIR}"

    if [ -e "${WORLD_FILE}" ] && [ ! -s "${WORLD_FILE}" ]; then
        local aside="${WORLD_FILE}.corrupt-$(date +%Y%m%d-%H%M%S)"
        echo "---'${WORLD_NAME}.wld' is zero bytes, which would fail to load forever---"
        echo "---Moving it to $(basename "${aside}") and generating a fresh world---"
        mv "${WORLD_FILE}" "${aside}"
    fi

    # Changing WORLD_NAME points at a different file, and autocreate then makes
    # a new world. The old one is still on disk, so say so rather than letting
    # it look like the save was lost.
    if [ ! -e "${WORLD_FILE}" ]; then
        local existing
        existing=$(find "${WORLD_DIR}" -maxdepth 1 -name '*.wld' -printf '%f ' 2>/dev/null)
        if [ -n "${existing}" ]; then
            echo "---No world named '${WORLD_NAME}.wld', but these exist: ${existing}---"
            echo "---A new world will be generated. Set WORLD_NAME to one of the above to use it instead.---"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Config. Regenerated every boot, so template edits actually take effect.
#
# autocreate is set unconditionally: Terraria honours it only when the world
# file is missing, which is what makes regeneration safe. Both world= and
# autocreate= must always be present — if either is absent the server drops into
# its interactive setup, prints "Choose World:", and reads our "exit" from the
# FIFO as a menu selection.
# -----------------------------------------------------------------------------
write_config() {
    echo "---Writing serverconfig.txt---"
    {
        echo "world=${WORLD_FILE}"
        echo "worldpath=${WORLD_DIR}"
        echo "worldname=${WORLD_NAME}"
        echo "autocreate=${WORLD_SIZE}"
        echo "difficulty=${DIFFICULTY}"
        echo "maxplayers=${MAX_PLAYERS}"
        echo "port=${GAME_PORT}"
        echo "password=${SRV_PWD}"
        echo "motd=${MOTD}"
        echo "language=${GAME_LANGUAGE}"
        echo "secure=${SECURE}"
        echo "upnp=${UPNP}"
        [ -n "${WORLD_SEED}" ] && echo "seed=${WORLD_SEED}"
        echo "priority=1"
    } > "${CONF}"
}

# -----------------------------------------------------------------------------
# Shutdown
# -----------------------------------------------------------------------------
graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"

    echo "---Shutdown requested, telling the server to save and exit---"
    # Write to the held descriptor, never re-open the path. Re-opening a FIFO
    # with no reader blocks inside open(2), and because that happens inside this
    # trap the handler becomes SIGTERM-proof and only SIGKILL clears it.
    echo exit >&3

    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${waited}" -lt "${STOP_TIMEOUT}" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---Still running after ${STOP_TIMEOUT}s, killing it---"
        kill -9 "${SERVER_PID}" 2>/dev/null || true
    fi

    # A trapped signal makes the first wait return 128+signum without reaping
    # the child, so this second wait is what collects the real status.
    wait "${SERVER_PID}" 2>/dev/null || true

    echo "---Server stopped---"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
install_terraria || exit 1
check_world
write_config

BIN="${SERVER_DIR}/active/TerrariaServer.bin.x86_64"
[ -x "${BIN}" ] || { echo "---${BIN} is missing or not executable---"; exit 1; }

rm -f "${FIFO}"
mkfifo "${FIFO}"
# O_RDWR. A write-only open blocks until a reader appears, and once the server
# has died a write-only descriptor takes SIGPIPE and kills this shell
# mid-shutdown. Holding a read end here makes both impossible, and it is also
# what stops the server seeing EOF when console.sh closes.
exec 3<>"${FIFO}"

echo "---Starting Terraria ${TERRARIA_VERSION} on port ${GAME_PORT}---"
"${BIN}" -config "${CONF}" < "${FIFO}" &
SERVER_PID=$!

wait "${SERVER_PID}"
```

- [ ] **Step 2: Write games/terraria/scripts/console.sh**

```bash
#!/bin/bash
# Send a console command to the running Terraria server.
#
#   docker exec <container> /opt/scripts/console.sh say hello
#   docker exec <container> /opt/scripts/console.sh save
#
# Safe to call: start-server.sh holds the FIFO open read-write, so this open
# never blocks even if the server itself has died.
set -eu

FIFO="/run/terraria.fifo"

if [ "$#" -eq 0 ]; then
    echo "usage: console.sh <terraria console command>" >&2
    exit 2
fi

if [ ! -p "${FIFO}" ]; then
    echo "No console FIFO at ${FIFO}. Is the server running in this container?" >&2
    exit 1
fi

printf '%s\n' "$*" > "${FIFO}"
```

- [ ] **Step 3: Rename LANGUAGE to GAME_LANGUAGE in the Dockerfile**

Task 4's `ENV` block sets `LANGUAGE="en/US"` and the locale block later sets
`LANGUAGE="en_US:en"`, so the game value is silently overwritten. In
`games/terraria/Dockerfile`, change the game variable to `GAME_LANGUAGE="en/US"`.
`start-server.sh` above already reads `GAME_LANGUAGE`.

- [ ] **Step 4: Build and lint**

```bash
docker build -f games/terraria/Dockerfile -t terraria-test .
shellcheck --severity=warning games/terraria/scripts/*.sh
```

Expected: both silent. `SC2155` may fire on `local aside="...$(date ...)"`; split the
declaration and assignment rather than disabling it.

- [ ] **Step 5: Commit**

```bash
git add games/terraria/scripts/start-server.sh games/terraria/scripts/console.sh games/terraria/Dockerfile
git commit -m "Add the Terraria runner with a FIFO console and save-on-stop"
```

---

### Task 6: Terraria end-to-end test

**Files:**
- Create: `tests/e2e-terraria.sh`
- Modify: `.github/workflows/build.yml` (add one step)

**Interfaces:**
- Consumes: the `terraria-test` image built from Task 5.
- Produces: the check that fails if the FIFO shutdown regresses.

- [ ] **Step 1: Write tests/e2e-terraria.sh**

```bash
#!/bin/bash
# End-to-end check for the Terraria container.
#
# Deliberate choices, each one a bug this would otherwise miss:
#
#  - `docker stop` with the DEFAULT grace, not a raised one. STOP_TIMEOUT must
#    fit inside Docker's 10s default or the handler is theatre in production
#    while passing here.
#  - The SIGTERM path, not console.sh. Writing to the FIFO directly tests the
#    wrong thing; the path that breaks in production is the trap.
#  - Asserts on the world file's size and mtime, NOT on exit code. The handler
#    ends in `exit 0` unconditionally, so "exited zero" passes whether or not
#    the save happened.
set -euo pipefail

IMAGE="${1:-terraria-test}"
NAME="terraria-e2e-$$"
DATA="$(mktemp -d)"

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    rm -rf "${DATA}"
}
trap cleanup EXIT

echo "== booting ${IMAGE}"
docker run -d --name "${NAME}" \
    -e UID="$(id -u)" -e GID="$(id -g)" \
    -e WORLD_NAME=E2E -e WORLD_SIZE=1 -e MAX_PLAYERS=2 \
    -v "${DATA}:/serverdata/serverfiles" \
    "${IMAGE}" >/dev/null

echo "== waiting for the server to listen"
deadline=$((SECONDS + 300))
until docker logs "${NAME}" 2>&1 | grep -q 'Server started'; do
    if [ "${SECONDS}" -gt "${deadline}" ]; then
        echo "FAIL: server never reported 'Server started' within 300s"
        docker logs "${NAME}" 2>&1 | tail -40
        exit 1
    fi
    if ! docker ps -q --filter "name=${NAME}" | grep -q .; then
        echo "FAIL: container exited during startup"
        docker logs "${NAME}" 2>&1 | tail -40
        exit 1
    fi
    sleep 2
done

# An incomplete serverconfig.txt drops the server into its interactive setup,
# where it reads our "exit" as a menu selection instead of a command.
if docker logs "${NAME}" 2>&1 | grep -q 'Choose World'; then
    echo "FAIL: server fell back to interactive setup; serverconfig.txt is incomplete"
    exit 1
fi

WORLD="${DATA}/worlds/E2E.wld"
[ -s "${WORLD}" ] || { echo "FAIL: no world generated at ${WORLD}"; exit 1; }
before_size=$(stat -c %s "${WORLD}")
before_mtime=$(stat -c %Y "${WORLD}")
echo "== world generated: ${before_size} bytes"

# Let the server settle so the shutdown save is distinguishable by mtime.
sleep 3

echo "== docker stop with the DEFAULT grace"
start=${SECONDS}
docker stop "${NAME}" >/dev/null
elapsed=$((SECONDS - start))
echo "== stopped in ${elapsed}s"

if [ "${elapsed}" -ge 10 ]; then
    echo "FAIL: stop took ${elapsed}s and hit Docker's 10s SIGKILL."
    echo "      The handler did not finish inside the default grace."
    exit 1
fi

docker logs "${NAME}" 2>&1 | grep -q 'Server stopped' || {
    echo "FAIL: handler never reached '---Server stopped---'"
    docker logs "${NAME}" 2>&1 | tail -20
    exit 1
}

after_size=$(stat -c %s "${WORLD}")
after_mtime=$(stat -c %Y "${WORLD}")
[ "${after_size}" -gt 0 ] || { echo "FAIL: world is empty after shutdown"; exit 1; }
[ "${after_mtime}" -ge "${before_mtime}" ] || { echo "FAIL: world mtime went backwards"; exit 1; }

echo "PASS: world ${after_size} bytes, saved on shutdown, stopped in ${elapsed}s"
```

- [ ] **Step 2: Run it locally**

```bash
docker build -f games/terraria/Dockerfile -t terraria-test .
bash tests/e2e-terraria.sh terraria-test
```

Expected: ends with `PASS: world <n> bytes, saved on shutdown, stopped in <n>s`.

- [ ] **Step 3: Prove the test detects the bug it exists for**

Temporarily change `echo exit >&3` in `games/terraria/scripts/start-server.sh` to
`echo exit > "${FIFO}"`, rebuild, and re-run the test.

```bash
sed -i 's|echo exit >&3|echo exit > "${FIFO}"|' games/terraria/scripts/start-server.sh
docker build -f games/terraria/Dockerfile -t terraria-broken .
bash tests/e2e-terraria.sh terraria-broken || echo "GOOD: the test caught it"
git checkout games/terraria/scripts/start-server.sh
```

Expected: the run fails. A test that cannot fail is not a test.

- [ ] **Step 4: Add the step to CI**

In `.github/workflows/build.yml`, after the `Build` step, add:

```yaml
      # Only Terraria: the install is 46MB and a world generates in seconds. A
      # full ASA boot pulls ~13GB, so ASA stays a manual check.
      - name: End-to-end test
        if: matrix.game.slug == 'terraria'
        run: |
          docker build -f games/terraria/Dockerfile -t terraria-test .
          bash tests/e2e-terraria.sh terraria-test
```

- [ ] **Step 5: Verify the workflow still parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('yaml ok')"
```

- [ ] **Step 6: Commit**

```bash
git add tests/e2e-terraria.sh .github/workflows/build.yml
git commit -m "Test that Terraria actually saves its world on stop"
```

---

### Task 7: Terraria CA template, icon and Docker Hub page

**Files:**
- Create: `templates/terraria.xml`
- Create: `games/terraria/README.md`
- Create: `games/terraria/docs/dockerhub.md`
- Create: `games/terraria/docker-compose.yml`
- Create: `tools/icongen/terraria.py`, producing root `terraria.png` and `terraria.svg`

**Interfaces:**
- Consumes: the env var names from Task 4's Dockerfile. Every `Target=` below must
  match one exactly.
- Produces: the CA entry Unraid users install.

- [ ] **Step 1: Generate the icon**

Write `tools/icongen/terraria.py` as a sibling of `build.py` — do **not** refactor
`build.py` into a shared module, the spec rejects that. Import the two writers from it:

```python
#!/usr/bin/env python3
"""Generate the Terraria icon: a green hill under a blue sky with a tree.

Same 32x32 pixel-art approach as build.py, whose writers we reuse directly.
Outputs terraria.png (256x256) and terraria.svg at the repo root.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build import write_png, write_svg, S  # noqa: E402
```

Then build a 32x32 grid of RGB tuples using the same conventions as `build.py`
(light source top-left) and call `write_png(grid, os.path.join(ROOT, "terraria.png"))`
and `write_svg(grid, os.path.join(ROOT, "terraria.svg"))`, where `ROOT` is resolved the
same way `build.py` resolves it.

Read `tools/icongen/build.py` first and match its `build_grid()` shape, since
`write_png` and `write_svg` expect that exact structure.

- [ ] **Step 2: Run it and confirm the outputs**

```bash
python3 tools/icongen/terraria.py
python3 -c "
from PIL import Image
i = Image.open('terraria.png')
print('png', i.size, i.mode)
assert i.size == (256, 256), i.size
"
test -s terraria.svg && echo "svg ok"
```

Expected: `png (256, 256) RGBA` (or `RGB`, matching whatever `build.py` produces for
`icon.png`) and `svg ok`.

- [ ] **Step 3: Write templates/terraria.xml**

Every `Target=` must match an `ENV` name from Task 4's Dockerfile exactly.

```xml
<?xml version="1.0"?>
<Container version="2">
  <Name>Terraria</Name>
  <Repository>ferment9348/terraria:latest</Repository>
  <Registry>https://hub.docker.com/r/ferment9348/terraria/</Registry>
  <Network>bridge</Network>
  <Shell>bash</Shell>
  <Privileged>false</Privileged>
  <Support>https://github.com/blckassassin/ArkSA/issues</Support>
  <Project>https://github.com/blckassassin/ArkSA</Project>
  <Overview>
Terraria dedicated server.

Terraria ships a native Linux server, so there is no Proton and no SteamCMD here - the server is a small download from terraria.org, checksummed before it is unpacked. First boot installs about 45MB and generates a world in seconds.

Settings are applied on every start, so changing Max Players or the password here and restarting takes effect. The exception is World Name: pointing it at a name that does not exist yet generates a new world rather than renaming the old one, and the container will list the worlds it found in the log.

Only 7777/tcp needs forwarding. Note that this is TCP, while an ARK server's 7777 is UDP, so the two can coexist on the same port number.

The server saves its world when the container stops. Leave Unraid's stop timeout at the default; the shutdown is designed to finish well inside it.
  </Overview>
  <Category>GameServers:</Category>
  <TemplateURL>https://raw.githubusercontent.com/blckassassin/ArkSA/main/templates/terraria.xml</TemplateURL>
  <Icon>https://raw.githubusercontent.com/blckassassin/ArkSA/main/terraria.png</Icon>
  <ReadMe>https://raw.githubusercontent.com/blckassassin/ArkSA/main/games/terraria/README.md</ReadMe>
  <License>MIT</License>
  <ExtraSearchTerms>terraria dedicated server sandbox</ExtraSearchTerms>
  <Changes>Initial release.</Changes>
  <ExtraParams>--restart=unless-stopped</ExtraParams>
  <Requires>About 100MB of disk and very little RAM - 1GB is comfortable for a small server. Unlike ARK this is not I/O heavy, so the array is fine.</Requires>

  <Config Name="Game Port" Target="7777" Default="7777" Mode="tcp" Description="Game traffic. TCP, unlike ARK's UDP 7777. This is the one to forward." Type="Port" Display="always" Required="true" Mask="false">7777</Config>

  <Config Name="Server Files" Target="/serverdata/serverfiles" Default="/mnt/user/appdata/terraria" Mode="rw" Description="Where the server, worlds and config live. About 100MB - the array is fine, no SSD needed." Type="Path" Display="always" Required="true" Mask="false">/mnt/user/appdata/terraria</Config>

  <Config Name="World Name" Target="WORLD_NAME" Default="World" Mode="" Description="Name of the world file. Changing this after first boot generates a NEW world - the old one stays on disk and the log lists it. It does not rename anything." Type="Variable" Display="always" Required="true" Mask="false">World</Config>
  <Config Name="World Size" Target="WORLD_SIZE" Default="2" Mode="" Description="1 = small, 2 = medium, 3 = large. Only used when the world is first generated." Type="Variable" Display="always" Required="true" Mask="false">2</Config>
  <Config Name="Difficulty" Target="DIFFICULTY" Default="0" Mode="" Description="0 = classic, 1 = expert, 2 = master, 3 = journey. Only used when the world is first generated." Type="Variable" Display="always" Required="true" Mask="false">0</Config>
  <Config Name="World Seed" Target="WORLD_SEED" Default="" Mode="" Description="Optional seed for world generation. Leave blank for random. Only used when the world is first generated." Type="Variable" Display="advanced" Required="false" Mask="false"/>
  <Config Name="Max Players" Target="MAX_PLAYERS" Default="8" Mode="" Description="Player slots. Applied on every restart." Type="Variable" Display="always" Required="true" Mask="false">8</Config>
  <Config Name="Server Password" Target="SRV_PWD" Default="" Mode="" Description="Join password. Leave blank for an open server. Applied on every restart." Type="Variable" Display="always" Required="false" Mask="true"/>
  <Config Name="MOTD" Target="MOTD" Default="" Mode="" Description="Message shown to players as they join." Type="Variable" Display="always" Required="false" Mask="false"/>

  <Config Name="Terraria Version" Target="TERRARIA_VERSION" Default="1458" Mode="" Description="Server build to install, as it appears in terraria.org's download URL. If you change this you MUST change the checksum below to match, or the container will refuse to start." Type="Variable" Display="advanced" Required="false" Mask="false">1458</Config>
  <Config Name="Terraria Checksum" Target="TERRARIA_SHA256" Default="f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334" Mode="" Description="sha256 of the server zip. Verified before anything is unpacked. Must match the version above." Type="Variable" Display="advanced" Required="false" Mask="false">f513a4ac9789d34af766291ae217c9cd7d9472e13782a0e2b17512f70d7a8334</Config>
  <Config Name="Stop Timeout" Target="STOP_TIMEOUT" Default="8" Mode="" Description="Seconds to wait for a save-and-exit before force killing. Kept under Docker's 10 second stop grace on purpose - raising it past 10 does nothing unless you also raise the container stop timeout." Type="Variable" Display="advanced" Required="false" Mask="false">8</Config>

  <Config Name="UID" Target="UID" Default="99" Mode="" Description="User ID. 99 is the Unraid default." Type="Variable" Display="advanced" Required="true" Mask="false">99</Config>
  <Config Name="GID" Target="GID" Default="100" Mode="" Description="Group ID. 100 is the Unraid default." Type="Variable" Display="advanced" Required="true" Mask="false">100</Config>
  <Config Name="UMASK" Target="UMASK" Default="000" Mode="" Description="umask for files the server creates. 000 keeps them editable over the share." Type="Variable" Display="advanced" Required="false" Mask="false">000</Config>
</Container>
```

`<Support>`, `<Project>`, `<TemplateURL>`, `<Icon>` and `<ReadMe>` deliberately still
say `ArkSA`. Task 8 explains why they only move after the appfeed is re-pointed.

- [ ] **Step 4: Validate the XML and cross-check every Target**

```bash
python3 - <<'EOF'
import re, xml.etree.ElementTree as ET
t = ET.parse('templates/terraria.xml')
env = set(re.findall(r'^\s+([A-Z_]+)=', open('games/terraria/Dockerfile').read(), re.M))
missing = []
for c in t.getroot().iter('Config'):
    if c.get('Type') == 'Variable' and c.get('Target') not in env:
        missing.append(c.get('Target'))
print('xml ok')
print('targets with no matching ENV:', missing or 'none')
assert not missing, missing
EOF
```

Expected: `xml ok` and `targets with no matching ENV: none`.

- [ ] **Step 5: Write games/terraria/README.md and games/terraria/docs/dockerhub.md**

`README.md` is the `<ReadMe>` target Unraid shows. Cover: what the image does, the
version and checksum pin and how to change both together, that settings reapply on
restart while World Name does not rename, the single TCP port, `console.sh` usage via
`docker exec`, and where worlds live. Model the tone on the existing root `README.md`.

`docs/dockerhub.md` is the Docker Hub long description — a shorter version of the same,
with the compose snippet.

- [ ] **Step 6: Write games/terraria/docker-compose.yml**

```yaml
services:
  terraria:
    build:
      context: ../..
      dockerfile: games/terraria/Dockerfile
    image: ferment9348/terraria:latest
    container_name: terraria
    restart: unless-stopped
    ports:
      - "7777:7777/tcp"
    environment:
      WORLD_NAME: "World"
      WORLD_SIZE: "2"
      DIFFICULTY: "0"
      MAX_PLAYERS: "8"
      SRV_PWD: ""
      # 1000:1000 suits an ordinary Linux host. The Unraid template uses 99:100.
      UID: "1000"
      GID: "1000"
    volumes:
      - ./data/terraria:/serverdata/serverfiles
```

- [ ] **Step 7: Commit**

```bash
git add templates/terraria.xml games/terraria/README.md games/terraria/docs/dockerhub.md games/terraria/docker-compose.yml tools/icongen/terraria.py terraria.png terraria.svg
git commit -m "Add the Terraria Community Applications template"
```

---

### Task 8: Repo-level docs and the CA migration runbook

The rename and the appfeed re-point are manual, ordered, and outside git. This task
documents them and does only the parts that are safe before the feed has moved.

**Files:**
- Modify: `README.md` (root)
- Modify: `ca_profile.xml`
- Modify: `AGENTS.md`
- Create: `docs/ca-migration.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the runbook the repo owner follows manually.

- [ ] **Step 1: Add an index section near the top of the root README**

The root `README.md` must stay an ASA guide. Its URL is frozen into every installed
CA template's `<ReadMe>`, and those users never receive a new template, so turning it
into a bare index would permanently degrade what they see in Unraid's Docker tab.

Insert immediately after the existing H1, before "What this one does differently":

```markdown
> **Other servers in this repo:** [Terraria](games/terraria/README.md).
> This page documents the ARK: Survival Ascended container.
```

Change nothing else in this file.

- [ ] **Step 2: Reword ca_profile.xml for two games**

Replace the `<Profile>` body's first two paragraphs with text covering both games,
keeping the ich777 lineage note. Leave `<Icon>` and `<WebPage>` pointing at `ArkSA`
until Task 8 Step 5's migration is done — `<Icon>` is
`raw.../ArkSA/main/icon.svg` and is frozen the same way `icon.png` is.

- [ ] **Step 3: Update AGENTS.md**

Rewrite the Layout table for the new tree, and replace the Build and Test blocks with:

```sh
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
docker build -f games/terraria/Dockerfile -t terraria-test .
```

```sh
shellcheck --severity=warning shared/scripts/*.sh games/*/scripts/*.sh
python3 -m py_compile games/ark-survival-ascended/scripts/rcon.py
bash tests/unit.sh
bash tests/e2e-terraria.sh terraria-test     # Terraria only; ASA's boot pulls ~13GB
```

Add to Constraints:

- Release tags are `<slug>/v<version>`. A bare `v1.2.3` triggers nothing at all.
- ASA has no `games/ark-survival-ascended/README.md`. Its guide is the root
  `README.md` because installed CA templates freeze that URL. Every other game gets
  `games/<slug>/README.md`.
- Terraria's `STOP_TIMEOUT` is 8 because Docker's default stop grace is 10s. Do not
  copy ASA's 120.
- Both images run as the account `steam`, Terraria included, because
  `shared/scripts/start.sh` hardcodes it.

- [ ] **Step 4: Write docs/ca-migration.md**

```markdown
# Renaming the repo without dropping off Community Applications

`<TemplateURL>` declares where CA should fetch a template from, and the appfeed
crawls on its own schedule — hours. Rewriting that field in the same commit as the
rename opens a window where the declared URL and the crawled URL disagree, which at
worst drops the entry and removes ARK from Community Applications for everyone
browsing it.

Raw URLs survive a repo rename: `raw.githubusercontent.com` serves the old
owner/name path transparently, verified against `GoogleCloudPlatform/kubernetes`,
`visionmedia/express` and `facebook/jest`. Raw URLs do **not** survive a file move,
which is why root `README.md`, `icon.png` and `icon.svg` stay exactly where they are.

Do these in order.

1. Merge this branch. Every template still points at `blckassassin/ArkSA`.
2. Rename the GitHub repo to `unraid-game-servers`. Confirm the frozen URLs still
   resolve:

   ```sh
   for u in README.md icon.png icon.svg templates/ark-survival-ascended.xml; do
       printf '%-40s %s\n' "$u" \
         "$(curl -s -o /dev/null -w '%{http_code}' \
            "https://raw.githubusercontent.com/blckassassin/ArkSA/main/$u")"
   done
   ```

   All four must be 200.
3. Re-point the CA appfeed entry at the new name. Wait for the feed to regenerate and
   confirm both ARK and Terraria appear.
4. Only now, in a follow-up commit, rewrite `<TemplateURL>`, `<Support>`, `<Project>`
   in both templates, and `<Icon>`/`<WebPage>` in `ca_profile.xml`, to
   `unraid-game-servers`.

**Never create a new repository named `blckassassin/ArkSA`.** GitHub frees an old name
for the same owner to reuse, and reusing it would hijack every frozen raw URL that
installed templates still point at.
```

- [ ] **Step 5: Verify and commit**

```bash
bash tests/unit.sh
docker build -f games/ark-survival-ascended/Dockerfile -t asa-test .
docker build -f games/terraria/Dockerfile -t terraria-test .
bash tests/e2e-terraria.sh terraria-test
git add README.md ca_profile.xml AGENTS.md docs/ca-migration.md
git commit -m "Document the two-game layout and the CA rename ordering"
```

---

## Self-Review

**Spec coverage.** §1 layout is Task 1 and 7. §1 `.dockerignore` is Task 1 Step 2. §2
shared boundary is Task 2. §3 CI, guards, semver `match=`, slug validation, `images:`
scoping, per-game docs are Task 3. §4 install, checksum, Linux-only extract, `active`
symlink is Task 4; FIFO, `STOP_TIMEOUT`, config regeneration, world guards are Task 5.
§5 frozen ABI and migration ordering are Task 8. §6 testing is Tasks 2, 3 and 6. §7
adding game three is the `ALL` list in Task 3 plus Task 8's AGENTS.md notes. §8 rejects
are respected: no base image, no registry, no `EXTRA_DATA_DIRS`, no `icongen/common.py`.
§9's five blocking items are Tasks 1, 2, 3, 5 and 6.

**Known gaps, deliberate.** Task 7 Steps 1 and 5 describe the icon grid and the two
prose files rather than supplying them literally — pixel art and a 200-line README are
authored against `build.py`'s existing conventions and the current root README's tone,
both of which the implementer must read anyway. Every other step carries real content.

**Type consistency.** `install_terraria()` is defined in Task 4 and called in Task 5.
`SERVER_DIR`, `TERRARIA_VERSION`, `TERRARIA_SHA256`, `WORLD_NAME`, `WORLD_SIZE`,
`DIFFICULTY`, `WORLD_SEED`, `MAX_PLAYERS`, `GAME_PORT`, `SRV_PWD`, `MOTD`,
`GAME_LANGUAGE`, `SECURE`, `UPNP`, `STOP_TIMEOUT` are set in Task 4's Dockerfile, read
in Task 5's runner, and exposed in Task 7's template. `GAME_LANGUAGE` is the corrected
name — Task 5 Step 3 fixes the `LANGUAGE` collision Task 4 introduces. `matrix.game.slug`
and `matrix.game.title` are produced by Task 3's `setup` job and consumed in the same
workflow. `FIFO` is `/run/terraria.fifo` in both Task 5 files.
