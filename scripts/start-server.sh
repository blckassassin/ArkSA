#!/bin/bash
# ARK: Survival Ascended dedicated server runner.
#
# ASA has no native Linux server binary, so this installs the Windows depot with
# SteamCMD (forcing the windows platform type) and runs ArkAscendedServer.exe
# under GE-Proton.

set -u
umask "${UMASK:-000}"

STEAMCMD_URL="https://media.steampowered.com/client/installer/steamcmd_linux.tar.gz"
PROTON_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
SERVER_EXE="ArkAscendedServer.exe"

# Filled in by locate_game_dirs() once the files are on disk.
SERVER_EXE_DIR=""
GAME_ROOT=""
SAVED_DIR=""
CONFIG_DIR=""

SERVER_PID=""
LOG_TAIL_PID=""
SHUTTING_DOWN="false"
CONFIG_UMASK_EFFECTIVE=""

# -----------------------------------------------------------------------------
# Open file limit. Proton's esync/fsync eat FDs fast and ASA dies with confusing
# wine errors when the limit is the usual 1024.
# -----------------------------------------------------------------------------
HARD_NOFILE="$(ulimit -Hn)"
if [ "${HARD_NOFILE}" = "unlimited" ]; then
    ulimit -n 1048576 2>/dev/null || true
else
    ulimit -n "${HARD_NOFILE}" 2>/dev/null || true
fi
echo "---Open file limit set to $(ulimit -n)---"

# -----------------------------------------------------------------------------
# Permissions.
#
# The point of this is that you can open the config files over SMB from a
# Windows box and actually save them. Two things have to be true: the files need
# permissive modes, and every directory above them needs to be traversable.
#
# umask 000 handles files the server creates from here on (666 files, 777 dirs),
# but it does nothing for files that already exist - a migrated install, or
# anything wine created with a tighter mode - so the config tree gets an explicit
# recursive pass on every start. It is only the config and save data, not the
# game binaries, so this stays cheap.
# -----------------------------------------------------------------------------
# Turn a umask into the two modes it implies, exactly as the kernel does at
# creation time: files start from 0666, directories from 0777, umask bits come
# off. Directories have to be handled separately or they lose the execute bit
# and nothing underneath is reachable.
CONFIG_FILE_MODE=""
CONFIG_DIR_MODE=""
resolve_config_modes() {
    # CONFIG_UMASK is the knob; it falls back to the container-wide UMASK so
    # that by default there is a single number governing everything.
    local m="${CONFIG_UMASK:-${UMASK:-000}}"

    if ! [[ "${m}" =~ ^[0-7]{1,4}$ ]]; then
        echo "---CONFIG_UMASK '${m}' is not a valid octal umask, using 000---"
        m="000"
    fi

    local dec=$((8#${m}))
    CONFIG_FILE_MODE="$(printf '%04o' $(( 0666 & ~dec & 0777 )))"
    CONFIG_DIR_MODE="$(printf '%04o' $(( 0777 & ~dec & 0777 )))"
    CONFIG_UMASK_EFFECTIVE="${m}"
}

fix_share_perms() {
    if [ "${FIX_PERMS,,}" != "true" ]; then
        return 0
    fi

    [ -n "${SAVED_DIR}" ] && [ -d "${SAVED_DIR}" ] || return 0

    resolve_config_modes

    # The parent chain gets the directory mode too, otherwise a permissive
    # config folder still sits behind an unreachable parent.
    chmod "${CONFIG_DIR_MODE}" "${GAME_ROOT}" 2>/dev/null
    find "${SAVED_DIR}" -type d -exec chmod "${CONFIG_DIR_MODE}" {} + 2>/dev/null
    find "${SAVED_DIR}" -type f -exec chmod "${CONFIG_FILE_MODE}" {} + 2>/dev/null
}

# -----------------------------------------------------------------------------
# Locate the install. Finding the binary beats hardcoding ShooterGame/ - the
# layout has shifted before, and people arrive here with folders laid out by
# whichever container they used previously.
# -----------------------------------------------------------------------------
locate_game_dirs() {
    local hit
    hit="$(find "${SERVER_DIR}" -maxdepth 5 -name "${SERVER_EXE}" -type f 2>/dev/null | head -n1)"
    if [ -z "${hit}" ]; then
        return 1
    fi

    SERVER_EXE_DIR="$(dirname "${hit}")"                       # .../Binaries/Win64
    GAME_ROOT="$(dirname "$(dirname "${SERVER_EXE_DIR}")")"     # .../ShooterGame
    SAVED_DIR="${GAME_ROOT}/Saved"
    CONFIG_DIR="${SAVED_DIR}/Config/WindowsServer"
    return 0
}

# -----------------------------------------------------------------------------
# SteamCMD
# -----------------------------------------------------------------------------
if [ ! -f "${STEAMCMD_DIR}/steamcmd.sh" ]; then
    echo "---SteamCMD not found, downloading---"
    mkdir -p "${STEAMCMD_DIR}"
    if ! curl -fsSL "${STEAMCMD_URL}" -o /tmp/steamcmd.tar.gz; then
        echo "---Could not download SteamCMD, exiting---"
        exit 1
    fi
    tar -xzf /tmp/steamcmd.tar.gz -C "${STEAMCMD_DIR}"
    rm -f /tmp/steamcmd.tar.gz
    chmod +x "${STEAMCMD_DIR}/steamcmd.sh"
fi

# -----------------------------------------------------------------------------
# GE-Proton
# -----------------------------------------------------------------------------
# GE-Proton changed its asset naming at GE-Proton11: releases now ship a
# -x86_64 and a -aarch64 tarball where they used to ship one unsuffixed file.
# Both spellings are still in play depending on which version you pin, and the
# aarch64 asset sorts first in the API listing, so picking "the first .tar.gz"
# lands you an ARM build on an amd64 host.
install_proton() {
    local requested="$1"
    local version="" url="" assets tarball tag base candidate

    if [ "${requested}" = "latest" ]; then
        echo "---Looking up the latest GE-Proton release---"
        assets="$(curl -fsSL "${PROTON_API}" \
                 | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')"
        if [ -z "${assets}" ] || [ "${assets}" = "null" ]; then
            echo "---Could not reach the GitHub API (rate limited?)---"
            echo "---Pin a version instead, e.g. PROTON_VERSION=GE-Proton9-27---"
            return 1
        fi
        url="$(printf '%s\n' "${assets}" | grep -m1 'x86_64\.tar\.gz$')" || \
            url="$(printf '%s\n' "${assets}" | head -n1)"
        version="$(basename "${url}" .tar.gz)"
    else
        # Accept either the release tag (GE-Proton11-5) or the full asset name
        # (GE-Proton11-5-x86_64); the download path always wants the tag.
        tag="${requested%-x86_64}"
        base="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${tag}"
        for candidate in "${tag}-x86_64" "${tag}"; do
            if [ -x "${PROTON_DIR}/${candidate}/proton" ]; then
                version="${candidate}"
                break
            fi
            if curl -fsIL -o /dev/null "${base}/${candidate}.tar.gz"; then
                version="${candidate}"
                url="${base}/${candidate}.tar.gz"
                break
            fi
        done
        if [ -z "${version}" ]; then
            echo "---No downloadable tarball for '${requested}'---"
            echo "---Expected ${tag}-x86_64.tar.gz or ${tag}.tar.gz on that release---"
            return 1
        fi
    fi

    if [ -x "${PROTON_DIR}/${version}/proton" ]; then
        echo "---${version} already installed---"
        PROTON_BIN="${PROTON_DIR}/${version}/proton"
        return 0
    fi

    echo "---Downloading ${version}---"
    tarball="/tmp/${version}.tar.gz"
    if ! curl -fL "${url}" -o "${tarball}"; then
        echo "---Download of ${version} failed---"
        rm -f "${tarball}"
        return 1
    fi

    # Verify before extracting. Every GE-Proton release publishes a .sha512sum
    # next to the tarball, naming the file exactly as we saved it. A missing
    # sums file is a warning rather than a failure; a mismatch is fatal.
    if curl -fsSL "${url%.tar.gz}.sha512sum" -o "${tarball}.sha512sum"; then
        if ( cd /tmp && sha512sum -c --status "$(basename "${tarball}").sha512sum" ); then
            echo "---Checksum verified---"
        else
            echo "---Checksum MISMATCH for ${version}, refusing to extract---"
            rm -f "${tarball}" "${tarball}.sha512sum"
            return 1
        fi
    else
        echo "---No published checksum for ${version}, skipping verification---"
    fi
    rm -f "${tarball}.sha512sum"

    mkdir -p "${PROTON_DIR}"
    echo "---Extracting ${version}---"
    tar -xzf "${tarball}" -C "${PROTON_DIR}"
    rm -f "${tarball}"

    if [ ! -x "${PROTON_DIR}/${version}/proton" ]; then
        echo "---${version} did not extract as expected---"
        return 1
    fi

    PROTON_BIN="${PROTON_DIR}/${version}/proton"
    return 0
}

PROTON_BIN=""
if ! install_proton "${PROTON_VERSION}"; then
    # Fall back to whatever build is already on disk rather than refusing to boot.
    PROTON_BIN="$(find "${PROTON_DIR}" -maxdepth 2 -name proton -type f -executable 2>/dev/null | sort -V | tail -n1)"
    if [ -z "${PROTON_BIN}" ]; then
        echo "---No usable Proton build available, exiting---"
        exit 1
    fi
    echo "---Falling back to $(basename "$(dirname "${PROTON_BIN}")")---"
fi
echo "---Using Proton: ${PROTON_BIN}---"

# ASA is sensitive to the Proton build, so say something when this is not the
# one the image was built and tested against. Checking for a deviation rather
# than for specific bad versions means this never goes stale, and it also
# catches a pinned old build or a fallback to whatever was already on disk.
PROTON_RESOLVED="$(basename "$(dirname "${PROTON_BIN}")")"
if [ -n "${PROTON_TESTED:-}" ] && [ "${PROTON_RESOLVED%-x86_64}" != "${PROTON_TESTED%-x86_64}" ]; then
    echo "---WARNING: this is not the Proton build this image was tested with---"
    echo "---  running: ${PROTON_RESOLVED}---"
    echo "---  tested:  ${PROTON_TESTED}---"
    echo "---If the server exits without producing any engine log output, this is---"
    echo "---the first thing to change: set PROTON_VERSION=${PROTON_TESTED} and---"
    echo "---delete ${PROTON_DIR} so the prefix is rebuilt.---"
fi

# WINEDEBUG=-all silences exactly the output you need when the server dies
# during startup, so DEBUG=true turns it back on and captures Proton's own log.
# +loaddll matters most here: when a Windows binary dies before reaching its own
# logging, the last DLL it loaded is usually the whole diagnosis.
if [ "${DEBUG,,}" = "true" ]; then
    export PROTON_LOG=1
    export PROTON_LOG_DIR="${SERVER_DIR}/logs"
    export WINEDEBUG="${WINEDEBUG_OVERRIDE:-+err,+fixme,+loaddll}"
    mkdir -p "${PROTON_LOG_DIR}"
    echo "---DEBUG is on: Proton log at ${PROTON_LOG_DIR}/steam-${GAME_ID}.log---"
    echo "---Turn it off once you have what you need; it is noisy and slows startup---"
fi

# Proton expects to be told which game it is running. Without SteamGameId it
# silently disables its own logging entirely (setup_logging returns early), and
# protonfixes decides it is running under a unit test and skips every fix. Both
# were happening here, which is why DEBUG=true produced no log at all.
export SteamAppId="${GAME_ID}"
export SteamGameId="${GAME_ID}"
export STEAM_COMPAT_APP_ID="${GAME_ID}"

# Proton's lsteamclient bridges the game's Windows Steam API calls to the
# native Linux steamclient.so, and it looks for that in exactly two places:
#
#   $HOME/.steam/sdk64/steamclient.so
#   $HOME/.steam/sdk32/steamclient.so
#
# (lsteamclient/unixlib.cpp). That is the long-standing convention for
# Steamworks dedicated servers. Miss it and lsteamclient does not fail softly -
# it asserts, aborting the process the moment the game first touches the Steam
# API, which for ASA is a second or so after startup. SteamCMD ships both
# libraries once it has run, so link them into place.
link_steam_sdk() {
    local bits src dst
    for bits in 64 32; do
        src="${STEAMCMD_DIR}/linux${bits}/steamclient.so"
        dst="${HOME}/.steam/sdk${bits}"
        if [ -f "${src}" ]; then
            mkdir -p "${dst}" 2>/dev/null || continue
            ln -sfn "${src}" "${dst}/steamclient.so" 2>/dev/null || true
        else
            echo "---Note: ${src} is missing; the Steam API bridge may not load---"
        fi
    done
}

export STEAM_COMPAT_CLIENT_INSTALL_PATH="${PROTON_DIR}/steam"
export STEAM_COMPAT_DATA_PATH="${PROTON_DIR}/prefix"
mkdir -p "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" "${STEAM_COMPAT_DATA_PATH}"

# A wine prefix belongs to the Proton build that created it, and handing one to
# a different build fails in ways that are hard to read. Record who built it and
# discard it when that changes, so switching PROTON_VERSION is enough on its own
# - no one should have to know to go and delete a folder by hand.
#
# Nothing here needs preserving: saves and configs live under ShooterGame/Saved,
# and Proton rebuilds the prefix on the next start.
PREFIX_MARKER="${STEAM_COMPAT_DATA_PATH}/.created-by-proton"
if [ -d "${STEAM_COMPAT_DATA_PATH}/pfx" ]; then
    PREFIX_BUILT_BY="$(cat "${PREFIX_MARKER}" 2>/dev/null || echo "an unknown build")"
    if [ "${PREFIX_BUILT_BY}" != "${PROTON_RESOLVED}" ]; then
        echo "---Prefix was built by ${PREFIX_BUILT_BY}, now running ${PROTON_RESOLVED}---"
        echo "---Discarding it so Proton rebuilds; saves and configs are untouched---"
        rm -rf "${STEAM_COMPAT_DATA_PATH:?}"
        mkdir -p "${STEAM_COMPAT_DATA_PATH}"
    fi
fi
printf '%s' "${PROTON_RESOLVED}" > "${PREFIX_MARKER}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Game files
# -----------------------------------------------------------------------------
echo "---Checking for ARK: Survival Ascended updates---"

STEAM_ARGS=( "+@sSteamCmdForcePlatformType" "windows" "+force_install_dir" "${SERVER_DIR}" )
if [ -n "${USERNAME}" ]; then
    STEAM_ARGS+=( "+login" "${USERNAME}" "${PASSWRD}" )
else
    STEAM_ARGS+=( "+login" "anonymous" )
fi
if [ "${VALIDATE,,}" = "true" ]; then
    echo "---Validate is enabled, this pass will take longer---"
    STEAM_ARGS+=( "+app_update" "${GAME_ID}" "validate" )
else
    STEAM_ARGS+=( "+app_update" "${GAME_ID}" )
fi
STEAM_ARGS+=( "+quit" )

"${STEAMCMD_DIR}/steamcmd.sh" "${STEAM_ARGS[@]}"
STEAM_RC=$?

if ! locate_game_dirs; then
    echo "---${SERVER_EXE} is missing after the SteamCMD run (exit ${STEAM_RC})---"
    echo "---The ASA depot is ~13GB, check free space and your appdata path---"
    exit 1
fi
if [ "${STEAM_RC}" -ne 0 ]; then
    echo "---SteamCMD exited ${STEAM_RC}, continuing with the files already on disk---"
fi

link_steam_sdk

echo "---Config directory: ${CONFIG_DIR}---"

# -----------------------------------------------------------------------------
# Config seed. Only written when absent - your edits are never overwritten.
# -----------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}"
if [ ! -f "${CONFIG_DIR}/GameUserSettings.ini" ]; then
    echo "---Seeding GameUserSettings.ini---"
    cat > "${CONFIG_DIR}/GameUserSettings.ini" <<EOF
[ServerSettings]
RCONEnabled=True
RCONPort=${RCON_PORT}
ServerAdminPassword=${SRV_ADMIN_PWD}
EOF
fi
[ -f "${CONFIG_DIR}/Game.ini" ] || touch "${CONFIG_DIR}/Game.ini"

if ! grep -qi "RCONEnabled=True" "${CONFIG_DIR}/GameUserSettings.ini"; then
    echo "---Note: RCON looks disabled in GameUserSettings.ini---"
    echo "---Without it this container can only hard-stop the server, which risks save loss---"
fi

# A short path to the configs, so the SMB share reads
# .../ark-sa/config/GameUserSettings.ini rather than the full nested path.
if [ ! -e "${SERVER_DIR}/config" ]; then
    ln -sfn "${CONFIG_DIR}" "${SERVER_DIR}/config" 2>/dev/null || true
fi

if [ "${FIX_PERMS,,}" = "true" ]; then
    resolve_config_modes
    echo "---Applying umask ${CONFIG_UMASK_EFFECTIVE} to ${SAVED_DIR} (files ${CONFIG_FILE_MODE}, dirs ${CONFIG_DIR_MODE})---"
fi
fix_share_perms

# -----------------------------------------------------------------------------
# Launch arguments
#
# ASA moved the important knobs off the ?-string and onto - flags. ?MaxPlayers=
# and ?Port= are silently ignored; -WinLiveMaxPlayers= and -port= are the real
# ones. ServerAdminPassword must be the LAST ? argument or the parser swallows
# whatever follows into the password value.
# -----------------------------------------------------------------------------
QUERY="${MAP}?listen"
[ -n "${SERVER_NAME}" ]        && QUERY+="?SessionName=${SERVER_NAME}"
[ -n "${QUERY_PARAMS_EXTRA}" ] && QUERY+="?${QUERY_PARAMS_EXTRA#\?}"
[ -n "${SRV_PWD}" ]            && QUERY+="?ServerPassword=${SRV_PWD}"
[ -n "${SRV_ADMIN_PWD}" ]      && QUERY+="?ServerAdminPassword=${SRV_ADMIN_PWD}"

FLAGS=( "-port=${GAME_PORT}" "-WinLiveMaxPlayers=${MAX_PLAYERS}" )
[ -n "${QUERY_PORT}" ] && FLAGS+=( "-QueryPort=${QUERY_PORT}" )
[ -n "${MODS}" ]       && FLAGS+=( "-mods=${MODS}" )
[ "${BATTLEYE,,}" = "false" ] && FLAGS+=( "-NoBattlEye" )
[ "${CROSSPLAY,,}" = "true" ] && FLAGS+=( "-crossplay" )
if [ -n "${CLUSTER_ID}" ]; then
    mkdir -p "${CLUSTER_DIR}"
    FLAGS+=( "-clusterid=${CLUSTER_ID}" "-ClusterDirOverride=${CLUSTER_DIR}" )
fi
if [ -n "${GAME_PARAMS_EXTRA}" ]; then
    read -ra EXTRA_ARR <<< "${GAME_PARAMS_EXTRA}"
    FLAGS+=( "${EXTRA_ARR[@]}" )
fi

# -----------------------------------------------------------------------------
# Shutdown handling. ARK writes its world on exit, so a plain SIGKILL is how
# people lose hours of progress. Ask nicely over RCON first.
# -----------------------------------------------------------------------------
wineserver_kill() {
    local ws
    ws="$(dirname "${PROTON_BIN}")/files/bin/wineserver"
    [ -x "${ws}" ] || ws="$(dirname "${PROTON_BIN}")/dist/bin/wineserver"
    if [ -x "${ws}" ]; then
        WINEPREFIX="${STEAM_COMPAT_DATA_PATH}/pfx" "${ws}" -k 2>/dev/null || true
    fi
}

stop_log_tail() {
    [ -n "${LOG_TAIL_PID}" ] || return 0
    kill "${LOG_TAIL_PID}" 2>/dev/null || true
    LOG_TAIL_PID=""
}

graceful_shutdown() {
    [ "${SHUTTING_DOWN}" = "true" ] && return
    SHUTTING_DOWN="true"
    echo "---Shutdown requested---"

    if [ -n "${SRV_ADMIN_PWD}" ] && grep -qi "RCONEnabled=True" "${CONFIG_DIR}/GameUserSettings.ini" 2>/dev/null; then
        echo "---Saving world via RCON---"
        python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT}" "${SRV_ADMIN_PWD}" "SaveWorld" || \
            echo "---RCON save failed, the server may already be down---"
        sleep 5
        echo "---Sending DoExit---"
        python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT}" "${SRV_ADMIN_PWD}" "DoExit" >/dev/null 2>&1 || true
    else
        echo "---No RCON available, stopping the process directly---"
    fi

    # Say something while waiting. A silent gap of up to STOP_TIMEOUT seconds
    # reads as a hang, and this is exactly when someone is deciding whether to
    # pull the plug on a server that is mid-save.
    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${waited}" -lt "${STOP_TIMEOUT}" ]; do
        sleep 2
        waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then
            echo "---Waiting for the server to exit (${waited}s of ${STOP_TIMEOUT}s)---"
        fi
    done

    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "---Still running after ${STOP_TIMEOUT}s, killing the wine prefix---"
        echo "---The world was already saved above, so this is not data loss---"
        wineserver_kill
        sleep 5
        kill -9 "${SERVER_PID}" 2>/dev/null || true
    fi

    # The server just rewrote its saves and configs on the way out; make sure
    # those new files are editable over the share too.
    fix_share_perms

    stop_log_tail
    echo "---Server stopped---"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
cd "${SERVER_EXE_DIR}" || exit 1

echo "---Starting ${MAP} on port ${GAME_PORT}, cap ${MAX_PLAYERS}---"
echo "---Launch line: ${SERVER_EXE} <query string hidden> ${FLAGS[*]}---"
echo "---First boot builds the Proton prefix and can sit quiet for several minutes---"

# Mirror the engine log into the container log, so the Unraid "Logs" button and
# `docker logs` show what the server is actually doing instead of only this
# script's own messages. ARK replaces ShooterGame.log on each start rather than
# appending, and `tail -F` follows by name: starting at -n 0 skips the previous
# run's contents, then it reopens the new file and reads it from the beginning.
ENGINE_LOG="${SAVED_DIR}/Logs/ShooterGame.log"
mkdir -p "$(dirname "${ENGINE_LOG}")" 2>/dev/null || true
tail -F -n 0 "${ENGINE_LOG}" 2>/dev/null &
LOG_TAIL_PID=$!

"${PROTON_BIN}" run "./${SERVER_EXE}" "${QUERY}" "${FLAGS[@]}" &
SERVER_PID=$!

wait "${SERVER_PID}"
EXIT_CODE=$?

stop_log_tail

if [ "${SHUTTING_DOWN}" = "false" ]; then
    echo "---Server exited on its own with code ${EXIT_CODE}---"
    # A server that dies before writing an engine log failed in Proton or in
    # loading the binary, not in ARK itself. Saying which narrows it a lot.
    if [ ! -s "${SAVED_DIR}/Logs/ShooterGame.log" ]; then
        echo "---No engine log was written, so it failed before ARK started.---"
        echo "---Set DEBUG=true and restart to capture wine and Proton output.---"
    fi
    fix_share_perms
fi
exit "${EXIT_CODE}"
