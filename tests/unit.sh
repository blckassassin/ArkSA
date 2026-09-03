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
