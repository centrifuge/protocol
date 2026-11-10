// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreditLine, IBasinLiquidityRoute, IGroveBasinLike} from "./interfaces/IBasinLiquidityRoute.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {VaultDetails, ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IAccountingToken} from "../../managers/spoke/interfaces/IAccountingToken.sol";

import {IVault} from "../interfaces/IVault.sol";
import {ILiquidityRoute} from "../policies/interfaces/IVaultPlugins.sol";

/// @title  Basin Liquidity Route
/// @notice Backs instant redemptions with Grove Basin liquidity: the vault draws its escrow shortfall
///         from the basin, recording a receivable the pool later `repay`s. The receivable is bounded
///         by both the pool's `limit` and the liquidity provider's `credit`, and is held in the pool's
///         escrow as liability accounting tokens, so the draw reaches the hub with its debt.
contract BasinLiquidityRoute is Recoverable, IBasinLiquidityRoute {
    using MathLib for uint256;

    ISpoke public immutable spoke;
    address public immutable envoy;
    IGroveBasinLike public immutable basin;
    ISpokeRegistry public immutable spokeRegistry;
    IAccountingToken public immutable accountingToken;

    mapping(address vault => CreditLine) internal _lines;

    constructor(IGroveBasinLike basin_, ISpoke spoke_, address envoy_, IAccountingToken accountingToken_, address root_)
        Auth(root_)
    {
        basin = basin_;
        spoke = spoke_;
        envoy = envoy_;
        spokeRegistry = spoke_.spokeRegistry();
        accountingToken = accountingToken_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (address vault, uint128 limit_) = abi.decode(payload, (address, uint128));

        require(_details(vault).poolId == poolId && IVault(vault).poolId() == poolId, WrongPool());
        _lines[vault].limit = limit_;
        emit SetLimit(poolId, vault, limit_);
    }

    /// @inheritdoc IBasinLiquidityRoute
    function setCredit(address vault, uint128 credit_) external {
        require(msg.sender == basin.liquidityProvider(), NotLiquidityProvider());
        _lines[vault].credit = credit_;
        emit SetCredit(_details(vault).poolId, vault, credit_);
    }

    //----------------------------------------------------------------------------------------------
    // Liquidity
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidityRoute
    function provide(address vault, uint128 assets) external {
        require(msg.sender == vault, NotVault());
        require(assets <= _headroom(vault), ExceedsLimit());

        // From the registry: a fabricated vault would otherwise name any asset.
        VaultDetails memory details = _details(vault);

        // Measured at the vault, which notes `assets` once this returns, whatever the venue reports.
        uint256 before = IERC20(details.asset).balanceOf(vault);
        basin.withdraw(details.asset, vault, assets);
        require(IERC20(details.asset).balanceOf(vault) >= before + assets, InsufficientLiquidity());

        _lines[vault].receivable += assets;

        uint256 liabilityId = _liabilityId(details);
        accountingToken.mint(address(this), liabilityId, assets, details.scId);
        accountingToken.approve(address(spoke), liabilityId, assets);
        spoke.deposit(details.poolId, details.scId, address(accountingToken), liabilityId, assets);

        emit BasinProvided(details.poolId, vault, assets);
    }

    /// @inheritdoc ILiquidityRoute
    function forward(address, uint128) external pure {}

    /// @inheritdoc IBasinLiquidityRoute
    function repay(address vault, uint128 assets) external {
        VaultDetails memory details = _details(vault);
        require(spokeRegistry.manager(details.poolId, msg.sender), NotManager());

        _lines[vault].receivable -= assets;

        // The provider is paid in full whatever the booking allows: a route that lost its roles, or
        // a liability another manager moved, leaves the rest for the pool to clear itself.
        uint256 liabilityId = _liabilityId(details);
        uint256 booked = _canBook(details)
            ? spoke.availableBalanceOf(details.poolId, details.scId, address(accountingToken), liabilityId)
            : 0;
        uint128 unbooked = MathLib.min(assets, booked).toUint128();
        if (unbooked > 0) {
            // forgefmt: disable-next-item
            spoke.withdraw(
                details.poolId, details.scId, address(accountingToken), liabilityId, address(this), unbooked
            );
            accountingToken.burn(address(this), liabilityId, unbooked, details.scId);
        }
        if (unbooked < assets) emit BasinLiabilityLeftBooked(details.poolId, vault, assets - unbooked);

        SafeTransferLib.safeTransferFrom(details.asset, msg.sender, basin.liquidityProvider(), assets);

        emit BasinRepaid(details.poolId, vault, msg.sender, assets);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBasinLiquidityRoute
    function limit(address vault) external view returns (uint128) {
        return _lines[vault].limit;
    }

    /// @inheritdoc IBasinLiquidityRoute
    function credit(address vault) external view returns (uint128) {
        return _lines[vault].credit;
    }

    /// @inheritdoc IBasinLiquidityRoute
    function receivable(address vault) external view returns (uint128) {
        return _lines[vault].receivable;
    }

    /// @inheritdoc IBasinLiquidityRoute
    function available(address vault) external view returns (uint128 assets) {
        uint128 headroom = _headroom(vault);
        if (headroom == 0) return 0;

        VaultDetails memory details = _details(vault);
        if (!_canBook(details)) return 0;

        bytes memory data = abi.encodeCall(IGroveBasinLike.previewWithdraw, (details.asset, type(uint256).max));
        (bool success, bytes memory answer) = address(basin).staticcall(data);
        if (!success || answer.length < 64) return 0;
        (, uint256 withdrawable) = abi.decode(answer, (uint256, uint256));
        return MathLib.min(withdrawable, headroom).toUint128();
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev The lower of the two limits, less what the vault already owes.
    function _headroom(address vault) internal view returns (uint128) {
        CreditLine memory line = _lines[vault];
        uint128 bound = MathLib.min(line.limit, line.credit).toUint128();
        return bound > line.receivable ? bound - line.receivable : 0;
    }

    /// @dev Booking takes the pool's spoke manager role, minting rights on the accounting token and the
    ///      liability token registered on the spoke. The pool's spoke policy cannot be asked in a view.
    function _canBook(VaultDetails memory details) internal view returns (bool) {
        return spokeRegistry.manager(details.poolId, address(this))
            && accountingToken.minters(details.poolId, address(this))
            && !spokeRegistry.assetToId(address(accountingToken), _liabilityId(details)).isNull();
    }

    function _liabilityId(VaultDetails memory details) internal view returns (uint256) {
        return accountingToken.toTokenId(details.poolId, details.asset, true);
    }

    /// @dev From the registry, not the caller-chosen vault: an unknown address maps to no pool.
    function _details(address vault) internal view returns (VaultDetails memory) {
        return spokeRegistry.vaultDetails(vault);
    }
}
