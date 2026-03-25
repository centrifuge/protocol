#!/bin/bash

# Deploys the GasService and propose it using OpsGuardian in all mainnet chains
# Usage: PROPOSER=<safe_proposer_address> script/deploy-gas-service.sh

set -euo pipefail

set -a; source .env; set +a

# Proposer address (Ledger account that will sign the Safe proposals)
PROPOSER="${PROPOSER:?Missing PROPOSER env var}"

for NETWORK_FILE in env/*.json; do
    NETWORK=$(basename "$NETWORK_FILE" .json)
    ENV=$(jq -r '.network.environment' "$NETWORK_FILE")

    if [ "$ENV" != "mainnet" ]; then
        continue
    fi

    BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' "$NETWORK_FILE")

    # Mirror NetworkConfigLib.rpcUrl() logic
    if [[ "$BASE_RPC_URL" == *"alchemy"* ]]; then
        RPC_URL="${BASE_RPC_URL}${ALCHEMY_API_KEY:?Missing ALCHEMY_API_KEY}"
    elif [[ "$BASE_RPC_URL" == *"plume"* ]]; then
        RPC_URL="${BASE_RPC_URL}${PLUME_API_KEY:?Missing PLUME_API_KEY}"
    elif [[ "$BASE_RPC_URL" == *"pharos"* ]]; then
        RPC_URL="${BASE_RPC_URL}${PHAROS_API_KEY:?Missing PHAROS_API_KEY}"
    else
        RPC_URL="$BASE_RPC_URL"
    fi

    echo ""
    echo "========================================================"
    echo " Network: $NETWORK"
    echo "========================================================"
    echo ""

    NETWORK="$NETWORK" forge script script/DeployGasService.s.sol:DeployGasService \
        --rpc-url "$RPC_URL" \
        --sender "$PROPOSER" \
        --broadcast
done

echo ""
echo "Done. GasService deployed and OpsGuardian.setGasService proposed on all mainnet networks."
echo ""
