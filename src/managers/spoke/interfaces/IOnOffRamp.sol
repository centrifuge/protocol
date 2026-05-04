// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAccountingToken} from "./IAccountingToken.sol";
import {IDepositManager, IWithdrawManager} from "./IBalanceSheetManager.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

/// @title  IOnOffRamp
/// @notice Interface for managing onramp (deposits) and offramp (withdrawals) operations for a specific pool and share class
/// @dev    Combines deposit, withdraw, and contract update functionality with relayer and asset whitelisting
interface IOnOffRamp is IDepositManager, IWithdrawManager, ITrustedContractUpdate {
    enum TrustedCall {
        Onramp,
        Relayer,
        Offramp,
        Withdraw
    }

    event UpdateOnramp(address indexed asset, bool isEnabled);
    event UpdateRelayer(address indexed relayer, bool isEnabled);
    event UpdateOfframp(address indexed asset, address receiver, bool isEnabled);
    event TrustedWithdraw(address indexed asset, uint256 amount, address receiver);

    error NotAllowedOnrampAsset();
    error InvalidOfframpDestination();
    error InvalidPoolId();
    error InvalidShareClassId();
    error NotContractUpdater();
    error NotRelayer();
    error ERC6909NotSupported();
    error UnknownTrustedCall();

    /// @notice Get the pool ID this manager is configured for
    function poolId() external view returns (PoolId);

    /// @notice Get the share class ID this manager is configured for
    function scId() external view returns (ShareClassId);

    /// @notice Get the accounting token used for minting receipts
    function accountingToken() external view returns (IAccountingToken);

    /// @notice Address authorized to update on/offramp configuration via trusted cross-chain calls
    function contractUpdater() external view returns (address);

    /// @notice Manages share token and asset balances, including minting, burning, and escrow transfers
    function balanceSheet() external view returns (IBalanceSheet);

    /// @notice Whether an asset is whitelisted for deposit (onramp) operations
    /// @param asset The asset address
    function onramp(address asset) external view returns (bool);

    /// @notice Whether an address is authorized to relay deposit operations on behalf of users
    /// @param relayer The relayer address
    function relayer(address relayer) external view returns (bool);

    /// @notice Whether withdrawal (offramp) is enabled for a specific asset and receiver pair
    /// @param asset The asset address
    /// @param receiver The receiver address
    function offramp(address asset, address receiver) external view returns (bool);
}
