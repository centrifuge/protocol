#!/bin/bash

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if anvil is already running
source "$SCRIPT_DIR/load_vars.sh" sepolia
if pgrep anvil >/dev/null; then
    read -p "Anvil is already running. Do you want to restart it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pkill anvil
        anvil --chain-id 31337 --gas-limit 50000000 --code-size-limit 50000 --fork-url "$RPC_URL" >anvil.log 2>&1 &
        sleep 2
    else
        echo "Using existing Anvil instance"
    fi
else
    # Start anvil with higher gas and code size limits for large contract deployments
    anvil --chain-id 31337 --gas-limit 50000000 --code-size-limit 50000 --fork-url "$RPC_URL" >anvil.log 2>&1 &
    sleep 3
fi

# Run the deployment script
# CreateXScript automatically handles CreateX deployment
echo "Running main deployment..."
# forge clean
# 2nd Anvil account: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
# 1st account Private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Generate a unique version based on timestamp to avoid CREATE3 collisions
VERSION_TIMESTAMP=$(date +%s)
echo "Using VERSION: $VERSION_TIMESTAMP"

NETWORK="anvil" ADMIN="0x70997970C51812dc3A010C7d01b50e0d17dc79C8" VERSION="0x$(printf '%064x' "$VERSION_TIMESTAMP")" \
    forge script script/FullDeployer.s.sol:FullDeployer \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast --skip-simulation -vvvv

echo ""
echo "----------------------------------------"
echo "Verifying contract deployment on Anvil..."
echo "----------------------------------------"

# Extract the Root contract address from the JSON output.
# We use grep and sed to avoid requiring jq.
ROOT_ADDRESS=$(grep '"root":' ./env/latest/31337-latest.json | sed 's/.*"root": "\(.*\)",/\1/')

if [ -z "$ROOT_ADDRESS" ] || [ "$ROOT_ADDRESS" == "null" ]; then
    echo "❌ Could not find Root address in deployment output file."
    exit 1
fi

echo "Checking for code at Root address: $ROOT_ADDRESS"
ROOT_CODE=$(cast code --rpc-url http://localhost:8545 "$ROOT_ADDRESS")

# Check if the returned code is not empty ('0x')
if [ "$ROOT_CODE" != "0x" ]; then
    echo "✅ Success: Found contract code at the Root address on the live Anvil instance."
else
    echo "❌ Failure: No contract code found at the Root address. The broadcast may have failed."
fi
