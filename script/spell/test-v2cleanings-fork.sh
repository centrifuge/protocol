#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/spell/test-v2cleanings-fork.sh ethereum
# ./script/spell/test-v2cleanings-fork.sh base
# ./script/spell/test-v2cleanings-fork.sh arbitrum
#
# Only requirements is to have ALCHEMY_API_KEY in the .env file

export NETWORK=$1

ALCHEMY_API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' env/"$NETWORK".json)
REMOTE_RPC_URL="${BASE_RPC_URL}${ALCHEMY_API_KEY}"

PROTOCOL_GUARDIAN="0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6"
GUARDIAN_V2_ETHEREUM_OR_ARBITRUM="0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8";
GUARDIAN_V2_BASE="0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9";

PROTOCOL_ADMIN=$(jq -r '.network.protocolAdmin' env/"$NETWORK".json)
ADMIN_V2_ETHEREUM="0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD"
ADMIN_V2_BASE="0x8b83962fB9dB346a20c95D98d4E312f17f4C0d9b"
ADMIN_V2_ARBITRUM="0xa36caE0ACd40C6BbA61014282f6AE51c7807A433"

ANY="0x1234567890000000000000000000000000000000"

case "$NETWORK" in
    ethereum)
        GUARDIAN_V2=$GUARDIAN_V2_ETHEREUM_OR_ARBITRUM
        ADMIN_V2=$ADMIN_V2_ETHEREUM
        ;;
    base)
        GUARDIAN_V2=$GUARDIAN_V2_BASE
        ADMIN_V2=$ADMIN_V2_BASE
        ;;
    arbitrum)
        GUARDIAN_V2=$GUARDIAN_V2_ETHEREUM_OR_ARBITRUM
        ADMIN_V2=$ADMIN_V2_ARBITRUM
        ;;
esac

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

mock_addr() {
    cast rpc anvil_impersonateAccount "$1" \
        --rpc-url "$LOCAL_RPC_URL"

    cast rpc anvil_setBalance "$1" $(cast --to-hex 1000000000000000000000) \
        --rpc-url "$LOCAL_RPC_URL"
}

mock_addr "$PROTOCOL_ADMIN"
mock_addr "$ADMIN_V2"
mock_addr "$ANY"

CHAIN_ID=$(cast chain-id --rpc-url "$LOCAL_RPC_URL")
ROOT_V3=$(cast call $PROTOCOL_GUARDIAN "root()(address)" --rpc-url "$LOCAL_RPC_URL")
ROOT_V2=$(cast call $GUARDIAN_V2 "root()(address)" --rpc-url "$LOCAL_RPC_URL")

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Deploy spell"
echo "##########################################################################"
echo ""

forge script script/spell/V2Cleanings.s.sol:V2CleaningsDeployer \
    --optimize \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$ANY" \
    --broadcast

SPELL=$(jq -r '.transactions[] | select(.contractName=="V2CleaningsSpell") | .contractAddress' \
    broadcast/V2Cleanings.s.sol/"$CHAIN_ID"/run-latest.json)

echo ""
echo "##########################################################################"
echo "#              STEP 2: Request root permissions to the spell"
echo "##########################################################################"
echo ""

cast send $PROTOCOL_GUARDIAN "scheduleRely(address)" "$SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$PROTOCOL_ADMIN"

cast send $GUARDIAN_V2 "scheduleRely(address)" "$SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ADMIN_V2"

echo ""
echo "##########################################################################"
echo "#                    INTERLUDE: Mock passing 48 hours"
echo "##########################################################################"
echo ""

# As a mocked process to skip 48 hours of delay
cast rpc evm_increaseTime 172800 \
    --rpc-url $LOCAL_RPC_URL \

# Mine a new block to set the new timestamp
cast rpc evm_mine \
    --rpc-url $LOCAL_RPC_URL

echo ""
echo "##########################################################################"
echo "#              STEP 3: Get root permissions to the spell"
echo "##########################################################################"
echo ""

cast send "$ROOT_V3" "executeScheduledRely(address)" "$SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ANY"

cast send "$ROOT_V2" "executeScheduledRely(address)" "$SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ANY"

echo ""
echo "##########################################################################"
echo "#                       STEP 4: Run migration"
echo "##########################################################################"
echo ""

forge script script/spell/V2Cleanings.s.sol:V2CleaningsExecutor \
    --sig "run(address)" "$SPELL" \
    --optimize \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$ANY" \
    --broadcast
