// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITokenBridge} from "./interfaces/ITokenBridge.sol";

import {Auth} from "../misc/Auth.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IGateway} from "../core/messaging/interfaces/IGateway.sol";
import {ITrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";

/// @title  TokenBridge
/// @notice Wrapper contract for cross-chain token transfers.
/// @dev    Integrates a relayer which is used for spoke -> hub -> spoke transfers, where the relayer pays
///         for the second leg on the hub chain, using the overpayment of the first leg on the source chain.
contract TokenBridge is Recoverable, ITokenBridge {
    using MathLib for uint256;

    ISpoke public spoke;
    IGateway public gateway;

    uint16 public immutable localCentrifugeId;

    address public relayer;
    mapping(PoolId => mapping(ShareClassId => GasLimits)) public gasLimits;
    mapping(uint256 evmChainId => uint16 centrifugeId) public chainIdToCentrifugeId;

    constructor(ISpoke spoke_, uint16 localCentrifugeId_, address deployer) Auth(deployer) {
        spoke = spoke_;
        localCentrifugeId = localCentrifugeId_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITokenBridge
    function file(bytes32 what, address data) external auth {
        if (what == "relayer") relayer = data;
        else if (what == "spoke") spoke = ISpoke(data);
        else if (what == "gateway") gateway = IGateway(data);
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
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external auth {
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
        external
        payable
        returns (bytes memory)
    {
        uint16 centrifugeId = chainIdToCentrifugeId[destinationChainId];
        require(centrifugeId != 0, InvalidChainId());
        require(!gateway.isBatching(), NotBatchable());

        (PoolId poolId, ShareClassId scId) = spoke.shareTokenDetails(token);

        // No approval needed: the spoke pulls the shares from this contract via authTransferFrom with
        // from == msg.sender, which skips the allowance path.
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);

        _crosschainTransfer(centrifugeId, poolId, scId, receiver, amount.toUint128(), refundAddress);

        emit Send(token, msg.sender, destinationChainId, receiver, amount, refundAddress);
        return bytes("");
    }

    function _crosschainTransfer(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        address refundAddress
    ) internal {
        GasLimits memory limits = gasLimits[poolId][scId];
        // The relayer only funds a second leg for a spoke -> hub -> spoke transfer. When either the source or
        // the destination is the hub the transfer is a single leg, so (as when no relayer is set) the
        // overpayment is refunded directly to the user instead of the relayer.
        bool hubIsEndpoint = centrifugeId == poolId.centrifugeId() || localCentrifugeId == poolId.centrifugeId();
        address refund = hubIsEndpoint || relayer == address(0) ? refundAddress : relayer;
        spoke.crosschainTransferShares{value: msg.value}(
            centrifugeId, poolId, scId, receiver, amount, limits.extraGasLimit, limits.remoteExtraGasLimit, refund
        );
    }
}
