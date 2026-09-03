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
    GAME_LANGUAGE="en/US" \
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
