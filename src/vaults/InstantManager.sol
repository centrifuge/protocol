// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";
import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IInstantManager} from "src/vaults/interfaces/IInstantManager.sol";

/// @title  Instant Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract InstantManager is Auth, IInstantManager {
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
    function maxDeposit(address vault, address owner) external view returns (uint256) {
        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IInstantManager
    function previewDeposit(address vault, address, /* sender */ uint256 assets) public view returns (uint256 shares) {
        IBaseVault vault_ = IBaseVault(vault);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        require(block.timestamp - computedAt <= maxPriceAge[vault], PriceTooOld());

        // TODO: actually convert assets to shares
        shares = assets;
    }

    /// @inheritdoc IInstantManager
    function deposit(address vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = previewDeposit(vault, owner, assets);

        ITranche tranche = ITranche(IBaseVault(vault).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IInstantManager
    function maxMint(address vault, address owner) external view returns (uint256) {
        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IInstantManager
    function previewMint(address vault, address sender, uint256 shares) public view returns (uint256 assets) {
        IBaseVault vault_ = IBaseVault(vault);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        require(block.timestamp - computedAt <= maxPriceAge[vault], PriceTooOld());

        // TODO: actually convert assets to shares
        shares = assets;
    }

    /// @inheritdoc IInstantManager
    function mint(address vault, uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = previewMint(vault, owner, shares);

        ITranche tranche = ITranche(IBaseVault(vault).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    // --- Admin actions ---
    /// @inheritdoc IInstantManager
    function handle(bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }
}
