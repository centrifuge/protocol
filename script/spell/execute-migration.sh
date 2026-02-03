#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/spell/execute-migration.sh ethereum
# ./script/spell/execute-migration.sh base
# ./script/spell/execute-migration.sh arbitrum
# ./script/spell/execute-migration.sh plume
# ./script/spell/execute-migration.sh avalanche
# ./script/spell/execute-migration.sh bnb-smart-chain
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

PROTOCOL_ADMIN="0x9711730060C73Ee7Fcfe1890e8A0993858a7D225"
OPS_ADMIN="0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16"
DEPLOYER_V3_1="0x926702C7f1af679a8f99A40af8917DDd82fD6F6c"
SPELL_EXECUTOR="$OPS_ADMIN"

MIGRATION_SPELL="0xe97ac43a22b8df15d53503cf8001f12c6b349327"
CHAIN_ID=$(cast chain-id --rpc-url "$REMOTE_RPC_URL")

PROPOSER="0x701Da7A0c8ee46521955CC29D32943d47E2c02b9"
DERIVATION_PATH="m/44'/60'/0'/0/0"

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Run pre-validations"
echo "##########################################################################"
echo ""

PRE_VALIDATION=true
forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
    --rpc-url "$REMOTE_RPC_URL" \
    --sig "validate(string,string,address,bool,address)" \
    "$NETWORK" \
    "$REMOTE_RPC_URL" \
    "$PROTOCOL_ADMIN" \
    "$PRE_VALIDATION" \
    "$SPELL_EXECUTOR"

echo ""
echo "##########################################################################"
echo "#                       STEP 2: Run migration"
echo "##########################################################################"
echo ""

forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1ExecutorMainnet \
    --sig "run(address,string,address)" "$DEPLOYER_V3_1" "$DERIVATION_PATH" "$MIGRATION_SPELL" \
    --rpc-url "$REMOTE_RPC_URL" \
    --sender "$PROPOSER" \
    --broadcast

echo ""
echo "##########################################################################"
echo "#                    STEP 3: Run post-validations"
echo "##########################################################################"
echo ""

POST_VALIDATION=false
forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
    --rpc-url "$REMOTE_RPC_URL" \
    --sig "validate(string,string,address,bool,address)" \
    "$NETWORK" \
    "$REMOTE_RPC_URL" \
    "$PROTOCOL_ADMIN" \
    "$POST_VALIDATION" \
    "$SPELL_EXECUTOR"

