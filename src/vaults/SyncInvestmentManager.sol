// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";

import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/ISyncInvestmentManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncInvestmentManager is Auth, ISyncInvestmentManager {
    using MathLib for uint256;

    address public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;

    mapping(address vaultAddr => uint64) public maxPriceAge;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc ISyncInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("SyncInvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address to, uint256 amount) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        } else {
            IERC6909(token).transfer(to, tokenId, amount);
        }
    }

    // --- Deposits ---
    /// @inheritdoc ISyncInvestmentManager
    function maxDeposit(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        IBaseVault vault = IBaseVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncInvestmentManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        IBaseVault vault = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault.poolId(), vault.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        shares = PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncInvestmentManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        ITranche tranche = ITranche(IBaseVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc ISyncInvestmentManager
    function maxMint(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        IBaseVault vault = IBaseVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncInvestmentManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        IBaseVault vault = IBaseVault(vaultAddr);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault.poolId(), vault.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncInvestmentManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = previewMint(vaultAddr, owner, shares);

        ITranche tranche = ITranche(IBaseVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    // --- Admin actions ---
    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }
}
