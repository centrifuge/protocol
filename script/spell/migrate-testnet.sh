#!/bin/bash
set -euo pipefail

# Example of different runs:
# ./script/spell/migrate-testnet.sh fork eth-sepolia sepolia
# ./script/spell/migrate-testnet.sh fork base-sepolia base-sepolia
# ./script/spell/migrate-testnet.sh fork arb-sepolia arbitrum-sepolia
#
# ./script/spell/migrate-testnet.sh deploy eth-sepolia sepolia
# ./script/spell/migrate-testnet.sh deploy base-sepolia base-sepolia
# ./script/spell/migrate-testnet.sh deploy arb-sepolia arbitrum-sepolia
#
# ./script/spell/migrate-testnet.sh execute eth-sepolia sepolia
# ./script/spell/migrate-testnet.sh execute base-sepolia base-sepolia
# ./script/spell/migrate-testnet.sh execute arb-sepolia arbitrum-sepolia

# Only PRIVATE_KEY and ALCHEMY_API_KEY are used from .env file
set -a; source .env; set +a # auto-export all sourced vars

MODE=$1
ALCHEMY_NAME=$2
export NETWORK=$3
REMOTE_RPC_URL="https://$ALCHEMY_NAME.g.alchemy.com/v2/$ALCHEMY_API_KEY"
GUARDIAN_V3="0xa5ac766b22d9966c3e64cc44923a48cb8b052eda"
POOLS_TO_MIGRATE="[281474976710662,281474976710668]"
ADMIN="0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb" # The account of PRIVATE_KEY
PRE_VALIDATION=true
POST_VALIDATION=false

deploy() {
    RPC_URL=$1

    echo ""
    echo "##########################################################################"
    echo "#                          STEP 1: Deploy V3.1"
    echo "##########################################################################"
    echo ""

    export VERSION="v3.1"
    export ROOT=$(cast call $GUARDIAN_V3 "root()(address)" --rpc-url "$RPC_URL")
    export PROTOCOL_ADMIN=$ADMIN
    export OPS_ADMIN=$ADMIN
    forge script script/LaunchDeployer.s.sol \
        --optimize \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast

    VERSION="v3.1" ./script/deploy/update_network_config.py "$NETWORK" --script script/LaunchDeployer.s.sol

    echo ""
    echo "##########################################################################"
    echo "#                    STEP 2: Deploy migration spell"
    echo "##########################################################################"
    echo ""

    forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1Deployer \
        --sig "run(address)" $ADMIN \
        --optimize \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast

    CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
    MIGRATION_SPELL=$(jq -r '.transactions[] | select(.contractName=="MigrationSpell") | .contractAddress' \
        broadcast/MigrationV3_1.s.sol/"$CHAIN_ID"/run-latest.json)

    echo ""
    echo "##########################################################################"
    echo "#              STEP 3: Request root permissions to the spell"
    echo "##########################################################################"
    echo ""

    cast send $GUARDIAN_V3 "scheduleRely(address)" "$MIGRATION_SPELL" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY"
}

execute() {
    RPC_URL=$1

    echo ""
    echo "##########################################################################"
    echo "#              STEP 4: Get root permissions to the spell"
    echo "##########################################################################"
    echo ""

    cast send "$ROOT" "executeScheduledRely(address)" "$MIGRATION_SPELL" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY"

    echo ""
    echo "##########################################################################"
    echo "#                        STEP 5: Block protocol"
    echo "##########################################################################"
    echo ""

    cast send $GUARDIAN_V3 "pause()" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY"

    echo ""
    echo "##########################################################################"
    echo "#                    STEP 6: Run pre-validations"
    echo "##########################################################################"
    echo ""

    forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
        --rpc-url "$RPC_URL" \
        --sig "validate(string,string,address,uint64[],bool)" \
        "$NETWORK" \
        "$RPC_URL" \
        $ADMIN \
        "$POOLS_TO_MIGRATE" \
        $PRE_VALIDATION

    echo ""
    echo "##########################################################################"
    echo "#                       STEP 7: Run migration"
    echo "##########################################################################"
    echo ""

    forge script script/spell/MigrationV3_1.s.sol:MigrationV3_1ExecutorTestnet \
        --sig "run(address, uint64[])" "$MIGRATION_SPELL" "$POOLS_TO_MIGRATE" \
        --optimize \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast

    echo ""
    echo "##########################################################################"
    echo "#                    STEP 8: Run post-validations"
    echo "##########################################################################"
    echo ""

    forge script test/spell/migration/ValidationRunner.sol:ValidationRunner \
        --rpc-url "$RPC_URL" \
        --sig "validate(string,string,address,uint64[],bool)" \
        "$NETWORK" \
        "$RPC_URL" \
        $ADMIN \
        "$POOLS_TO_MIGRATE" \
        $POST_VALIDATION

    echo ""
    echo "##########################################################################"
    echo "#                       STEP 9: Unpause protocol"
    echo "##########################################################################"
    echo ""

    cast send $GUARDIAN_V3 "unpause()" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY"

}

case "$MODE" in
    fork)
        echo "Starting Anvil in fork mode..."

        anvil --fork-url "$REMOTE_RPC_URL" &
        ANVIL_PID=$!
        trap "kill $ANVIL_PID" EXIT

        LOCAL_RPC_URL="http://127.0.0.1:8545" #anvil
        sleep 3.0 # Wait ensuring Anvil is up

        deploy $LOCAL_RPC_URL

        # As a mocked process to skip 48 hours of delay
        cast rpc evm_increaseTime 172800 \
            --rpc-url $LOCAL_RPC_URL \

        # Mine a new block to set the new timestamp
        cast rpc evm_mine \
            --rpc-url $LOCAL_RPC_URL

        execute $LOCAL_RPC_URL
        ;;
    deploy)
        read -p "You're not in a fork. Are you sure you want to continue? [y/N] " confirm
        if [[ $confirm != [yY] ]]; then
          echo "Aborted."
          exit 1
        fi

        echo "Deploy..."
        deploy "$REMOTE_RPC_URL"
        ;;
    execute)
        read -p "You're not in a fork. Are you sure you want to continue? [y/N] " confirm
        if [[ $confirm != [yY] ]]; then
          echo "Aborted."
          exit 1
        fi

        echo "Execute..."
        execute "$REMOTE_RPC_URL"
        ;;
    *)
        echo "Usage: $0 {fork|deploy|execute}"
        exit 1
        ;;
esac
