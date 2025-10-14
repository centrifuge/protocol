// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IDepositManager, IWithdrawManager} from "./IBalanceSheetManager.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

/// @title  IOnOfframpManager
/// @notice Interface for managing onramp (deposits) and offramp (withdrawals) operations for a specific pool and share class
/// @dev    Combines deposit, withdraw, and contract update functionality with relayer and asset whitelisting
interface IOnOfframpManager is IDepositManager, IWithdrawManager, ITrustedContractUpdate {
    enum TrustedCall {
        Onramp,
        Relayer,
        Offramp
    }

    event UpdateOnramp(address indexed asset, bool isEnabled);
    event UpdateRelayer(address indexed relayer, bool isEnabled);
    event UpdateOfframp(address indexed asset, address receiver, bool isEnabled);

    error NotAllowedOnrampAsset();
    error InvalidAmount();
    error InvalidOfframpDestination();
    error InvalidPoolId();
    error InvalidShareClassId();
    error NotContractUpdater();
    error NotRelayer();
    error ERC6909NotSupported();
    error UnknownTrustedCall();

    /// @notice Get the pool ID this manager is configured for
    /// @return The pool identifier
    function poolId() external view returns (PoolId);

    /// @notice Get the share class ID this manager is configured for
    /// @return The share class identifier
    function scId() external view returns (ShareClassId);
}
