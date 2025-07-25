// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RelinkV2Eth, VaultLike, AxelarAdapterLike, InvestmentManagerLike} from "./RelinkV2Eth.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

import {
    UpdateRestrictionType,
    UpdateRestrictionMessageLib
} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

interface IERC7540Vault {
    function poolId() external view returns (uint64);
    function trancheId() external view returns (bytes16);
    function share() external view returns (address shareTokenAddress);
    function asset() external view returns (address assetTokenAddress);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 pendingAssets);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
}

contract RelinkV2TestBase is Test {
    uint256 public constant REQUEST_ID = 0;

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
    uint256 preJaaaTotalSupply;

    // Main integration test
    function testSpellIntegration() public {
        preJaaaTotalSupply = spell.JAAA_SHARE_TOKEN().totalSupply();

        castSpell();

        _checkLinkedVaults();
        _checkManagers();
        _checkShareBalances();
        _checkInvestmentState();
        _checkMembershipState();
        _checkAxelarTransactionCannotBeReexecuted();
        _checkSpellCannotBeCastedSecondTime();
        _checkSpellAccessIsCleared();
    }

    function _checkLinkedVaults() internal view {
        assertEq(spell.JTRSY_SHARE_TOKEN().vault(spell.USDC_TOKEN()), spell.JTRSY_VAULT_ADDRESS());
        assertEq(spell.JAAA_SHARE_TOKEN().vault(spell.USDC_TOKEN()), spell.JAAA_VAULT_ADDRESS());
    }

    function _checkManagers() internal view {
        assertEq(VaultLike(spell.JTRSY_VAULT_ADDRESS()).manager(), address(spell.V2_INVESTMENT_MANAGER()));
        assertEq(VaultLike(spell.JAAA_VAULT_ADDRESS()).manager(), address(spell.V2_INVESTMENT_MANAGER()));
    }

    function _checkShareBalances() internal view {
        uint256 postJaaaTotalSupply = spell.JAAA_SHARE_TOKEN().totalSupply();
        assertEq(preJaaaTotalSupply, postJaaaTotalSupply);

        assertEq(spell.JAAA_SHARE_TOKEN().balanceOf(spell.INVESTOR()), 50_000_000e6);
        assertEq(spell.JAAA_SHARE_TOKEN().balanceOf(address(spell)), 0);
    }

    function _checkInvestmentState() internal view {
        VaultLike vault = VaultLike(spell.JAAA_VAULT_ADDRESS());
        assertEq(vault.pendingDepositRequest(REQUEST_ID, spell.INVESTOR()), 0);
        assertEq(vault.claimableDepositRequest(REQUEST_ID, spell.INVESTOR()), 0);
    }

    function _checkMembershipState() internal {
        (bool isValid,) = spell.V2_RESTRICTION_MANAGER().isMember(address(spell.JAAA_SHARE_TOKEN()), address(spell));
        assertEq(isValid, true);

        vm.warp(block.timestamp + 1);
        (isValid,) = spell.V2_RESTRICTION_MANAGER().isMember(address(spell.JAAA_SHARE_TOKEN()), address(spell));
        assertEq(isValid, false);
    }

    function _checkAxelarTransactionCannotBeReexecuted() internal {
        AxelarAdapterLike adapter = spell.V2_AXELAR_ADAPTER();
        bytes32 commandId = spell.COMMAND_ID();
        string memory sourceChain = spell.SOURCE_CHAIN();
        string memory sourceAddr = spell.SOURCE_ADDR();
        bytes memory payload = spell.PAYLOAD();

        vm.expectRevert("AxelarAdapter/not-approved-by-axelar-gateway");
        adapter.execute(commandId, sourceChain, sourceAddr, payload);
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
        _checkWard(address(spell.V2_INVESTMENT_MANAGER()), spellAddr, 0);
        _checkWard(address(spell.V2_RESTRICTION_MANAGER()), spellAddr, 0);
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

    address poolAdmin = 0x742d100011fFbC6e509E39DbcB0334159e86be1e;

    function test_completeAsyncDepositFlow() public {
        castSpell();

        _completeAsyncDepositFlow(spell.JTRSY_VAULT_ADDRESS(), spell.INVESTOR(), 100_000e6);
        _completeAsyncDepositFlow(spell.JAAA_VAULT_ADDRESS(), spell.INVESTOR(), 100_000e6);
    }

    function _completeAsyncDepositFlow(address vault_, address investor, uint128 depositAmount) internal {
        IERC7540Vault vault = IERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        uint128 assetId = spell.USDC_ASSET_ID();
        IShareToken shareToken = IShareToken(address(vault.share()));

        InvestmentManagerLike investmentManager = spell.V2_INVESTMENT_MANAGER();

        deal(vault.asset(), investor, depositAmount);

        vm.startPrank(investor);
        IERC20(vault.asset()).approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, investor, investor);
        vm.stopPrank();

        assertEq(
            vault.pendingDepositRequest(REQUEST_ID, investor),
            depositAmount,
            "Deposit request not recorded with new manager"
        );

        vm.startPrank(address(spell.V2_ROOT()));
        investmentManager.fulfillDepositRequest(poolId, trancheId, investor, assetId, depositAmount, depositAmount);
        vm.stopPrank();

        uint256 sharesBefore = shareToken.balanceOf(investor);

        vm.startPrank(investor);
        uint256 maxMintable = vault.maxMint(investor);
        assertGt(maxMintable, 0, "Max mintable shares should be greater than 0");
        vault.mint(maxMintable, investor);
        vm.stopPrank();

        uint256 sharesAfter = shareToken.balanceOf(investor);
        assertGt(sharesAfter, sharesBefore, "User should have received shares");
    }
}
