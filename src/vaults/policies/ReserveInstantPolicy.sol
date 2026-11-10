// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IInstantPolicy, IReserveInstantPolicy} from "./interfaces/IVaultPlugins.sol";

import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {ISpokeRegistry, VaultDetails} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../interfaces/IVault.sol";

/// @title  Reserve Instant Policy
/// @notice Default instant policy: deposits are capped at `maxReserve` minus the escrow balance,
///         redemptions are switched by `redeemEnabled`, each side has an optional fee in basis points
///         (paid to `feeRecipient`, or retained in the escrow when it is zero), either lane can be
///         gated to an allowlist of callers, and positions credited to others to an allowlist of sponsors.
contract ReserveInstantPolicy is IReserveInstantPolicy {
    ISpoke public immutable spoke;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;

    mapping(address vault => Config) public config;
    mapping(address vault => mapping(ConfigKind kind => mapping(address who => bool))) public isAllowed;

    constructor(ISpoke spoke_, address envoy_) {
        spoke = spoke_;
        envoy = envoy_;
        spokeRegistry = spoke_.spokeRegistry();
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (ConfigKind kind, address vault, bytes memory args) = abi.decode(payload, (ConfigKind, address, bytes));

        require(_details(vault).poolId == poolId && IVault(vault).poolId() == poolId, WrongPool());

        if (kind == ConfigKind.Terms) return _setTerms(poolId, vault, args);

        (address who, bool allowed) = abi.decode(args, (address, bool));
        isAllowed[vault][kind][who] = allowed;
        emit SetAllowed(poolId, vault, who, kind, allowed);
    }

    //----------------------------------------------------------------------------------------------
    // Instant lanes
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IInstantPolicy
    function maxInstantDeposit(address vault, address) external view returns (uint128 assets) {
        uint128 maxReserve = config[vault].maxReserve;
        if (maxReserve == 0) return 0;

        VaultDetails memory details = _details(vault);
        uint128 available = spoke.availableBalanceOf(details.poolId, details.scId, details.asset, details.tokenId);
        return MathLib.saturatingSub(maxReserve, available);
    }

    /// @inheritdoc IInstantPolicy
    function maxInstantRedeem(address vault, address owner) external view returns (uint128 assets) {
        Config storage config_ = config[vault];
        if (!config_.redeemEnabled || (config_.gatedRedeem && !isAllowed[vault][ConfigKind.Redeemer][owner])) return 0;
        return type(uint128).max;
    }

    /// @inheritdoc IInstantPolicy
    function quoteInstantDeposit(address vault, address, address, uint128 assets, bool exactOut)
        external
        view
        returns (int128 feeAssets, address feeRecipient)
    {
        Config storage config_ = config[vault];
        return (_fee(assets, exactOut, config_.depositFeeBps), config_.feeRecipient);
    }

    /// @inheritdoc IInstantPolicy
    function quoteInstantRedeem(address vault, address, address, uint128 assets, bool exactOut)
        external
        view
        returns (int128 feeAssets, address feeRecipient)
    {
        Config storage config_ = config[vault];
        return (_fee(assets, exactOut, config_.redeemFeeBps), config_.feeRecipient);
    }

    /// @inheritdoc IInstantPolicy
    function onInstantDeposit(address vault, address sender, address, uint128, bool) external view {
        Config storage config_ = config[vault];
        require(!config_.gatedDeposit || isAllowed[vault][ConfigKind.Depositor][sender], NotDepositor());
    }

    /// @inheritdoc IInstantPolicy
    function onInstantRedeem(address vault, address sender, address, uint128, bool) external view {
        Config storage config_ = config[vault];
        require(!config_.gatedRedeem || isAllowed[vault][ConfigKind.Redeemer][sender], NotRedeemer());
    }

    /// @inheritdoc IInstantPolicy
    function canCredit(address vault, address owner, address) external view returns (bool) {
        return isAllowed[vault][ConfigKind.Sponsor][owner];
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _setTerms(PoolId poolId, address vault, bytes memory args) internal {
        Config memory config_ = abi.decode(args, (Config));
        require(config_.depositFeeBps < MathLib.BPS && config_.redeemFeeBps < MathLib.BPS, InvalidFees());

        config[vault] = config_;
        emit SetConfig(poolId, vault, config_);
    }

    /// @dev From the registry, not the caller-chosen vault: an unknown address maps to no pool.
    function _details(address vault) internal view returns (VaultDetails memory) {
        return spokeRegistry.vaultDetails(vault);
    }

    /// @dev Charged on the gross, rounded up: floored, it is zero below `BPS / bps`, which a caller could exploit by
    ///      splitting. An exact-out net is grossed up first, so the fee is at least the configured rate of the gross.
    function _fee(uint128 assets, bool exactOut, uint16 bps) internal pure returns (int128) {
        if (!exactOut) return MathLib.toInt128(MathLib.fractionOf(assets, bps, MathLib.BPS, MathLib.Rounding.Up));

        uint256 gross = MathLib.fractionOf(assets, MathLib.BPS, MathLib.BPS - bps, MathLib.Rounding.Up);
        return MathLib.toInt128(gross - assets);
    }
}
