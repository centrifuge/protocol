#!/bin/bash

# Check if anvil is already running
if pgrep anvil >/dev/null; then
    read -p "Anvil is already running. Do you want to restart it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pkill anvil
        sleep 1
    else
        echo "Using existing Anvil instance"
    fi
else
    # Start anvil with minimal parameters
    anvil --chain-id 1982 >anvil.log 2>&1 &
    sleep 3
fi

# Etch CreateX code to the expected address
echo "Etching CreateX code..."
CREATE3_ADDRESS="0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"
CREATE3_BYTECODE=$(sed -n 's/.*hex"\([0-9a-fA-F]*\)".*/\1/p' lib/createx-forge/script/CreateX.d.sol)

cast rpc anvil_setCode $CREATE3_ADDRESS 0x"$CREATE3_BYTECODE"

# Verify CreateX deployment
if cast keccak $(cast code $CREATE3_ADDRESS) | grep -q "0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f"; then
    echo "Welcome Mr. Anderson. (CREATE3 deployed, hash: $CREATE3_ADDRESS)"
else
    echo "Error: CreateX deployment failed"
    exit 1
fi

# Run the deployment script
# 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 is Anvil's first account
echo "Running main deployment..."
NETWORK="anvil" ADMIN="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" forge script script/FullDeployer.s.sol:FullDeployer --rpc-url http://localhost:8545 --broadcast --verify -vvvv --via-ir
