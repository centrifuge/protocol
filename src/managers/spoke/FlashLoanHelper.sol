// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.28;

import {IOnchainPM} from "./interfaces/IOnchainPM.sol";
import {IFlashLoanHelper} from "./interfaces/IFlashLoanHelper.sol";
import {IOnchainPMFactory} from "./interfaces/IOnchainPMFactory.sol";
import {IAaveV3Pool, IAaveV3FlashLoanReceiver} from "./interfaces/IAaveV3Pool.sol";

import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

/// @title  FlashLoanHelper
/// @notice Periphery contract bridging Aave V3 flash loans to OnchainPM.executeCallback().
///         The outer weiroll script calls `requestFlashLoan`, Aave sends tokens and calls back
///         `executeOperation`, which forwards to the OnchainPM's inner callback script.
///
///         The `pool` parameter in `requestFlashLoan` MUST be a fixed state element in the
///         weiroll stateBitmap. If left as non-fixed state, a strategist could substitute a
///         malicious pool address. The `onchainPM` parameter is validated to be both the caller
///         and a factory-deployed instance, preventing re-entry via a malicious pool.
contract FlashLoanHelper is IFlashLoanHelper, IAaveV3FlashLoanReceiver {
    using SafeTransferLib for address;

    IOnchainPMFactory public immutable factory;

    address private transient _pool;
    address private transient _onchainPM;

    constructor(IOnchainPMFactory factory_) {
        factory = factory_;
    }

    /// @inheritdoc IFlashLoanHelper
    function requestFlashLoan(
        IAaveV3Pool pool,
        address token,
        uint256 amount,
        IOnchainPM onchainPM,
        bytes calldata callbackData
    ) external {
        require(_pool == address(0), AlreadyActive());
        require(msg.sender == address(onchainPM), NotOnchainPM());
        require(factory.getAddress(onchainPM.poolId()) == address(onchainPM), NotAuthorized());
        _pool = address(pool);
        _onchainPM = address(onchainPM);
        emit FlashLoan(address(pool), token, amount, address(onchainPM));
        pool.flashLoanSimple(address(this), token, amount, callbackData, 0);
        _pool = address(0);
        _onchainPM = address(0);
    }

    /// @inheritdoc IAaveV3FlashLoanReceiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        require(msg.sender == _pool, NotPool());
        require(_onchainPM != address(0), NotActive());
        require(initiator == address(this), NotInitiator());

        address onchainPM = _onchainPM;
        asset.safeTransfer(onchainPM, amount);

        (bytes32[] memory commands, bytes[] memory state, uint128 stateBitmap) =
            abi.decode(params, (bytes32[], bytes[], uint128));
        IOnchainPM(onchainPM).executeCallback(commands, state, stateBitmap);

        // Inner script must have sent repayment tokens back to this contract
        asset.safeApprove(msg.sender, 0);
        asset.safeApprove(msg.sender, amount + premium);
        return true;
    }
}
