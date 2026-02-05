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
# Only requirement is to have ALCHEMY_API_KEY (or PLUME_API_KEY for plume) in the .env file

NETWORK=$1

BASE_RPC_URL=$(jq -r '.network.baseRpcUrl' env/"$NETWORK".json)
if [ "$NETWORK" == "plume" ]; then
    API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
else
    API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
fi
REMOTE_RPC_URL="${BASE_RPC_URL}${API_KEY}"

GUARDIAN_V3="0xFEE13c017693a4706391D516ACAbF6789D5c3157"
ADMIN_V3=$(jq -r '.network.safeAdmin' env/"$NETWORK".json)

PROTOCOL_ADMIN="0x9711730060C73Ee7Fcfe1890e8A0993858a7D225"
OPS_ADMIN="0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16"

DEPLOYER_V3_1="0x926702C7f1af679a8f99A40af8917DDd82fD6F6c"
SPELL_EXECUTOR="$OPS_ADMIN"
MIGRATION_SPELL="0xe97ac43a22b8df15d53503cf8001f12c6b349327"

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

CHAIN_ID=$(cast chain-id --rpc-url "$LOCAL_RPC_URL")
ROOT="0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f"

echo ""
echo "##########################################################################"
echo "#                          STEP 1: Deploy V3.1"
echo "##########################################################################"
echo " Done!"

echo ""
echo "##########################################################################"
echo "#                    STEP 2: Deploy migration spell"
echo "##########################################################################"
echo " Done!"

echo ""
echo "##########################################################################"
echo "#              STEP 3: Request root permissions to the spell"
echo "##########################################################################"
echo " Done!"

echo ""
echo "##########################################################################"
echo "#                    INTERLUDE: Mock passing 48 hours"
echo "##########################################################################"
echo " Done!"

echo ""
echo "##########################################################################"
echo "#              STEP 4: Get root permissions to the spell"
echo "##########################################################################"
echo " Done!"

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
