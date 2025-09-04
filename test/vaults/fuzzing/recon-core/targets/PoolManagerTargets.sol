// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

import {Properties} from "../properties/Properties.sol";

// Only for Share
abstract contract PoolManagerTargets is BaseTargetFunctions, Properties {
// TODO: Live comparison of TotalSupply of share class token
// With our current storage value

// NOTE: These introduce many false positives because they're used for cross-chain transfers but we our test environment
// only allows tracking state on one chain so they were removed
// TODO: Overflow stuff
// function spoke_handleTransferShares(uint128 amount, uint256 investorEntropy) public updateGhosts asActor {
//     address investor = _getRandomActor(investorEntropy);
//     spoke.handleTransferShares(poolId, scId, investor, amount);

//     // TF-12 mint share class tokens to user, not tracked in escrow

//     // Track minting for Global-3
//     incomingTransfers[address(token)] += amount;
// }

// function spoke_transferSharesToEVM(uint16 destinationChainId, bytes32 destinationAddress, uint128 amount)
//     public
// updateGhosts asActor {
//     uint256 balB4 = token.balanceOf(_getActor());

//     // Clamp
//     if (amount > balB4) {
//         amount %= uint128(balB4);
//     }

//     // Exact approval
//     token.approve(address(spoke), amount);

//     spoke.transferShares(destinationChainId, poolId, scId, destinationAddress, amount);
//     // TF-11 burns share class tokens from user, not tracked in escrow

//     // Track minting for Global-3
//     outGoingTransfers[address(token)] += amount;

//     uint256 balAfterActor = token.balanceOf(_getActor());

//     t(balAfterActor <= balB4, "PM-3-A");
//     t(balB4 - balAfterActor == amount, "PM-3-A");
// }
}
