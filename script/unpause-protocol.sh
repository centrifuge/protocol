#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/spell/unpause-protocol.sh ethereum
# ./script/spell/unpause-protocol.sh base
# ./script/spell/unpause-protocol.sh arbitrum
# ./script/spell/unpause-protocol.sh plume
# ./script/spell/unpause-protocol.sh avalanche
# ./script/spell/unpause-protocol.sh bnb-smart-chain
#
# Only requirement is to have ALCHEMY_API_KEY (or PLUME_API_KEY for plume) in the .env file

NETWORK=$1

BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' env/"$NETWORK".json)
if [ "$NETWORK" == "plume" ]; then
    API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
else
    API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
fi
REMOTE_RPC_URL="${BASE_RPC_URL}${API_KEY}"

PROPOSER="0x701Da7A0c8ee46521955CC29D32943d47E2c02b9"

forge script ProposeUnpause \
    --rpc-url "$REMOTE_RPC_URL" \
    --sender "$PROPOSER" \
    --broadcast

