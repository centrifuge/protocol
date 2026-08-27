// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";

import {MockValuation} from "../core/mocks/MockValuation.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {ISyncManager} from "../../src/vaults/interfaces/IVaultManagers.sol";

import {DeployerInput, FullDeployer, noAdaptersInput, defaultTxLimits} from "../../script/deploy/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {MAX_MESSAGE_COST as GAS} from "../utils/GasConstants.sol";

/// @notice The base contract for integrators that want to tests their contracts.
/// It assumes a full deployment in one chain.
/// @dev NOTE. Use always LOCAL_CENTRIFUGE_ID when centrifugeId param is required
contract CentrifugeIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = IntegrationConstants.LOCAL_CENTRIFUGE_ID;
    address FUNDED = makeAddr("FUNDED");
    uint256 constant DEFAULT_SUBSIDY = IntegrationConstants.INTEGRATION_DEFAULT_SUBSIDY;

    // Helper contracts
    MockValuation valuation;

    function setUp() public virtual {
        address[] memory executors = new address[](1);
        executors[0] = address(this);

        // Deployment: this contract is the namespace of its own namespace, and its own executor
        super.deployFullBothPhases(
            DeployerInput({
                centrifugeId: LOCAL_CENTRIFUGE_ID,
                deploymentId: "",
                txLimits: defaultTxLimits(),
                protocolSafe: ISafe(makeAddr("ProtocolSafe")),
                opsSafe: ISafe(makeAddr("OpsSafe")),
                root: address(0),
                delay: 0,
                adapters: noAdaptersInput()
            }),
            address(this),
            executors
        );

        // Extra deployment
        valuation = new MockValuation(hubRegistry);
        vm.label(address(valuation), "mockValuation");

        // Accounts
        vm.deal(FUNDED, 100 ether);
    }

    /// @dev Core no longer keeps a tuple -> vault reverse lookup; recover a freshly DeployAndLink'd vault from
    ///      the most recent DeployVault event. Requires `vm.recordLogs()` to be active across the deploy call.
    function _deployedVaultFromLogs() internal returns (address vault_) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == ISpokeRegistry.DeployVault.selector) {
                (,, address v) = abi.decode(logs[i - 1].data, (uint256, address, address));
                return v;
            }
        }
        revert("no DeployVault log");
    }
}

/// @notice Similar to CentrifugeIntegrationTest but with some customized general utilities
contract CentrifugeIntegrationTestWithUtils is CentrifugeIntegrationTest {
    address immutable FM = makeAddr("fundManager");
    PoolId POOL_A;
    ShareClassId SC_1;

    // Extra deployment
    ERC20 usdc;
    AssetId usdcId;

    function setUp() public virtual override {
        super.setUp();

        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);

        // Extra deployment
        usdc = new ERC20(6);
        usdc.rely(address(protocolGuardian.safe()));
        vm.startPrank(address(protocolGuardian.safe()));
        usdc.file("name", "USD Coin");
        usdc.file("symbol", "USDC");
        vm.stopPrank();
        vm.label(address(usdc), "usdc");
    }

    function _registerUSDC() internal {
        vm.prank(FUNDED);
        usdcId = spoke.registerAsset{value: GAS}(LOCAL_CENTRIFUGE_ID, address(usdc), 0, FUNDED);
    }

    function _mintUSDC(address receiver, uint256 amount) internal {
        vm.prank(address(protocolGuardian.safe()));
        usdc.mint(receiver, amount);
    }

    function _createPool() internal {
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, FM, USD_ID);

        vm.prank(FM);
        hub.addShareClass(POOL_A, "ShareClass1", "sc1", bytes32(bytes8(POOL_A.raw())));
    }

    function _syncManagerMaxReserveMsg(ShareClassId scId, AssetId assetId, uint128 maxReserve)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(scId.raw(), uint8(ISyncManager.TrustedCall.MaxReserve), assetId.raw(), maxReserve);
    }
}

contract _CentrifugeIntegrationTestWithUtilsTest is CentrifugeIntegrationTestWithUtils {
    function testCreatePool() public {
        _createPool();
    }

    function testMintUSDC(uint256 amount) public {
        _mintUSDC(makeAddr("receiver"), amount);
    }

    function testRegisterUSDC() public {
        _registerUSDC();
    }
}
