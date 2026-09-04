#!/bin/bash
# Send a console command to the running Terraria server.
#
#   docker exec <container> /opt/scripts/console.sh say hello
#   docker exec <container> /opt/scripts/console.sh save
#
# Safe to call: start-server.sh holds the FIFO open read-write, so this open
# never blocks even if the server itself has died.
set -eu

FIFO="/tmp/terraria-console.fifo"

if [ "$#" -eq 0 ]; then
    echo "usage: console.sh <terraria console command>" >&2
    exit 2
fi

if [ ! -p "${FIFO}" ]; then
    echo "No console FIFO at ${FIFO}. Is the server running in this container?" >&2
    exit 1
fi

printf '%s\n' "$*" > "${FIFO}"
