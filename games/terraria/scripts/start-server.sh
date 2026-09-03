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
