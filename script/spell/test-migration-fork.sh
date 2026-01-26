#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/spell/test-migration-fork.sh ethereum
# ./script/spell/test-migration-fork.sh base
# ./script/spell/test-migration-fork.sh arbitrum
# ./script/spell/test-migration-fork.sh plume
# ./script/spell/test-migration-fork.sh avalanche
# ./script/spell/test-migration-fork.sh bnb-smart-chain
#
# Only requirements is to have PLUME_API_KEY and ALCHEMY_API_KEY in the .env file

export NETWORK=$1
export VERSION="v3.1"

if [ "$NETWORK" == "plume" ]; then
    PLUME_API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
    REMOTE_RPC_URL="https://rpc.plume.org/$PLUME_API_KEY"
else
    ALCHEMY_API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
    ALCHEMY_NAME=$(jq -r --arg net "$NETWORK" '.mainnet[$net] // empty' script/deploy/config/alchemy_networks.json)
    REMOTE_RPC_URL="https://$ALCHEMY_NAME.g.alchemy.com/v2/$ALCHEMY_API_KEY"
fi

GUARDIAN_V3="0xFEE13c017693a4706391D516ACAbF6789D5c3157"
ADMIN_V3=$(jq -r '.network.safeAdmin' env/"$NETWORK".json)

PROTOCOL_ADMIN="0x9711730060C73Ee7Fcfe1890e8A0993858a7D225"
OPS_ADMIN="0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16"

DEPLOYER_V3_1="0x926702C7f1af679a8f99A40af8917DDd82fD6F6c"
SPELL_EXECUTOR="$OPS_ADMIN"
ANY="0x1234567890000000000000000000000000000000"

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

mock_addr "$ADMIN_V3"
mock_addr "$DEPLOYER_V3_1"
mock_addr "$SPELL_EXECUTOR"
mock_addr "$PROTOCOL_ADMIN"
mock_addr "$OPS_ADMIN"
mock_addr "$ANY"

CHAIN_ID=$(cast chain-id --rpc-url "$LOCAL_RPC_URL")

echo ""
echo "##########################################################################"
echo "#                          STEP 1: Deploy V3.1"
echo "##########################################################################"
echo ""

# Important! Deploying for the migrations requires to have ROOT envvar exported at this time.
export ROOT=$(cast call $GUARDIAN_V3 "root()(address)" --rpc-url "$LOCAL_RPC_URL")
forge script script/LaunchDeployer.s.sol \
    --optimize \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$DEPLOYER_V3_1" \
    --broadcast

VERSION="$VERSION" ./script/deploy/update_network_config.py "$NETWORK" --script LaunchDeployer.s.sol

echo ""
echo "##########################################################################"
echo "#                    STEP 2: Deploy migration spell"
echo "##########################################################################"
echo ""

forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1Deployer \
    --sig "run(address)" $SPELL_EXECUTOR \
    --optimize \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$ANY" \
    --broadcast

MIGRATION_SPELL=$(jq -r '.transactions[] | select(.contractName=="MigrationSpell") | .contractAddress' \
    broadcast/MigrationV3_1.s.sol/"$CHAIN_ID"/run-latest.json)

echo ""
echo "##########################################################################"
echo "#              STEP 3: Request root permissions to the spell"
echo "##########################################################################"
echo ""

cast send $GUARDIAN_V3 "scheduleRely(address)" "$MIGRATION_SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ADMIN_V3"

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
echo "#              STEP 4: Get root permissions to the spell"
echo "##########################################################################"
echo ""

cast send "$ROOT" "executeScheduledRely(address)" "$MIGRATION_SPELL" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ANY"

echo ""
echo "##########################################################################"
echo "#                        STEP 5: Block protocol"
echo "##########################################################################"
echo ""

cast send $GUARDIAN_V3 "pause()" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$ADMIN_V3"

echo ""
echo "##########################################################################"
echo "#                    STEP 6: Run pre-validations"
echo "##########################################################################"
echo ""

PRE_VALIDATION=true
forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
    --rpc-url "$LOCAL_RPC_URL" \
    --sig "validate(string,string,address,bool, address)" \
    "$NETWORK" \
    "$LOCAL_RPC_URL" \
    "$PROTOCOL_ADMIN" \
    "$PRE_VALIDATION" \
    "$SPELL_EXECUTOR"

echo ""
echo "##########################################################################"
echo "#                       STEP 7: Run migration"
echo "##########################################################################"
echo ""

forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1ExecutorMainnet \
    --sig "run(address,string,address)" "$DEPLOYER_V3_1" "" "$MIGRATION_SPELL" \
    --optimize \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$SPELL_EXECUTOR" \
    --broadcast

echo ""
echo "##########################################################################"
echo "#                    STEP 8: Run post-validations"
echo "##########################################################################"
echo ""

POST_VALIDATION=false
forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
    --rpc-url "$LOCAL_RPC_URL" \
    --sig "validate(string,string,address,bool,address)" \
    "$NETWORK" \
    "$LOCAL_RPC_URL" \
    "$PROTOCOL_ADMIN" \
    "$POST_VALIDATION" \
    "$SPELL_EXECUTOR"

echo ""
echo "##########################################################################"
echo "#                       STEP 9: Unpause protocol"
echo "##########################################################################"
echo ""

PROTOCOL_GUARDIAN=$(jq -r '.contracts.protocolGuardian.address' env/"$NETWORK".json)

cast send "$PROTOCOL_GUARDIAN" "unpause()" \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --from "$PROTOCOL_ADMIN"
