// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {IFlashLoanHelper} from "./interfaces/IFlashLoanHelper.sol";
import {IAaveV3Pool, IAaveV3FlashLoanReceiver} from "./interfaces/IAaveV3Pool.sol";

import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

/// @title  FlashLoanHelper
/// @notice Periphery contract bridging Aave V3 flash loans to Executor.executeCallback().
///         The outer weiroll script calls `requestFlashLoan`, Aave sends tokens and calls back
///         `executeOperation`, which forwards to the Executor's inner callback script.
///
///         The `pool` parameter in `requestFlashLoan` MUST be a fixed
///         state element in the weiroll stateBitmap. If left as non-fixed state, a strategist
///         could substitute a malicious pool address.
contract FlashLoanHelper is IFlashLoanHelper, IAaveV3FlashLoanReceiver {
    using SafeTransferLib for address;

    address private transient _pool;
    address private transient _executor;

    /// @inheritdoc IFlashLoanHelper
    function requestFlashLoan(
        IAaveV3Pool pool,
        address token,
        uint256 amount,
        IExecutor executor,
        bytes calldata callbackData
    ) external {
        _pool = address(pool);
        _executor = address(executor);
        emit FlashLoan(address(pool), token, amount, address(executor));
        pool.flashLoanSimple(address(this), token, amount, callbackData, 0);
        _pool = address(0);
        _executor = address(0);
    }

    /// @inheritdoc IAaveV3FlashLoanReceiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        require(msg.sender == _pool, NotPool());
        require(_executor != address(0), NotActive());
        require(initiator == address(this), NotInitiator());

        address executor = _executor;
        asset.safeTransfer(executor, amount);

        (bytes32[] memory commands, bytes[] memory state, uint256 stateBitmap) =
            abi.decode(params, (bytes32[], bytes[], uint256));
        IExecutor(executor).executeCallback(commands, state, stateBitmap);

        // Inner script must have sent repayment tokens back to this contract
        asset.safeApprove(msg.sender, 0);
        asset.safeApprove(msg.sender, amount + premium);
        return true;
    }
}
