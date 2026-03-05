#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/test-pool-hooks-fork.sh ethereum
# ./script/test-pool-hooks-fork.sh base
# ./script/test-pool-hooks-fork.sh arbitrum
# ./script/test-pool-hooks-fork.sh plume
# ./script/test-pool-hooks-fork.sh avalanche
# ./script/test-pool-hooks-fork.sh bnb-smart-chain

NETWORK=$1

mock_addr() {
    cast rpc anvil_impersonateAccount "$1" \
        --rpc-url "$LOCAL_RPC_URL"

    cast rpc anvil_setBalance "$1" $(cast --to-hex 1000000000000000000000) \
        --rpc-url "$LOCAL_RPC_URL"
}

BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' env/"$NETWORK".json)
if [ "$NETWORK" == "plume" ]; then
    API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
else
    API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
fi
REMOTE_RPC_URL="${BASE_RPC_URL}${API_KEY}"

echo ""
echo "##########################################################################"
echo "#                   STEP 0: Start anvil in fork mode"
echo "##########################################################################"
echo ""

anvil --fork-url "$REMOTE_RPC_URL" &
ANVIL_PID=$!
trap "kill $ANVIL_PID" EXIT

LOCAL_RPC_URL="http://127.0.0.1:8545" #anvil

sleep 3.0 # Wait ensuring Anvil is up

SENDER="0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb"
mock_addr "$SENDER"

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Run PoolHooks script"
echo "##########################################################################"
echo ""

NETWORK="$NETWORK" forge script script/PoolHooks.s.sol:PoolHooks \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$SENDER" \
    --broadcast \
    -vv

echo ""
echo "##########################################################################"
echo "#                           Done!"
echo "##########################################################################"
echo ""
