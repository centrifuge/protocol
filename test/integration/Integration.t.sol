// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../src/misc/ERC20.sol";

import {MockValuation} from "../common/mocks/MockValuation.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST as GAS} from "../../src/common/interfaces/IGasService.sol";

import {FullDeployer, FullActionBatcher, CommonInput} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

/// @notice The base contract for integrators that want to tests their contracts.
/// It assumes a full deployment in one chain.
/// @dev NOTE. Use always LOCAL_CENTRIFUGE_ID when centrifugeId param is required
contract CentrifugeIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    address immutable ADMIN = address(adminSafe);
    address immutable FUNDED = address(this);
    uint256 constant DEFAULT_SUBSIDY = 1 ether;

    // Helper contracts
    MockValuation valuation;

    function setUp() public virtual {
        // Deployment
        CommonInput memory input = CommonInput({
            centrifugeId: LOCAL_CENTRIFUGE_ID,
            adminSafe: adminSafe,
            batchGasLimit: uint128(GAS) * 100,
            version: bytes32(0)
        });

        FullActionBatcher batcher = new FullActionBatcher();
        super.labelAddresses("");
        super.deployFull(input, noAdaptersInput(), batcher);
        super.removeHubDeployerAccess(batcher);

        // Extra deployment
        valuation = new MockValuation(hubRegistry);
        vm.label(address(valuation), "mockValuation");

        // Subsidizing guardian actions
        gateway.subsidizePool{value: DEFAULT_SUBSIDY}(PoolId.wrap(0));
    }
}

/// @notice Similar to CentrifugeIntegrationTest but with some customized general utilities
contract CentrifugeIntegrationTestWithUtils is CentrifugeIntegrationTest {
    address immutable FM = makeAddr("fundManager");
    PoolId POOL_A;
    ShareClassId SC_1;

    // Extra deployment
    ERC20 usdc;

    function setUp() public override {
        super.setUp();

        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);

        // Extra deployment
        vm.startPrank(ADMIN);
        usdc = new ERC20(6);
        usdc.file("name", "USD Coin");
        usdc.file("symbol", "USDC");
        vm.label(address(usdc), "usdc");
    }

    function registerUSDC() public {
        vm.startPrank(FUNDED);
        spoke.registerAsset{value: GAS}(LOCAL_CENTRIFUGE_ID, address(usdc), 0);
    }

    function createPool() public {
        vm.startPrank(ADMIN);
        guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        hub.addShareClass(POOL_A, "ShareClass1", "sc1", bytes32("salt"));

        vm.startPrank(FUNDED);
        gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
    }
}

contract _CentrifugeIntegrationTestWithUtilsTest is CentrifugeIntegrationTestWithUtils {
    function testCreatePool() public {
        createPool();
    }

    function testRegisterUSDC() public {
        registerUSDC();
    }
}
