#!/bin/bash

source .env

display_help() {
    echo
    echo "This script verifies the vault contract and its associated share class and restriction manager contracts."
    echo
    echo "Usage: $0 contract_address"
    echo
    echo "Arguments:"
    echo "  contract_address      The address of the vault to verify"
    echo
    echo "Required Environment Variables:"
    echo "  RPC_URL               The RPC URL"
    echo "  ETHERSCAN_KEY         The Etherscan API key"
    echo "  ETHERSCAN_URL          The verifier URL"
    echo "  CHAIN_ID              The chain ID"
    echo
    exit 0
}

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    display_help
fi

if [ -z "$RPC_URL" ] || [ -z "$ETHERSCAN_KEY" ] || [ -z "$ETHERSCAN_URL" ] || [ -z "$CHAIN_ID" ]; then
    echo "Error: RPC_URL, ETHERSCAN_KEY, ETHERSCAN_URL, and CHAIN_ID must be set in the .env file."
    exit 1
fi

contract_address=$1

echo "vault: $contract_address"
if ! cast call $contract_address 'share()(address)' --rpc-url $RPC_URL &> /dev/null; then
    echo "Error: Must pass a vault address."
    exit 1
fi
poolId=$(cast call $contract_address 'poolId()(uint64)' --rpc-url $RPC_URL | awk '{print $1}')
scId=$(cast call $contract_address 'trancheId()(bytes16)' --rpc-url $RPC_URL | cut -c 1-34)
asset=$(cast call $contract_address 'asset()(address)' --rpc-url $RPC_URL)
share=$(cast call $contract_address 'share()(address)' --rpc-url $RPC_URL)
root=$(cast call $contract_address 'root()(address)' --rpc-url $RPC_URL)
asyncRedeemManager=$(cast call $contract_address 'asyncRedeemManager()(address)' --rpc-url $RPC_URL)
syncDepositManager=$(cast call $contract_address 'syncDepositManager()(address)' --rpc-url $RPC_URL)
spoke=$(cast call $asyncRequestManager 'spoke()(address)' --rpc-url $RPC_URL)
decimals=$(cast call $share 'decimals()(uint8)' --rpc-url $RPC_URL)
echo "poolId: $poolId"
echo "shareClassId: $scId"
echo "asset: $asset"
echo "share: $share"
echo "root: $root"
echo "asyncRedeemManager: $asyncRedeemManager"
echo "syncDepositManager: $syncDepositManager"
echo "spoke: $spoke"
echo "token decimals: $decimals"
forge verify-contract --constructor-args $(cast abi-encode "constructor(uint8)" $decimals) --watch --etherscan-api-key $ETHERSCAN_KEY $share src/spoke/ShareToken.sol:CentrifugeToken --verifier-url $ETHERSCAN_URL --chain $CHAIN_ID

# forge verify-contract --constructor-args $(cast abi-encode "constructor(uint64,bytes16,address,uint256,address,address,address)" $poolId $scId $asset 0 $share $root $asyncRedeemManager) --watch --etherscan-api-key $ETHERSCAN_KEY $contract_address src/spoke/ERC7540Vault.sol:ERC7540Vault --verifier-url $ETHERSCAN_URL --chain $CHAIN_ID
forge verify-contract --constructor-args $(cast abi-encode "constructor(uint64,bytes16,address,uint256,address,address,address,address)" $poolId $scId $asset 0 $share $root $syncDepositManager $asyncRedeemManager) --watch --etherscan-api-key $ETHERSCAN_KEY $contract_address src/spoke/vaults/SyncDepositVault.sol:SyncDepositVault --verifier-url $ETHERSCAN_URL --chain $CHAIN_ID
