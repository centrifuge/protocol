// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";

// TODO(@wischli): Docs
interface IInvestmentManagerMapper {
    // Admin function to add a new investment manager
    function addInvestmentManager(IBaseInvestmentManager newManager) external;

    // Admin function to remove an investment manager by index
    function removeInvestmentManager(uint256 index) external;

    // Maps a triplet of vault keys to its corresponding investment manager
    function vaultKeysToInvestmentManager(uint64 poolId, bytes16 trancheId, uint128 assetId)
        external
        view
        returns (IBaseInvestmentManager);
}
