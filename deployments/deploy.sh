#!/bin/bash

# Basic usage: ./development/deploy.sh <Localhost|Axelar|Wormhole> $2
#
# Expect a .env file with at least the following:
#
# PRIVATE_KEY=
# ETHERSCAN_KEY=
# ETHERSCAN_URL=
# RPC_URL=
# CHAIN_ID=
# CENTRIFUGE_ID=
# ADMIN=

source .env

ADAPTER=$1

if [[ -z "$1" ]]; then
    echo "ADAPTER is not defined"
    exit 1
fi

mkdir -p deployments/latest

forge clean

case "$ADAPTER" in
    Localhost|Axelar|Wormhole)
        forge script script/adapters/${ADAPTER}.s.sol:${ADAPTER}Deployer --optimize --rpc-url $RPC_URL --private-key $PRIVATE_KEY --verify --broadcast --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY $2
        ;;
    *)
        echo "Adapter '$ADAPTER' was chosen"
        echo "Adapter (first argument) should be one of Localhost, Axelar, Wormhole"
        exit 1
    ;;
esac

