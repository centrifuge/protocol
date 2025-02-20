// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {Domain} from "src/vaults/interfaces/IPoolManager.sol";

// Only for Tranche
abstract contract PoolManagerFunctions is BaseTargetFunctions, Properties {
    // TODO: Add currencies e.g. function poolManager_transfer(address currency, bytes32 recipient, uint128 amount)
    // public {
    function poolManager_transfer(bytes32 recipient, uint128 amount) public {
        // Currency
        token.approve(address(poolManager), amount);

        bool hasReverted;
        uint256 balB4Actor = token.balanceOf(actor);
        uint256 balB4Escrow = token.balanceOf(address(escrow));
        try poolManager.transferAssets(address(token), recipient, amount) {
            sumOfTransfersIn[address(token)] += amount;
        } catch {
            hasReverted = true;
        }

        if (!hasReverted) {
            uint256 balAfterActor = token.balanceOf(actor);
            uint256 balAfterEscrow = token.balanceOf(address(escrow));

            t(balAfterActor <= balB4Actor, "Actor has spent Currnecy");
            t(balAfterEscrow >= balB4Escrow, "Escrow has received Currnecy");
            // Check for delta balances
            t((balB4Actor - balAfterActor) == (balAfterEscrow - balB4Escrow), "PM-1 & PM-2");
        }
    }

    uint128 absoluteTokensToTransfer;

    // //// TODO: DECIDE HOW TO KEEP THESE
    function poolManager_handleTransfer(bytes32 recipient, uint128 amount) public {
        token.approve(address(poolManager), amount);
        poolManager.transferAssets(address(token), recipient, amount);
        sumOfTransfersIn[address(token)] += amount;

        /// === CLAMP === ///
        absoluteTokensToTransfer += amount;
    }

    function poolManager_handleTransfer(address recipient, uint128 amount) public {
        /// === CLAMP === ///
        // Avoids donations to system address
        require(!_isInSystemAddress(recipient));
        require(_canDonate(recipient)); // Prevent donation to escrow for E_1

        /// === CLAMP === ///
        amount %= absoluteTokensToTransfer + 1;
        absoluteTokensToTransfer -= amount;

        poolManager.handleTransfer(currencyId, recipient, amount);

        // E-1
        sumOfTransfersOut[address(token)] += amount;
    }

    function poolManager_handleTransfer(uint128 amount) public {
        /// === CLAMP === ///
        amount %= absoluteTokensToTransfer + 1;
        absoluteTokensToTransfer -= amount;

        poolManager.handleTransfer(currencyId, actor, amount);
        sumOfTransfersOut[address(token)] += amount;
    }

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
        uint64 destinationChainId,
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

        poolManager.transferTrancheTokens(poolId, trancheId, Domain.EVM, destinationChainId, destinationAddress, amount);
        // TF-11 burns tranche tokens from user, not tracked in escrow

        // Track minting for Global-3
        outGoingTransfers[address(trancheToken)] += amount;

        uint256 balAfterActor = trancheToken.balanceOf(actor);

        t(balAfterActor <= balB4, "PM-3-A");
        t(balB4 - balAfterActor == amount, "PM-3-A");
    }
}
