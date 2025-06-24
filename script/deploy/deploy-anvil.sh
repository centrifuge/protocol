#!/bin/bash

# Check if anvil is already running
if pgrep anvil >/dev/null; then
    read -p "Anvil is already running. Do you want to restart it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pkill anvil
        anvil --chain-id 31337 >anvil.log 2>&1 &
        sleep 5
    else
        echo "Using existing Anvil instance"
    fi
else
    # Start anvil with default chain ID 31337 (CreateXScript expects this)
    anvil --chain-id 31337 >anvil.log 2>&1 &
    sleep 3
fi

# Run the deployment script
# CreateXScript automatically handles CreateX deployment
echo "Running main deployment..."
NETWORK="anvil" ADMIN="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" forge script script/FullDeployer.s.sol:FullDeployer --rpc-url http://localhost:8545 --broadcast --skip-simulation -vvvv --via-ir

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
