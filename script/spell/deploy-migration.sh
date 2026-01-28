#!/bin/bash
set -euo pipefail

# Required secrets: ETHERSCAN_API_KEY, PLUME_API_KEY and ALCHEMY_API_KEY in .env

ACCOUNT=$1
NETWORK=$2
SPELL_DEPLOYER="0x8D566ADACe57ee5DD2BF98953B804991D634211A"
SPELL_EXECUTOR="0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16" #OPS_ADMIN

ETHERSCAN_API_KEY=$(grep -E '^ETHERSCAN_API_KEY=' .env | cut -d= -f2-)

if [ "$NETWORK" == "plume" ]; then
    PLUME_API_KEY=$(grep -E '^PLUME_API_KEY=' .env | cut -d= -f2-)
    REMOTE_RPC_URL="https://rpc.plume.org/$PLUME_API_KEY"
else
    ALCHEMY_API_KEY=$(grep -E '^ALCHEMY_API_KEY=' .env | cut -d= -f2-)
    ALCHEMY_NAME=$(jq -r --arg net "$NETWORK" '.mainnet[$net] // empty' script/deploy/config/alchemy_networks.json)
    REMOTE_RPC_URL="https://$ALCHEMY_NAME.g.alchemy.com/v2/$ALCHEMY_API_KEY"
fi

forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1Deployer \
    --sig "run(address)" $SPELL_EXECUTOR \
    --optimize \
    --rpc-url "$REMOTE_RPC_URL" \
    --unlocked \
    --account "$ACCOUNT" \
    --sender "$SPELL_DEPLOYER" \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --broadcast

CHAIN_ID=$(cast chain-id --rpc-url "$REMOTE_RPC_URL")

echo "MigrationSpell address: $(jq -r '.transactions[].additionalContracts[] | select(.contractName=="MigrationSpell") | .address' \
    broadcast/MigrationV3_1.s.sol/"$CHAIN_ID"/run-latest.json)"
