#!/bin/bash
set -euo pipefail

# Serves env/ and opens the connections viewer for one environment.
#
#   ./env/connections_viewer.sh [environment] [port]    # defaults: the one environment here, 8000
#
# The viewer fetches env/<environment>/connections.json, and browsers block fetch()
# on file:// pages, so env/ must be served over HTTP. Ctrl+C stops the server.
#
# Which environments have a connections file depends on the branch — main holds only a local
# run's env/anvil-<id>/ — so the default is whatever single one is here, and a choice is asked for
# when there are several.

cd "$(dirname "$0")"
FOUND=$(ls -d */connections.json 2>/dev/null | xargs -n1 dirname 2>/dev/null | tr "\n" " " | sed "s/ $//" || true)

ENVIRONMENT=${1:-}
PORT=${2:-8000}
if [[ -z "$ENVIRONMENT" ]]; then
    if [[ $(wc -w <<< "$FOUND") -ne 1 ]]; then
        echo "Name the environment: ./env/connections_viewer.sh <environment> [port]" >&2
        echo "Those with a connections.json here: ${FOUND:-none}" >&2
        exit 1
    fi
    ENVIRONMENT=$FOUND
fi
[[ -f "$ENVIRONMENT/connections.json" ]] || {
    echo "No env/$ENVIRONMENT/connections.json. Those here: ${FOUND:-none}" >&2; exit 1;
}

OPEN=$(command -v open || command -v xdg-open)
(sleep 1 && "$OPEN" "http://localhost:$PORT/connections_viewer.html#$ENVIRONMENT") &
exec python3 -m http.server "$PORT" -d .
