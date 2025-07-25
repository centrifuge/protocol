// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RelinkV2Eth} from "./RelinkV2Eth.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {ISpokeGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";

import {
    UpdateRestrictionType,
    UpdateRestrictionMessageLib
} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

contract RelinkV2TestBase is Test {
    RelinkV2Eth public spell;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");

        spell = new RelinkV2Eth();
    }

    function castSpell() internal {
        // NOTE: In production, this would be done through Guardian.scheduleRely + ROOT.executeScheduledRely
        // For testing, we simulate this by directly setting the spell as ward on ROOT
        // wards mapping is at slot 0 for Auth contracts
        bytes32 wardSlot = keccak256(abi.encode(address(spell), uint256(0)));
        vm.store(address(spell.V2_ROOT()), wardSlot, bytes32(uint256(1)));

        spell.cast();
    }
}

contract RelinkV2TestIntegrity is RelinkV2TestBase {
    // Main integration test
    function testSpellIntegration() public {
        castSpell();

        _checkLinkedVaults();
        _checkSpellCannotBeCastedSecondTime();
        _checkSpellAccessIsCleared();
    }

    function _checkLinkedVaults() internal view {
        assertEq(
            spell.JTRSY_SHARE_TOKEN().vault(spell.USDC_TOKEN()),
            spell.JTRSY_VAULT_ADDRESS(),
            "JTRSY_SHARE_TOKEN.vault mismatch"
        );
        assertEq(
            spell.JAAA_SHARE_TOKEN().vault(spell.USDC_TOKEN()),
            spell.JAAA_VAULT_ADDRESS(),
            "JAAA_SHARE_TOKEN.vault mismatch"
        );
    }

    function _checkSpellCannotBeCastedSecondTime() internal {
        address root = address(spell.V2_ROOT());

        assertTrue(spell.done(), "Spell should be marked as done");
        vm.expectRevert("spell-already-cast");
        vm.prank(root);
        spell.cast();
    }

    function _checkSpellAccessIsCleared() internal view {
        address spellAddr = address(spell);
        _checkWard(address(spell.V2_ROOT()), spellAddr, 0);
        _checkWard(address(spell.JTRSY_SHARE_TOKEN()), spellAddr, 0);
        _checkWard(address(spell.JAAA_SHARE_TOKEN()), spellAddr, 0);
    }

    function _checkWard(address where, address who, uint256 status) internal view {
        assertEq(
            IAuth(where).wards(who),
            status,
            string(abi.encodePacked("Ward check failed for ", vm.toString(who), " on ", vm.toString(where)))
        );
    }
}

contract RelinkV2TestAsyncDepositFlow is RelinkV2TestBase {
    using CastLib for *;

    // address poolAdmin = 0x742d100011fFbC6e509E39DbcB0334159e86be1e;
    // uint128 depositAmount = 1e12;

    // function test_completeAsyncDepositFlow() public {
    //     address investor = makeAddr("INVESTOR_A");

    //     castSpell();

    //     IAsyncVault vault = IAsyncVault(VAULT_1);
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     IShareToken shareToken = SPOKE.shareToken(poolId, scId);

    //     deal(vault.asset(), investor, depositAmount);
    //     _addPoolMember(vault, investor);

    //     vm.startPrank(investor);
    //     IERC20(vault.asset()).approve(address(vault), depositAmount);
    //     vault.requestDeposit(depositAmount, investor, investor);
    //     vm.stopPrank();

    //     assertEq(
    //         newAsyncRequestManager.pendingDepositRequest(IBaseVault(address(vault)), investor),
    //         depositAmount,
    //         "Deposit request not recorded with new manager"
    //     );

    //     _poolAdminApproveDeposits(vault, depositAmount);

    //     _poolAdminIssueShares(vault);

    //     _notifyDepositCompletion(vault, investor);

    //     uint256 sharesBefore = shareToken.balanceOf(investor);

    //     vm.startPrank(investor);
    //     uint256 maxMintable = vault.maxMint(investor);
    //     assertGt(maxMintable, 0, "Max mintable shares should be greater than 0");
    //     vault.mint(maxMintable, investor);
    //     vm.stopPrank();

    //     uint256 sharesAfter = shareToken.balanceOf(investor);
    //     assertGt(sharesAfter, sharesBefore, "User should have received shares");
    // }

    // //----------------------------------------------------------------------------------------------
    // // Helpers
    // //----------------------------------------------------------------------------------------------

    // function _poolAdminApproveDeposits(IAsyncVault vault, uint128 amount) internal {
    //     PoolId poolId = vault.poolId();
    //     AssetId assetId = SPOKE.assetToId(vault.asset(), 0);

    //     bool isManager = HUB_REGISTRY.manager(poolId, poolAdmin);
    //     assertTrue(isManager, "Pool admin should have manager permissions");

    //     vm.startPrank(poolAdmin);
    //     vm.deal(poolAdmin, 1 ether);

    //     uint32 epochId = SCM.nowDepositEpoch(vault.scId(), assetId);
    //     HUB.approveDeposits{value: 0.1 ether}(poolId, vault.scId(), assetId, epochId, amount);

    //     vm.stopPrank();
    // }

    // function _poolAdminIssueShares(IAsyncVault vault) internal {
    //     PoolId poolId = vault.poolId();
    //     AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
    //     ShareClassId scId = vault.scId();

    //     vm.startPrank(poolAdmin);
    //     vm.deal(poolAdmin, 1 ether);

    //     uint32 issueEpochId = SCM.nowIssueEpoch(scId, assetId);
    //     D18 sharePrice = D18.wrap(1e18);

    //     (uint128 issuedShares,,) =
    //         HUB.issueShares{value: 0.1 ether}(poolId, scId, assetId, issueEpochId, sharePrice, 50000); // 50k gas for
    // hook
    //     assertGt(issuedShares, 0, "No shares issued");

    //     vm.stopPrank();
    // }

    // function _notifyDepositCompletion(IAsyncVault vault, address investor) internal {
    //     PoolId poolId = vault.poolId();
    //     AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
    //     ShareClassId scId = vault.scId();

    //     address anyCaller = makeAddr("ANY_CALLER");
    //     vm.deal(anyCaller, 1 ether);

    //     uint32 maxClaims = SCM.maxDepositClaims(scId, investor.toBytes32(), assetId);
    //     vm.startPrank(anyCaller);
    //     HUB.notifyDeposit{value: 0.1 ether}(poolId, scId, assetId, investor.toBytes32(), maxClaims);
    //     vm.stopPrank();
    // }

    // function _userClaimsShares(IAsyncVault vault, address investor) internal {
    //     vm.startPrank(investor);

    //     uint256 maxMintable = vault.maxMint(investor);
    //     assertGt(maxMintable, 0, "No shares available to mint");

    //     vault.mint(maxMintable, investor);

    //     vm.stopPrank();
    // }

    // function _addPoolMember(IAsyncVault vault, address user) internal {
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();

    //     UpdateRestrictionMessageLib.UpdateRestrictionMember memory memberUpdate = UpdateRestrictionMessageLib
    //         .UpdateRestrictionMember({user: bytes32(bytes20(user)), validUntil: type(uint64).max});
    //     bytes memory payload = UpdateRestrictionMessageLib.serialize(memberUpdate);

    //     // Short cut message from hub by temporarily adding this test as spoke ward
    //     bytes32 spokeWardSlot = keccak256(abi.encode(address(this), uint256(0)));
    //     vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(1)));
    //     ISpokeGatewayHandler(address(SPOKE)).updateRestriction(poolId, scId, payload);

    //     // Remove temporary spoke ward
    //     vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(0)));
    // }
}
