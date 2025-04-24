// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IVaultMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IBalanceSheetGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {ISharePriceProvider, Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

contract BalanceSheet is Auth, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler, IUpdateContract {
    using MathLib for *;
    using CastLib for bytes32;

    IGateway public gateway;
    IPoolManager public poolManager;
    IVaultMessageSender public sender;
    ISharePriceProvider public sharePriceProvider;
    IPoolEscrowProvider public poolEscrowProvider;

    mapping(PoolId => mapping(ShareClassId => mapping(address => bool))) public manager;

    constructor(address deployer) Auth(deployer) {}

    /// @dev Check if the msg.sender has managers
    modifier authOrManager(PoolId poolId, ShareClassId scId) {
        require(wards[msg.sender] == 1 || manager[poolId][scId][msg.sender], IAuth.NotAuthorized());
        _;
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "sharePriceProvider") sharePriceProvider = ISharePriceProvider(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// --- IUpdateContract Implementation ---
    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateManager)) {
            MessageLib.UpdateContractUpdateManager memory m = MessageLib.deserializeUpdateContractUpdateManager(payload);

            address who = m.who.toAddress();

            manager[poolId][scId][who] = m.canManage;

            emit UpdateManager(poolId, scId, who, m.canManage);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// --- External ---
    /// @inheritdoc IBalanceSheet
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset);
        _executeDeposit(poolId, asset, tokenId, provider, amount);
    }

    /// @inheritdoc IBalanceSheet
    /// @dev This function is mostly useful to keep higher level integrations CEI adherent.
    function noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset);
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePoolPerAsset);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _noteRevoke(poolId, scId, from, pricePoolPerShare, shares);
        _executeRevoke(poolId, scId, from, shares);
    }

    /// @inheritdoc IBalanceSheet
    /// @dev This function is mostly useful to keep higher level integrations CEI adherent.
    function noteRevoke(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _noteRevoke(poolId, scId, from, pricePoolPerShare, shares);
    }

    /// --- IBalanceSheetHandler ---
    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset);
        _executeDeposit(poolId, asset, tokenId, provider, amount);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerWithdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePoolPerAsset);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares)
        external
        auth
    {
        _issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        external
        auth
    {
        _noteRevoke(poolId, scId, from, pricePoolPerShare, shares);
        _executeRevoke(poolId, scId, from, shares);
    }

    // --- Internal ---
    function _issue(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares) internal {
        emit Issue(poolId, scId, to, pricePoolPerShare, shares);
        sender.sendUpdateShares(poolId, scId, to, pricePoolPerShare, shares, true);
        IShareToken token = poolManager.shareToken(poolId, scId);
        token.mint(to, shares);
    }

    function _noteRevoke(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        internal
    {
        emit Revoke(poolId, scId, from, pricePoolPerShare, shares);
        sender.sendUpdateShares(poolId, scId, from, pricePoolPerShare, shares, false);
    }

    function _executeRevoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) internal {
        IShareToken token = poolManager.shareToken(poolId, scId);
        token.burn(from, shares);
    }

    function _noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) internal {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.deposit(scId, asset, tokenId, amount);
        emit Deposit(poolId, scId, asset, tokenId, provider, amount, pricePoolPerAsset);
        sender.sendUpdateHoldingAmount(poolId, scId, assetId, provider, amount, pricePoolPerAsset, true);
    }

    function _executeDeposit(PoolId poolId, address asset, uint256 tokenId, address provider, uint128 amount)
        internal
    {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
        }
    }

    function _withdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    ) internal {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.withdraw(scId, asset, tokenId, amount);
        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePoolPerAsset);
        sender.sendUpdateHoldingAmount(poolId, scId, assetId, receiver, amount, pricePoolPerAsset, false);
        // TODO: More specific error would be great here
        escrow.authTransferTo(asset, tokenId, receiver, amount);
    }
}
