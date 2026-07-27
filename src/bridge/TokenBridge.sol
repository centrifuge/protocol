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
import {IManagerCallFromHub} from "../core/utils/interfaces/IManagerCall.sol";

/// @title  TokenBridge
/// @notice Wrapper contract for cross-chain token transfers.
/// @dev    Integrates a relayer which is used for spoke -> hub -> spoke transfers, where the relayer pays
///         for the second leg on the hub chain, using the overpayment of the first leg on the source chain.
contract TokenBridge is Recoverable, ITokenBridge, IManagerCallFromHub {
    using MathLib for uint256;

    address public immutable envoy;
    uint16 public immutable localCentrifugeId;

    ISpoke public spoke;
    address public relayer;
    IGateway public gateway;

    mapping(PoolId => mapping(ShareClassId => GasLimits)) public gasLimits;
    mapping(uint256 evmChainId => uint16 centrifugeId) public chainIdToCentrifugeId;

    constructor(ISpoke spoke_, IGateway gateway_, uint16 localCentrifugeId_, address envoy_, address deployer)
        Auth(deployer)
    {
        envoy = envoy_;
        spoke = spoke_;
        gateway = gateway_;
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

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (bytes16 scId_, uint128 extraGasLimit, uint128 remoteExtraGasLimit) =
            abi.decode(payload, (bytes16, uint128, uint128));
        ShareClassId scId = ShareClassId.wrap(scId_);
        require(address(spoke.spokeRegistry().shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

        gasLimits[poolId][scId] = GasLimits(extraGasLimit, remoteExtraGasLimit);
        emit UpdateGasLimits(poolId, scId, extraGasLimit, remoteExtraGasLimit);
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

        (PoolId poolId, ShareClassId scId) = spoke.spokeRegistry().tokenDetails(token);
        require(!poolId.isNull(), ShareTokenDoesNotExist());

        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(token, address(spoke), amount);

        _crosschainTransfer(centrifugeId, poolId, scId, receiver, amount.toUint128(), msg.sender, refundAddress);

        emit Send(token, msg.sender, destinationChainId, receiver, amount, refundAddress);
        return bytes("");
    }

    /// @dev Reads the pool/share-class gas limits once and forwards the transfer to the spoke.
    function _crosschainTransfer(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        address sender_,
        address refundAddress
    ) internal {
        GasLimits memory limits = gasLimits[poolId][scId];

        // The relayer only funds a second leg for a spoke -> hub -> spoke transfer. When either the source or
        // the destination is the hub the transfer is a single leg, so (as when no relayer is set) the
        // overpayment is refunded directly to the user instead of the relayer.
        bool hubIsEndpoint = centrifugeId == poolId.centrifugeId() || localCentrifugeId == poolId.centrifugeId();
        address refund = hubIsEndpoint || relayer == address(0) ? refundAddress : relayer;
        spoke.crosschainTransferShares{value: msg.value}(
            centrifugeId,
            poolId,
            scId,
            receiver,
            sender_,
            address(this),
            amount,
            limits.extraGasLimit,
            limits.remoteExtraGasLimit,
            refund
        );
    }
}
