// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IRedeemGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IAsyncRedeemManager, AsyncRedeemState} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {SyncDepositAsyncRedeemVault} from "src/vaults/SyncDepositAsyncRedeemVault.sol";
import {AsyncRedeemVault} from "src/vaults/BaseVaults.sol";
import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";

// TODO(@wischli) implement IUpdateContract for max price age
/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncInvestmentManager is BaseInvestmentManager, ISyncInvestmentManager {
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    IGateway public gateway;
    IVaultMessageSender public sender;

    mapping(address vaultAddr => uint64) public maxPriceAge;

    constructor(address root_, address escrow_) BaseInvestmentManager(root_, escrow_) {}

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("SyncInvestmentManager/file-unrecognized-param");
        emit IBaseInvestmentManager.File(what, data);
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

        // TODO(@wischli): Also execute for asyncManager

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

        // TODO(@wischli): Also execute for asyncManager

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

        ITranche tranche = ITranche(SyncDepositAsyncRedeemVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        ITranche tranche = ITranche(SyncDepositAsyncRedeemVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        SyncDepositAsyncRedeemVault vault_ = SyncDepositAsyncRedeemVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        shares = PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseInvestmentManager, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IVaultManager).interfaceId
            || interfaceId == type(IDepositManager).interfaceId || interfaceId == type(ISyncDepositManager).interfaceId
            || interfaceId == type(ISyncInvestmentManager).interfaceId || interfaceId == type(IMessageHandler).interfaceId;
    }

    // --- Admin actions ---
    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }
}
