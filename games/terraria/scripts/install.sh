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
    local partial="${want}.partial"

    # TERRARIA_VERSION drives ${want}, and a successful install rm -rf's
    # ${want}. An empty or garbage value (e.g. a blanked Unraid template
    # field) must never resolve to ${SERVER_DIR} itself.
    if ! [[ "${TERRARIA_VERSION}" =~ ^[0-9]+$ ]]; then
        echo "---TERRARIA_VERSION '${TERRARIA_VERSION}' is not a valid version number, refusing to install---"
        return 1
    fi
    if [ "${want}" = "${SERVER_DIR}" ] || [ "${want}" = "${SERVER_DIR}/" ]; then
        echo "---Refusing to install: computed path '${want}' is the server directory itself---"
        return 1
    fi

    # A leftover .partial from a run killed mid-move must not confuse the
    # next attempt.
    rm -rf "${partial}"

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
    if ! curl -fL --no-progress-meter "${url}" -o "${zip}"; then
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

    # Move onto the volume as a sibling first, not over the live install. /tmp
    # (staging) and ${SERVER_DIR} (a VOLUME) are very likely different
    # filesystems, so this is a copy+unlink rather than an atomic rename — a
    # failure partway must never have already destroyed the previous good
    # install.
    if ! mv "${staging}/${TERRARIA_VERSION}/Linux" "${partial}"; then
        echo "---Move to ${partial} failed, existing install left untouched---"
        rm -rf "${staging}" "${zip}" "${partial}"
        return 1
    fi
    rm -rf "${staging}" "${zip}"

    chmod +x "${partial}/TerrariaServer.bin.x86_64"
    if [ ! -x "${partial}/TerrariaServer.bin.x86_64" ]; then
        echo "---${partial} has no executable server binary, refusing to activate it---"
        rm -rf "${partial}"
        return 1
    fi

    # Same filesystem now, so this rename is atomic.
    rm -rf "${want}"
    mv "${partial}" "${want}"
    ln -sfn "${want}" "${active}"
    echo "---Terraria ${TERRARIA_VERSION} installed---"
    return 0
}
