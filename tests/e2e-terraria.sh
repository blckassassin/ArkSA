#!/bin/bash
# End-to-end check for the Terraria container.
#
# What this catches: a boot hang, the interactive-setup fallback, a shutdown
# command that never reaches the server, a shutdown command that is the wrong
# command, a world that was not saved during shutdown, and a stop that
# overruns the engine's default grace. It cannot distinguish `>&3` from a
# path reopen in the trap, because the runner holds the FIFO open read-write
# for the container's lifetime, so both deliver identically (see
# start-server.sh's `graceful_shutdown`) - that is a real limit of what a
# live-server stop can exercise, not an oversight here.
#
# Deliberate choices:
#
#  - The ENGINE's DEFAULT stop grace, not a raised one. STOP_TIMEOUT must fit
#    inside it or the handler is theatre in production while passing here.
#    Note: STOP_TIMEOUT's own kill-9 fallback means a delivery failure still
#    exits within budget (~7-9s) - the elapsed check only catches a stop that
#    genuinely overruns the grace, not a command that never arrived. That's
#    what the log/world checks below are for.
#  - The SIGTERM path (stop), not console.sh. Writing to the FIFO directly
#    tests the wrong thing; the path that breaks in production is the trap.
#  - Asserts on the world file's size and STRICTLY advancing mtime, and on
#    Terraria's own "Saving before exit" log line - NOT on exit code. The
#    handler ends in `exit 0` unconditionally, and `-ge`/`-gt 0` alone both
#    pass on a completely untouched file, so neither proves a save happened.
#
# ENGINE defaults to docker (CI, real Docker, no user-namespace remapping).
# This host has no docker, only podman - verify locally with:
#   ENGINE=podman bash tests/e2e-terraria.sh
# Two rootless-podman-only quirks can keep a local run from going green even
# when the container logic is correct: conmon stops relaying container logs
# past ~186 lines regardless of log driver (this script greps container logs
# for "Server started"), and `exec` as root can't write the FIFO under
# fuse-overlayfs. Neither applies to Docker. Do not loosen an assertion to
# work around either - CI is what proves them out.
#
# Rootless podman also remaps container UIDs into a subuid range: start.sh's
# `chown "${UID}" "${SERVER_DIR}"` runs the number we passed through that
# mapping, so ${DATA} (the bind-mounted volume root) ends up owned on the
# real host by a uid that isn't ours, and DATA_PERM=775 leaves us only r-x
# on it - a plain `rm -rf` as ourselves can't touch its contents. `podman
# unshare` re-enters that same mapping so the removal resolves correctly.
# Docker performs no such remapping and never hits this.
set -euo pipefail

ENGINE="${ENGINE:-docker}"
IMAGE="${1:-terraria-test}"
NAME="terraria-e2e-$$"
DATA="$(mktemp -d)"

cleanup() {
    "${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true
    if [ "${ENGINE}" = "podman" ]; then
        podman unshare rm -rf "${DATA}" 2>/dev/null || rm -rf "${DATA}" 2>/dev/null || true
    else
        rm -rf "${DATA}"
    fi
}
trap cleanup EXIT

echo "== booting ${IMAGE} (${ENGINE})"
"${ENGINE}" run -d --name "${NAME}" \
    -e UID="$(id -u)" -e GID="$(id -g)" \
    -e WORLD_NAME=E2E -e WORLD_SIZE=1 -e MAX_PLAYERS=2 \
    -v "${DATA}:/serverdata/serverfiles" \
    "${IMAGE}" >/dev/null

echo "== waiting for the server to listen"
# GitHub-hosted runners are 2-core and Terraria's worldgen is single-threaded.
# A 300s deadline was observed failing on a real CI run at 97% complete, while
# the same WORLD_SIZE=1 world takes 25-50s on a developer machine. This exists
# to catch a genuine hang, not to enforce a performance budget.
boot_deadline=900
deadline=$((SECONDS + boot_deadline))
next_report=$((SECONDS + 60))
until "${ENGINE}" logs "${NAME}" 2>&1 | grep -q 'Server started'; do
    if [ "${SECONDS}" -gt "${deadline}" ]; then
        echo "FAIL: server never reported 'Server started' within ${boot_deadline}s"
        "${ENGINE}" logs "${NAME}" 2>&1 | tail -40
        exit 1
    fi
    if ! "${ENGINE}" ps -q --filter "name=${NAME}" | grep -q .; then
        echo "FAIL: container exited during startup"
        "${ENGINE}" logs "${NAME}" 2>&1 | tail -40
        exit 1
    fi
    if [ "${SECONDS}" -gt "${next_report}" ]; then
        echo "== still waiting (${SECONDS}s elapsed)"
        next_report=$((SECONDS + 60))
    fi
    sleep 2
done

# An incomplete serverconfig.txt drops the server into its interactive setup,
# where it reads our "exit" as a menu selection instead of a command.
if "${ENGINE}" logs "${NAME}" 2>&1 | grep -q 'Choose World'; then
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

echo "== ${ENGINE} stop with the DEFAULT grace"
start=${SECONDS}
"${ENGINE}" stop "${NAME}" >/dev/null
elapsed=$((SECONDS - start))
echo "== stopped in ${elapsed}s"

if [ "${elapsed}" -ge 10 ]; then
    echo "FAIL: stop took ${elapsed}s and hit the engine's 10s SIGKILL grace."
    echo "      The handler did not finish inside the default grace."
    exit 1
fi

"${ENGINE}" logs "${NAME}" 2>&1 | grep -q 'Server stopped' || {
    echo "FAIL: handler never reached '---Server stopped---'"
    "${ENGINE}" logs "${NAME}" 2>&1 | tail -20
    exit 1
}

# Terraria's own pre-exit save message - only printed if it actually received
# and processed "exit", not just any command. Catches a wrong command (e.g.
# "save") slipping through undetected by the size/mtime checks below, since a
# real save can happen without the server ever announcing an exit.
"${ENGINE}" logs "${NAME}" 2>&1 | grep -q 'Saving before exit' || {
    echo "FAIL: server never announced 'Saving before exit'; exit was not delivered"
    "${ENGINE}" logs "${NAME}" 2>&1 | tail -20
    exit 1
}

after_size=$(stat -c %s "${WORLD}")
after_mtime=$(stat -c %Y "${WORLD}")
[ "${after_size}" -gt 0 ] || { echo "FAIL: world is empty after shutdown"; exit 1; }
[ "${after_mtime}" -gt "${before_mtime}" ] || { echo "FAIL: world mtime did not advance on shutdown"; exit 1; }

echo "PASS: world ${after_size} bytes, saved on shutdown, stopped in ${elapsed}s"
