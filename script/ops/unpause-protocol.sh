#!/bin/bash
set -euo pipefail

# Proposes the unpause to the protocol Safe on one network.
#
#   ./script/ops/unpause-protocol.sh <network>      # any name in env/, e.g. ethereum
#
# Needs whichever API key the network's [rpc_endpoints] entry references in .env
# (./script/setup/load-secrets.sh).

NETWORK=${1:?Usage: $0 <network>}
[ -f "env/$NETWORK.json" ] || { echo "No env/$NETWORK.json. The network is the name of an env config" >&2; exit 1; }

PROPOSER="0x701Da7A0c8ee46521955CC29D32943d47E2c02b9"

# No signer flag, deliberately: this proposes to a Safe through safe-utils, which drives the Ledger itself
# from a derivation path. Passing --ledger here would take the device away from it. The proposer is named as
# the sender only, so the script knows which Safe owner it is signing as.
#
# The network name is an [rpc_endpoints] alias, which is where a base URL and its API key are composed
forge script ProposeUnpause \
    --rpc-url "$NETWORK" \
    --sender "$PROPOSER" \
    --broadcast

