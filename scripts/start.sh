#!/bin/bash
# Root entrypoint: reconcile the steam user with the UID/GID the host wants
# (99:100 on Unraid), fix ownership, then hand off to the unprivileged runner.

set -u

echo "---Preparing container---"

umask "${UMASK:-000}"

# -----------------------------------------------------------------------------
# Resolve the target ids.
#
# Careful here: bash marks UID readonly and seeds it from getuid() when it is
# absent from the environment, so a bare "${UID}" can silently mean "0" rather
# than "the id the user asked for". Resolve into our own variables, and accept
# the PUID/PGID spelling too since plenty of people have it in muscle memory.
# -----------------------------------------------------------------------------
TARGET_UID="${PUID:-${UID:-99}}"
TARGET_GID="${PGID:-${GID:-100}}"

if [ "${TARGET_UID}" = "0" ] || ! [[ "${TARGET_UID}" =~ ^[0-9]+$ ]]; then
    echo "---UID '${TARGET_UID}' is not usable, falling back to 99---"
    TARGET_UID="99"
fi
if ! [[ "${TARGET_GID}" =~ ^[0-9]+$ ]]; then
    echo "---GID '${TARGET_GID}' is not usable, falling back to 100---"
    TARGET_GID="100"
fi

# -----------------------------------------------------------------------------
# Group. Two distinct cases: the target gid already exists under some other name
# (100 is 'users' on Unraid, so join it), or it does not exist yet (renumber the
# steam group). Getting this backwards leaves usermod pointing at a missing gid.
# -----------------------------------------------------------------------------
if [ "$(id -g steam)" != "${TARGET_GID}" ]; then
    if getent group "${TARGET_GID}" >/dev/null 2>&1; then
        echo "---Adding steam to existing group $(getent group "${TARGET_GID}" | cut -d: -f1) (${TARGET_GID})---"
        usermod -g "${TARGET_GID}" steam
    else
        echo "---Setting steam group id to ${TARGET_GID}---"
        groupmod -o -g "${TARGET_GID}" steam
    fi
fi

# -----------------------------------------------------------------------------
# User.
# -----------------------------------------------------------------------------
if [ "$(id -u steam)" != "${TARGET_UID}" ]; then
    echo "---Setting steam user id to ${TARGET_UID}---"
    usermod -o -u "${TARGET_UID}" steam
fi

# -----------------------------------------------------------------------------
# Directories.
# -----------------------------------------------------------------------------
# wine logs "Failed to open /etc/machine-id" without this; debian-slim ships no
# machine-id. Generated per container rather than baked into the image.
if [ ! -s /etc/machine-id ]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/machine-id 2>/dev/null || true
fi

mkdir -p "${STEAMCMD_DIR}" "${SERVER_DIR}" "${PROTON_DIR}" /home/steam

# A recursive chown over 60+ GB of ARK files on every boot is painful, so only do
# the deep pass when the top-level owner actually looks wrong. Set
# FORCE_CHOWN=true to run it unconditionally if permissions ever get tangled.
for DIR in "${STEAMCMD_DIR}" "${SERVER_DIR}" "${PROTON_DIR}" /home/steam; do
    if [ "$(stat -c %u "${DIR}")" != "${TARGET_UID}" ] || [ "${FORCE_CHOWN:-false}" = "true" ]; then
        echo "---Fixing ownership on ${DIR} (slow the first time, this is normal)---"
        chown -R "${TARGET_UID}:${TARGET_GID}" "${DIR}"
    else
        chown "${TARGET_UID}:${TARGET_GID}" "${DIR}"
    fi
done

# Top-level modes. 775 rather than 770 so an SMB client that is not the owner
# and not in the group can still traverse in; the recursive pass over the config
# and save tree happens in start-server.sh once the install has been located.
chmod "${DATA_PERM:-775}" "${SERVER_DIR}" 2>/dev/null || true
chmod a+rX "${SERVER_DIR}" 2>/dev/null || true

echo "---Starting as user steam (${TARGET_UID}:${TARGET_GID})---"
exec gosu steam /opt/scripts/start-server.sh
