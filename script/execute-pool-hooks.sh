#!/bin/bash
set -euo pipefail

set -a; source .env; set +a # auto-export all sourced vars

# Example of different runs:
# ./script/execute-pool-hooks.sh ethereum
# ./script/execute-pool-hooks.sh base
# ./script/execute-pool-hooks.sh arbitrum
# ./script/execute-pool-hooks.sh plume
# ./script/execute-pool-hooks.sh avalanche
# ./script/execute-pool-hooks.sh bnb-smart-chain

NETWORK=$1

BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' env/"$NETWORK".json)
if [ "$NETWORK" == "plume" ]; then
    API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
else
    API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
fi
REMOTE_RPC_URL="${BASE_RPC_URL}${API_KEY}"

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Run PoolHooks script"
echo "##########################################################################"
echo ""

forge script script/PoolHooks.s.sol:PoolHooks \
    --optimize \
    --rpc-url "$RPC_URL" \
    --resume \
    --verify \
    --private-key "$PRIVATE_KEY" \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --broadcast

echo ""
echo "##########################################################################"
echo "#                           Done!"
echo "##########################################################################"
echo ""
