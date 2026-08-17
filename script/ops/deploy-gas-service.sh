#!/bin/bash

# Deploys the GasService and proposes it through OpsGuardian on every mainnet in env/. The one wrapper that
# takes no network: it is the loop over all of them.
#
#   PROPOSER=<safe_proposer_address> VERSION=<version> ./script/ops/deploy-gas-service.sh
#
# No signer flag, deliberately: like unpause-protocol.sh this proposes to a Safe through safe-utils, which
# drives the Ledger itself. The proposer is named as the sender only.

set -euo pipefail

set -a; source .env; set +a

# Proposer address (Ledger account that will sign the Safe proposals)
PROPOSER="${PROPOSER:?Missing PROPOSER env var}"
VERSION="${VERSION:?Missing VERSION env var}"

for NETWORK_FILE in env/*.json; do
    NETWORK=$(basename "$NETWORK_FILE" .json)
    ENV=$(jq -r '.network.environment' "$NETWORK_FILE")

    if [ "$ENV" != "mainnet" ]; then
        continue
    fi

    echo ""
    echo "========================================================"
    echo " Network: $NETWORK"
    echo "========================================================"
    echo ""

    # The network name is an [rpc_endpoints] alias in foundry.toml, which is where a base URL and its API key
    # are composed, so there is nothing to assemble here
    NETWORK="$NETWORK" VERSION="$VERSION" forge script script/ops/DeployGasService.s.sol:DeployGasService \
        --rpc-url "$NETWORK" \
        --sender "$PROPOSER" \
        --broadcast
done

echo ""
echo "Done. GasService deployed and OpsGuardian.setGasService proposed on all mainnet networks."
echo ""
