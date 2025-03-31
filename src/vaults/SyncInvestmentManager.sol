// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {d18, D18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IAsyncRedeemManager, AsyncRedeemState} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {SyncDepositAsyncRedeemVault} from "src/vaults/SyncDepositAsyncRedeemVault.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncInvestmentManager is BaseInvestmentManager, ISyncInvestmentManager {
    using BytesLib for bytes;
    using MathLib for *;
    using CastLib for *;
    using MessageLib for *;

    IBalanceSheetManager public balanceSheetManager;

    mapping(address vaultAddr => uint64) public maxPriceAge;
    // TODO(follow-up PR): Support multiple vaults
    mapping(uint64 poolId => mapping(bytes16 trancheId => mapping(uint128 assetId => address vault))) public vault;

    constructor(address root_, address escrow_) BaseInvestmentManager(root_, escrow_) {}

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheetManager") balanceSheetManager = IBalanceSheetManager(data);
        else revert("SyncInvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncInvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] == address(0), "SyncInvestmentManager/vault-already-exists");

        vault[poolId][trancheId][assetId] = vaultAddr;

        IAuth(token).rely(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncInvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] != address(0), "SyncInvestmentManager/vault-does-not-exist");

        delete vault[poolId][trancheId][assetId];

        IAuth(token).deny(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    // --- IDepositManager ---
    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = previewMint(vaultAddr, owner, shares);

        _issueShares(vaultAddr, receiver, shares.toUint128());
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        _issueShares(vaultAddr, receiver, shares.toUint128());
    }

    /// @inheritdoc IDepositManager
    function maxMint(address, /* vaultAddr */ address /* owner */ ) public pure returns (uint256) {
        // TODO(follow-up PR): implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(address, /* vaultAddr */ address /* owner */ ) public pure returns (uint256) {
        // TODO(follow-up PR): implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);
        uint128 assetId = poolManager.vaultDetails(vaultAddr).assetId;

        uint128 latestPrice = _pricePerShare(vaultAddr, vault_.poolId(), vault_.trancheId(), assetId);
        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);
        uint128 assetId = poolManager.vaultDetails(vaultAddr).assetId;

        uint128 latestPrice = _pricePerShare(vaultAddr, vault_.poolId(), vault_.trancheId(), assetId);
        shares = PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IVaultManager
    function vaultByAssetId(uint64 poolId, bytes16 trancheId, uint128 assetId) public view returns (address) {
        return vault[poolId][trancheId][assetId];
    }

    /// --- IUpdateContract ---
    function update(uint64, bytes16, bytes calldata payload) external auth {
        MessageLib.UpdateContractMaxPriceAge memory m = MessageLib.deserializeUpdateContractMaxPriceAge(payload);

        address vaultAddr = address(bytes20(m.vault));
        maxPriceAge[vaultAddr] = m.maxPriceAge;

        emit MaxPriceAgeUpdate(vaultAddr, m.maxPriceAge);
    }

    /// --- IERC165 ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseInvestmentManager, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IVaultManager).interfaceId
            || interfaceId == type(IDepositManager).interfaceId || interfaceId == type(ISyncDepositManager).interfaceId
            || interfaceId == type(ISyncInvestmentManager).interfaceId;
    }

    /// @dev Retrieve the latest price for the share class token
    function _pricePerShare(address vaultAddr, uint64 poolId, bytes16 trancheId, uint128 assetId)
        internal
        view
        returns (uint128 latestPrice)
    {
        (uint128 price, uint64 computedAt) = poolManager.tranchePrice(poolId, trancheId, assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());
        return price;
    }

    /// @dev Issues shares to the receiver and instruct the Balance Sheet Manager to react on the issuance and the
    /// updated holding value
    function _issueShares(address vaultAddr, address receiver, uint128 shares) internal {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);

        uint64 poolId_ = vault_.poolId();
        bytes16 scId_ = vault_.trancheId();
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        D18 pricePerShare = d18(_pricePerShare(vaultAddr, poolId_, scId_, vaultDetails.assetId));

        PoolId poolId = PoolId.wrap(poolId_);
        ShareClassId scId = ShareClassId.wrap(scId_);

        // Mint shares for receiver notify CP about issued shares
        balanceSheetManager.issue(poolId, scId, receiver, pricePerShare, shares.toUint128(), false);

        // Notify CP about updated holding value
        balanceSheetManager.updateValue(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, pricePerShare);
    }
}
