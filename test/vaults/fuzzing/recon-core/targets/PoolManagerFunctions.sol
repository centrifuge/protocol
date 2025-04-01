// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

// Only for Tranche
abstract contract PoolManagerFunctions is BaseTargetFunctions, Properties {
    // TODO: Live comparison of TotalSupply of tranche token
    // With our current storage value

    // TODO: Clamp / Target specifics
    // TODO: Actors / Randomness
    // TODO: Overflow stuff
    function poolManager_handleTransferTrancheTokens(uint128 amount) public {
        poolManager.handleTransferTrancheTokens(poolId, trancheId, actor, amount);
        // TF-12 mint tranche tokens from user, not tracked in escrow

        // Track minting for Global-3
        incomingTransfers[address(trancheToken)] += amount;
    }

    function poolManager_transferTrancheTokensToEVM(
        uint16 destinationChainId,
        bytes32 destinationAddress,
        uint128 amount
    ) public {
        uint256 balB4 = trancheToken.balanceOf(actor);

        // Clamp
        if (amount > balB4) {
            amount %= uint128(balB4);
        }

        // Exact approval
        trancheToken.approve(address(poolManager), amount);

        poolManager.transferTrancheTokens(poolId, trancheId, destinationChainId, destinationAddress, amount);
        // TF-11 burns tranche tokens from user, not tracked in escrow

        // Track minting for Global-3
        outGoingTransfers[address(trancheToken)] += amount;

        uint256 balAfterActor = trancheToken.balanceOf(actor);

        t(balAfterActor <= balB4, "PM-3-A");
        t(balB4 - balAfterActor == amount, "PM-3-A");
    }
}
