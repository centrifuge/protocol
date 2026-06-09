// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CentrifugeIntegrationTest} from "./Integration.t.sol";

import {Gateway} from "../../src/core/messaging/Gateway.sol";
import {ERR_MAX_LENGTH} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IMessageHandler} from "../../src/core/messaging/interfaces/IMessageHandler.sol";
import {IProtocolPauser} from "../../src/core/messaging/interfaces/IProtocolPauser.sol";

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Reverts with exactly ERR_MAX_LENGTH zero bytes via assembly, keeping G_inner negligible.
///         Using assembly avoids the memory allocation that `revert(new string(...))` would charge
///         to the inner call's budget. The outer context still pays returndatacopy for ERR_MAX_LENGTH
///         bytes — the worst-case cost this reserve must absorb.
contract AlwaysFailProcessor is IMessageHandler {
    function handle(uint16, bytes calldata) external pure override {
        assembly {
            revert(0, ERR_MAX_LENGTH)
        }
    }
}

/// @notice Overrides Gateway._afterProcessorCall to record a gasleft() checkpoint via transient storage
///         immediately after excessivelySafeCall returns, without duplicating any _safeProcess logic.
contract GatewayHarness is Gateway {
    uint256 internal constant _GAS_CHECKPOINT_TSLOT = uint256(keccak256("GatewayHarness.gasCheckpoint"));

    constructor(uint16 localCentrifugeId_, IProtocolPauser pauser_, address deployer)
        Gateway(localCentrifugeId_, pauser_, deployer)
    {}

    function _afterProcessorCall() internal override {
        uint256 tslot = _GAS_CHECKPOINT_TSLOT;
        assembly {
            tstore(tslot, gas())
        }
    }

    /// @return consumedGas      Total gas consumed by the whole safe-process call.
    /// @return failureBranchGas Gas consumed after excessivelySafeCall returns (storage++ + event).
    function safeProcess(uint16 centrifugeId, bytes memory message, bytes32 messageHash, uint128 gasLimit)
        external
        returns (uint256 consumedGas, uint256 failureBranchGas)
    {
        uint128 reserve = messageProperties.messageFailureGasReserve();
        uint256 g0 = gasleft();
        _safeProcess(centrifugeId, message, messageHash, gasLimit, reserve);
        uint256 g2 = gasleft();
        uint256 g1;
        uint256 tslot = _GAS_CHECKPOINT_TSLOT;
        assembly {
            g1 := tload(tslot)
        }
        consumedGas = g0 - g2;
        failureBranchGas = g1 - g2;
    }
}

/// @notice Benchmarks the failure-path gas budget against GasService.messageFailureGasReserve.
///
///         _safeProcess gives the processor (gasLimit - reserve) gas and relies on the reserved budget
///         to cover all outer-context work when the processor reverts:
///           - excessivelySafeCall overhead: call opcode + returndatacopy(ERR_MAX_LENGTH)
///           - failure branch: failedMessages storage write + FailMessage event
///
///         AlwaysFailProcessor reverts with ERR_MAX_LENGTH zero bytes via assembly, keeping G_inner
///         negligible. consumedGas therefore approximates the actual outer-context cost that must fit
///         within the reserve, without the G_inner overcount of the previous `fail - ok` approach.
contract GatewayFailGasTest is CentrifugeIntegrationTest {
    GatewayHarness gatewayHarness;

    function setUp() public override {
        super.setUp();

        gatewayHarness = new GatewayHarness(LOCAL_CENTRIFUGE_ID, gateway.pauser(), address(this));
        gatewayHarness.file("processor", address(new AlwaysFailProcessor()));
        gatewayHarness.file("messageProperties", address(gasService));
    }

    function testProcessFailMessageGasBenchmark() public {
        bytes memory message = new bytes(10);
        bytes32 messageHash = keccak256(message);

        // Give the processor plenty of headroom so the inner-call cap is never the bottleneck
        uint128 reserve = gasService.messageFailureGasReserve();
        uint128 gasLimit = reserve + 100_000;

        (uint256 consumed, uint256 branchGas) =
            gatewayHarness.safeProcess(LOCAL_CENTRIFUGE_ID, message, messageHash, gasLimit);

        // Double-checking the benchmarking is working as expected:
        assertEq(gatewayHarness.failedMessages(LOCAL_CENTRIFUGE_ID, messageHash), 1);

        console.log("excessivelySafeCall outer overhead (call + returndatacopy):", consumed - branchGas);
        console.log("failure branch (storage write + FailMessage event):        ", branchGas);
        console.log("total outer-context cost vs reserve:                        ", consumed, "/", reserve);

        // Coverage disables the optimizer, increasing gas costs
        uint256 covTolerance = vm.isContext(VmSafe.ForgeContext.Coverage) ? 5_000 : 0;
        assertLt(consumed, reserve + covTolerance, "messageFailureGasReserve is not high enough");
    }
}
