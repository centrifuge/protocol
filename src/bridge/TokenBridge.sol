// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITokenBridge} from "./interfaces/ITokenBridge.sol";

import {Auth} from "../misc/Auth.sol";
import {IERC20} from "../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";

/// @title  TokenBridge
/// @notice Wrapper contract for cross-chain token transfers compatible with Glacis Airlift
contract TokenBridge is Auth, ITokenBridge {
    ISpoke public immutable spoke;

    address public relayer;
    mapping(PoolId => mapping(ShareClassId => GasLimits)) public gasLimits;
    mapping(uint256 evmChainId => uint16 centrifugeId) public chainIdToCentrifugeId;

    constructor(ISpoke spoke_, address deployer) Auth(deployer) {
        spoke = spoke_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITokenBridge
    function file(bytes32 what, address data) external auth {
        if (what == "relayer") relayer = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ITokenBridge
    function file(bytes32 what, uint256 evmChainId, uint16 centrifugeId) external auth {
        if (what == "centrifugeId") chainIdToCentrifugeId[evmChainId] = centrifugeId;
        else revert FileUnrecognizedParam();
        emit File(what, evmChainId, centrifugeId);
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.SetGasLimits) {
            (, uint128 extraGasLimit, uint128 remoteExtraGasLimit) = abi.decode(payload, (uint8, uint128, uint128));

            require(address(spoke.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

            gasLimits[poolId][scId] = GasLimits(extraGasLimit, remoteExtraGasLimit);
            emit UpdateGasLimits(poolId, scId, extraGasLimit, remoteExtraGasLimit);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Bridging
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITokenBridge
    function send(address token, uint256 amount, bytes32 receiver, uint256 destinationChainId, address refundAddress)
        public
        payable
        returns (bytes memory)
    {
        uint16 centrifugeId = chainIdToCentrifugeId[destinationChainId];
        require(centrifugeId != 0, InvalidChainId());

        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        if (IERC20(token).allowance(address(this), address(spoke)) == 0) {
            SafeTransferLib.safeApprove(token, address(spoke), type(uint256).max);
        }

        (PoolId poolId, ShareClassId scId) = spoke.shareTokenDetails(token);
        GasLimits memory limits = gasLimits[poolId][scId];

        spoke.crosschainTransferShares{value: msg.value}(
            centrifugeId,
            poolId,
            scId,
            receiver,
            uint128(amount),
            limits.extraGasLimit,
            limits.remoteExtraGasLimit,
            relayer != address(0) ? relayer : refundAddress // Transfer remaining ETH to relayer if set
        );

        return bytes("");
    }
}
