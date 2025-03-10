// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IInstantManager} from "src/vaults/interfaces/IInstantManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {IMessageHandler} from "src/vaults/interfaces/IInvestmentManager.sol";

/// @title  Instant Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract InstantManager is Auth, IInstantManager {
    using MathLib for uint256;

    address public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;

    mapping(address vault => uint64) public maxPriceAge;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IInstantManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("InstantManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Deposits ---
    /// @inheritdoc IInstantManager
    function maxDeposit(address vault, address /* owner */ ) public view returns (uint256) {
        IBaseVault vault_ = IBaseVault(vault);
        require(poolManager.isAllowedAsset(vault_.poolId(), vault_.asset()), AssetNotAllowed());

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IInstantManager
    function previewDeposit(address vault, address, /* sender */ uint256 assets) public view returns (uint256 shares) {
        IBaseVault vault_ = IBaseVault(vault);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        require(block.timestamp - computedAt <= maxPriceAge[vault], PriceTooOld());

        shares = PriceConversionLib.calculateShares(assets.toUint128(), vault, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IInstantManager
    function deposit(address vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vault, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vault, owner, assets);

        ITranche tranche = ITranche(IBaseVault(vault).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IInstantManager
    function maxMint(address vault, address /* owner */ ) public view returns (uint256) {
        IBaseVault vault_ = IBaseVault(vault);
        require(poolManager.isAllowedAsset(vault_.poolId(), vault_.asset()), AssetNotAllowed());

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IInstantManager
    function previewMint(address vault, address, /* sender */ uint256 shares) public view returns (uint256 assets) {
        IBaseVault vault_ = IBaseVault(vault);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        require(block.timestamp - computedAt <= maxPriceAge[vault], PriceTooOld());

        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vault, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IInstantManager
    function mint(address vault, uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = previewMint(vault, owner, shares);

        ITranche tranche = ITranche(IBaseVault(vault).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    // --- Admin actions ---
    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }
}
