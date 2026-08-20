# Trixie, not bookworm: GE-Proton 11 links against GLIBC_2.38 and bookworm
# ships 2.36, so wine fails to load ntdll.so and the server exits code 1.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="ARK: Survival Ascended Dedicated Server" \
      org.opencontainers.image.description="ASA dedicated server (Windows binary via GE-Proton), SteamCMD-based, Unraid friendly. Inspired by ich777/steamcmd." \
      org.opencontainers.image.source="https://github.com/blckassassin/ArkSA" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND="noninteractive" \
    STEAMCMD_DIR="/serverdata/steamcmd" \
    SERVER_DIR="/serverdata/serverfiles" \
    PROTON_DIR="/serverdata/serverfiles/proton" \
    GAME_ID="2430930" \
    GAME_PORT="7777" \
    QUERY_PORT="27015" \
    RCON_PORT="27020" \
    MAX_PLAYERS="20" \
    MAP="TheIsland_WP" \
    SERVER_NAME="ASA Server" \
    SRV_PWD="" \
    SRV_ADMIN_PWD="adminpassword" \
    MODS="" \
    CLUSTER_ID="" \
    CLUSTER_DIR="/serverdata/serverfiles/cluster" \
    BATTLEYE="false" \
    CROSSPLAY="false" \
    GAME_PARAMS_EXTRA="" \
    QUERY_PARAMS_EXTRA="" \
    PROTON_TESTED="GE-Proton10-34" \
    PROTON_VERSION="GE-Proton10-34" \
    VALIDATE="" \
    USERNAME="" \
    PASSWRD="" \
    UID="99" \
    GID="100" \
    DATA_PERM="775" \
    CONFIG_UMASK="" \
    FIX_PERMS="true" \
    UMASK="000" \
    STOP_TIMEOUT="120" \
    LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/lib32" \
    DEBUG="false" \
    WINEDEBUG="-all" \
    DXVK_HUD="0" \
    PROTON_USE_WINED3D="1" \
    PROTON_NO_ESYNC="0" \
    PROTON_NO_FSYNC="0"

# lib32gcc-s1 -> SteamCMD. python3 -> the GE-Proton launcher is a Python script.
# The X/GL/freetype libs are what wine expects to find on the host even headless.
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        tar \
        xz-utils \
        bzip2 \
        unzip \
        zip \
        procps \
        net-tools \
        jq \
        gosu \
        tini \
        python3 \
        python3-minimal \
        lib32gcc-s1 \
        libatomic1 \
        libfreetype6 \
        libgl1 \
        libvulkan1 \
        libx11-6 \
        libxext6 \
        libxrandr2 \
        libnss3 \
        libgnutls30 \
        libglib2.0-0 \
        libdbus-1-3 \
        libudev1 \
        locales && \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen && \
    useradd -u ${UID} -d /home/steam -m -s /bin/bash steam && \
    mkdir -p ${STEAMCMD_DIR} ${SERVER_DIR} ${PROTON_DIR} && \
    apt-get -y autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

COPY scripts/ /opt/scripts/
RUN chmod -R 755 /opt/scripts

# 7777/udp  game traffic (required)
# 7778/udp  peer port, game port + 1 (try it if players get flaky connects)
# 27015/udp legacy Steam query port - vestigial in ASA, discovery goes via EOS
# 27020/tcp RCON, only if you administer remotely
EXPOSE 7777/udp 7778/udp 27015/udp 27020/tcp

# Proton lives inside serverfiles, so it must NOT be declared here: a nested
# VOLUME would shadow the parent mount.
VOLUME ["/serverdata/steamcmd", "/serverdata/serverfiles"]

# No -g here on purpose: process-group signalling would SIGTERM the wine
# processes directly and defeat the save-then-exit handler in start-server.sh.
# tini still reaps the zombies wine leaves behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/start.sh"]
