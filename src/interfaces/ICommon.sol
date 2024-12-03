// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// NOTE: this is a pending interface until we split this into files

import {Auth} from "src/Auth.sol";
import {ChainId, ShareClassId, AssetId, Ratio, ItemId, AccountId} from "src/types/Domain.sol";
import {D18} from "src/types/D18.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";
import {PoolId} from "src/types/PoolId.sol";

interface IShareClassManager {
    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;
    function requestRedemption(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;

    function approveDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, Ratio approvalRatio, IERC7726 valuation)
        external
        returns (uint128 totalApproved);
    function approveRedemption(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        Ratio approvalRatio,
        IERC7726 valuation
    ) external returns (uint128 totalApproved);

    function issueShares(PoolId poolId, ShareClassId scId, uint128 nav) external;
    function revokeShares(PoolId poolId, ShareClassId scId, uint128 nav) external;

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, address investor)
        external
        returns (uint128 shares, uint128 tokens);
    function claimTokens(PoolId poolId, ShareClassId scId, AssetId assetId, address investor)
        external
        returns (uint128 shares, uint128 tokens);
}

interface IAssetManager is IERC6909 {
    function mint(address who, AssetId assetId, uint128 amount) external;
    function burn(address who, AssetId assetId, uint128 amount) external;
}

interface IAccounting {
    function updateEntry(AccountId credit, AccountId debit, uint128 value) external;
    function lock(PoolId poolId) external;
}

interface IGateway {
    function sendAllowPool(ChainId chainId, PoolId poolId) external;
    function sendAllowShareClass(ChainId chainId, PoolId poolId, ShareClassId scId) external;
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address investor,
        uint128 shares,
        uint128 investedAmount
    ) external;
    function sendFulfilledRedemptionRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address investor,
        uint128 shares,
        uint128 investedAmount
    ) external;
    function sendUnlockTokens(ChainId chainId, AssetId assetId, address receiver, uint128 poolAmount) external;
}
