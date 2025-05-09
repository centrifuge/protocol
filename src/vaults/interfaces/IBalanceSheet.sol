// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18, d18} from "src/misc/types/D18.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

struct QueueAmount {
    // Issuances of shares / deposits of assets
    uint128 increase;
    // Revocations of shares / withdraws of assets
    uint128 decrease;
}

interface IBalanceSheet {
    // --- Events ---
    event File(bytes32 indexed what, address data);
    event UpdateManager(PoolId indexed poolId, address who, bool canManage);
    event Withdraw(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    );
    event Deposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    );
    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address to, D18 pricePoolPerShare, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address from, D18 pricePoolPerShare, uint128 shares);

    // --- Errors ---
    error FileUnrecognizedParam();
    error CannotTransferFromEndorsedContract();

    function root() external view returns (IRoot);
    function poolManager() external view returns (IPoolManager);
    function sender() external view returns (IVaultMessageSender);
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    function manager(PoolId poolId, address manager) external view returns (bool);
    function queueEnabled(PoolId poolId, ShareClassId scId) external view returns (bool);
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 increase, uint128 decrease);
    function queuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 increase, uint128 decrease);

    function file(bytes32 what, address data) external;

    /// @notice Overloaded increase with asset transfer
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external;

    function noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount
    ) external;

    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external;

    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external;

    function revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) external;

    function noteRevoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) external;

    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount) external;

    function overridePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 value) external;

    function overridePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 value) external;

    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        external
        view
        returns (uint128);
}
