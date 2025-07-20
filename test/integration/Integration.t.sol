// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "centrifuge-v3/src/misc/ERC20.sol";

import {AssetId} from "centrifuge-v3/src/common/types/AssetId.sol";
import {PoolId} from "centrifuge-v3/src/common/types/PoolId.sol";
import {ShareClassId} from "centrifuge-v3/src/common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST as GAS} from "centrifuge-v3/src/common/interfaces/IGasService.sol";

import {UpdateContractMessageLib} from "centrifuge-v3/src/spoke/libraries/UpdateContractMessageLib.sol";

import {FullDeployer, FullActionBatcher, CommonInput} from "centrifuge-v3/script/FullDeployer.s.sol";

import {MockValuation} from "centrifuge-v3/test/common/mocks/MockValuation.sol";

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
    using UpdateContractMessageLib for *;

    address immutable FM = makeAddr("fundManager");
    PoolId POOL_A;
    ShareClassId SC_1;

    // Extra deployment
    ERC20 usdc;
    AssetId usdcId;

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

    function _registerUSDC() internal {
        vm.startPrank(FUNDED);
        usdcId = spoke.registerAsset{value: GAS}(LOCAL_CENTRIFUGE_ID, address(usdc), 0);
    }

    function _createPool() internal {
        vm.startPrank(ADMIN);
        guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        hub.addShareClass(POOL_A, "ShareClass1", "sc1", bytes32("salt"));

        vm.startPrank(FUNDED);
        gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
    }

    function _updateContractSyncDepositMaxReserveMsg(AssetId assetId, uint128 maxReserve)
        internal
        pure
        returns (bytes memory)
    {
        return UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
            assetId: assetId.raw(),
            maxReserve: maxReserve
        }).serialize();
    }

}

contract _CentrifugeIntegrationTestWithUtilsTest is CentrifugeIntegrationTestWithUtils {
    function testCreatePool() public {
        _createPool();
    }

    function testRegisterUSDC() public {
        _registerUSDC();
    }
}
