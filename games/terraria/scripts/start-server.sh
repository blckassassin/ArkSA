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

# /tmp, never the mounted volume. On a volume the inode survives restarts and
# mkfifo returns EEXIST on every boot after the first. Worse, if the path is
# ever restored as a regular file, mkfifo fails but the open succeeds, so
# shutdown commands append to a file nobody reads and the save never happens.
# Nothing is lost by not persisting it: pipe contents live in memory.
#
# Not /run either: this script runs as the unprivileged steam user after
# start.sh's gosu drop, and /run is root-only (drwxr-xr-x root root), so
# mkfifo there fails with EACCES on every boot. /tmp is world-writable
# (drwxrwxrwt) and shares the container's mount namespace, so `docker exec`
# still reaches it.
FIFO="/tmp/terraria-console.fifo"

SERVER_PID=""
READER_PID=""
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
        local stamp
        stamp="$(date +%Y%m%d-%H%M%S)"
        local aside="${WORLD_FILE}.corrupt-${stamp}"
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
# Worldgen progress collapsing. Not cosmetic: Terraria logs one line per 0.1%
# of every generation phase, plus a hundred "Resetting game objects N%"
# lines — 10,000+ lines for even a small world. A container log driver that
# cannot keep up with that stalls, and the stall looks exactly like a hung
# server: the process itself keeps running and finishes generating fine,
# only the log freezes. An operator watching a frozen log concludes the
# container hung and kills it mid-generation, destroying the world - the
# same silent-hang failure class this repo already paid for with GE-Proton.
#
# Emit a line only when the phase name changes or the whole-percent tick
# changes; everything else (bare text, "Server started", errors) passes
# through untouched. fflush after every print, or mawk's own buffering
# reintroduces the same silence it's here to fix.
# -----------------------------------------------------------------------------
collapse_worldgen_progress() {
    awk '
    {
        line = $0
        # "12.3% - Phase name - 45.6%": dedup on the phase and the whole-percent
        # part of the OVERALL figure, so a phase busy at the 0.1% level still
        # collapses to about one line per percentage point.
        if (line ~ /^[0-9]+\.[0-9]+% - .+ - [0-9]+\.[0-9]+%$/) {
            split(line, parts, " - ")
            phase = parts[2]
            pct = parts[1]
            sub(/%$/, "", pct)
            bucket = int(pct)
            if (phase != last_name || bucket != last_bucket) {
                print line
                fflush()
                last_name = phase
                last_bucket = bucket
            }
            next
        }
        # "Resetting game objects 45%", "Settling liquids 17%": a standalone
        # counter with no overall figure to peg to. Collapse CONSECUTIVE
        # repeats only, in a key of its own: "Saving world data: NN%" has
        # this exact shape and recurs on every console.sh save, and a save
        # is not worldgen - it happens more than once per container life.
        # Only a plain passthrough line (below) resets last_repeat, not a
        # worldgen line above - the boot-time save interleaves one "100.0%
        # - Finalizing world" line between every percent tick, and treating
        # that as a boundary would undo the collapsing for the exact save
        # this branch exists to shrink. A later save is always preceded by
        # its own passthrough boundary (chat, "Backing up world file",
        # "Saving before exit..."), so that is the right place to reset.
        if (line ~ /^.+ [0-9]+%$/) {
            name = line
            sub(/ [0-9]+%$/, "", name)
            # The console echoes a ": " prompt before the first response line
            # after any command, so line 1 of an event reads ": Saving world
            # data: 3%" and line 2 reads plain "Saving world data: 11%" -
            # strip it or those two never compare equal and every event
            # prints twice.
            sub(/^: /, "", name)
            if (name != last_repeat) {
                print line
                fflush()
                last_repeat = name
            }
            next
        }
        last_repeat = ""
        print line
        fflush()
    }
    '
}

# -----------------------------------------------------------------------------
# Shutdown
# -----------------------------------------------------------------------------
# tini is PID 1 with this script as its only child (start.sh execs into it via
# gosu), so tini exits - and the kernel tears down the whole PID namespace -
# the instant the server dies, with no grace period for anything else still
# running. The reader below only notices the server is gone on its own
# once-per-second poll, then still has to stat, tail and push through awk;
# without waiting for it here, "Saving before exit" and the save-progress
# lines can be SIGKILLed before they ever reach the container's stdout, even
# though the world save on disk (which does not depend on this) is fine.
# Bounded, not a bare wait: the same reasoning as the ban on a bare wait on
# SERVER_PID applies here too - if the reader ever hangs, unbounded means the
# container hangs until SIGKILL instead of exiting cleanly.
wait_for_reader() {
    local waited=0
    while kill -0 "${READER_PID}" 2>/dev/null && [ "${waited}" -lt 3 ]; do
        sleep 1
        waited=$((waited + 1))
    done
}

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
    wait_for_reader

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
# A real file, not a pipe. Measured on this host: the same binary, the same
# seed range, writing to a plain file reached "Server started" in ~26s;
# piped through this exact filter via process substitution it was still
# stuck 10+ minutes later at the same 90-something percent mark, CPU still
# ticking over but barely. A live pipe reader on the other end of stdout -
# even an idle, fast one - made the server itself over 20x slower, for
# reasons that sit below this script (scheduling/latency on that pipe, not
# the reader's own CPU cost, which measured near zero). Writing to a file
# is never gated on a reader, so SERVER_PID below is always exactly right
# and the server's own speed no longer depends on anything downstream.
SERVER_LOG="/tmp/terraria-server.log"
"${BIN}" -config "${CONF}" < "${FIFO}" > "${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

# Mirrors the log file into this script's own stdout through the collapsing
# filter above, same as the ASA runner's LOG_TAIL_PID does for its engine
# log. This is a plain byte-offset poll loop, not `tail -f`: inotify-based
# follow measurably missed a burst of writes in this sandbox (it sat idle
# while the file kept growing underneath it, right through "Server
# started", and never caught back up) and this coreutils build has no
# --poll flag to force plain polling instead. `stat` + `tail -c` depend on
# nothing but read()/stat(), so there is no notification path left to fail.
# One persistent awk process reads the whole loop's output, so its dedup
# state survives across polls. Stops on its own once the server does.
(
    pos=0
    while kill -0 "${SERVER_PID}" 2>/dev/null; do
        sz=$(stat -c %s "${SERVER_LOG}" 2>/dev/null || echo 0)
        if [ "${sz}" -gt "${pos}" ]; then
            tail -c "+$((pos + 1))" "${SERVER_LOG}"
            pos="${sz}"
        fi
        sleep 1
    done
    sz=$(stat -c %s "${SERVER_LOG}" 2>/dev/null || echo 0)
    [ "${sz}" -gt "${pos}" ] && tail -c "+$((pos + 1))" "${SERVER_LOG}"
) | collapse_worldgen_progress &
READER_PID=$!

wait "${SERVER_PID}"
wait_for_reader
