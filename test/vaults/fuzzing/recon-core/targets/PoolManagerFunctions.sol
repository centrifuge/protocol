// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

// Only for Share
abstract contract PoolManagerFunctions is BaseTargetFunctions, Properties {
    // TODO: Live comparison of TotalSupply of share class token
    // With our current storage value

    // TODO: Clamp / Target specifics
    // TODO: Actors / Randomness
    // TODO: Overflow stuff
    function poolManager_handleTransferShares(uint128 amount) public {
        poolManager.handleTransferShares(poolId, scId, actor, amount);
        // TF-12 mint share class tokens from user, not tracked in escrow

        // Track minting for Global-3
        incomingTransfers[address(token)] += amount;
    }

    function poolManager_transferSharesToEVM(uint16 destinationChainId, bytes32 destinationAddress, uint128 amount)
        public
    {
        uint256 balB4 = token.balanceOf(actor);

        // Clamp
        if (amount > balB4) {
            amount %= uint128(balB4);
        }

        // Exact approval
        token.approve(address(poolManager), amount);

        poolManager.transferShares(destinationChainId, poolId, scId, destinationAddress, amount);
        // TF-11 burns share class tokens from user, not tracked in escrow

        // Track minting for Global-3
        outGoingTransfers[address(token)] += amount;

        uint256 balAfterActor = token.balanceOf(actor);

        t(balAfterActor <= balB4, "PM-3-A");
        t(balB4 - balAfterActor == amount, "PM-3-A");
    }
}
