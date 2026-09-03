#!/bin/bash
# Run an RCON command against the server in this container.
#
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh SaveWorld
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh "Broadcast Restarting in 5"
#   docker exec ARK-Survival-Ascended /opt/scripts/rcon-cli.sh ListPlayers

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <rcon command> [more commands...]"
    exit 2
fi

exec python3 /opt/scripts/rcon.py 127.0.0.1 "${RCON_PORT:-27020}" "${SRV_ADMIN_PWD}" "$@"
