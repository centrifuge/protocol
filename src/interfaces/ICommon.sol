// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {ChainId, PoolId, ShareClassId, AssetId, Ratio} from "src/types/Domain.sol";
import {D18} from "src/types/D18.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for data feeds providing the relative value of assets.
interface IERC7726 {
    /// @notice Returns the value of `baseAmount` of `base` in quote `terms`.
    /// It's rounded towards 0 and reverts if overflow
    /// @param base The asset that the user needs to know the value for
    /// @param quote The asset in which the user needs to value the base
    /// @param baseAmount An amount of base in quote terms
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

interface IShareClassManager {
    function requestDeposit(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address investor, uint128 amount)
        external;
    function approveDepositRequests(
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        Ratio approvalRatio,
        IERC7726 valuation
    ) external returns (uint128 totalApproved);
    function issueShares(PoolId poolId, ShareClassId shareClassId, uint128 nav, uint64 epochIndex) external;
    function claimShares(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address investor) external;
}

interface IPoolRegistry {
    // Can also be called "isFundManager" or be extracted in a Permissions contract
    // NOTE: The gateway contract is able to unlock any poolId
    function isUnlocker(address who, PoolId poolId) external view returns (bool);

    // Associate who to be the owner/poolAdmin of the new poolId
    function registerPool(address who) external returns (PoolId);

    function shareClassManager(PoolId poolId) external view returns (IShareClassManager);
}

interface IAssetManager is IERC6909 {
    function mint(address who, AssetId assetId, uint128 amount) external;
}

interface IAccounting {
    function unlock(PoolId poolId) external;
    function lock(PoolId poolId) external;
}

interface IHoldings {
    function updateHoldings() external;
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external returns (IERC7726);

    function pendingPoolEscrow(PoolId poolId, ShareClassId scId) external view returns (address);
    function poolEscrow(PoolId poolId, ShareClassId scId) external view returns (address);
}

interface IGateway {
    function sendAllowPool(ChainId chainId, PoolId poolId) external;
    function sendAllowShareClass(ChainId chainId, PoolId poolId, ShareClassId scId) external;
}
