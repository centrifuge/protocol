// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IERC6909ExclOperator} from "../../../../src/misc/interfaces/IERC6909.sol";

import {UpdateRestrictionMessageLib} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OnOffRampFactory} from "../../../../src/managers/spoke/OnOffRamp.sol";
import {IOnOffRamp} from "../../../../src/managers/spoke/interfaces/IOnOffRamp.sol";
import {IAccountingToken} from "../../../../src/managers/spoke/interfaces/IAccountingToken.sol";

import {AssetId, VaultBaseTest as BaseTest, ShareClassId, shareClassSalt} from "../../vaults/VaultBaseTest.sol";

import {IShareTokenRegistrar} from "../../../../src/token/interfaces/IShareTokenRegistrar.sol";

abstract contract OnOffRampBaseTest is BaseTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    IAccountingToken mockAccountingToken = IAccountingToken(makeAddr("accountingToken"));

    OnOffRampFactory factory;
    IOnOffRamp manager;

    address relayer = makeAddr("relayer");
    address receiver = makeAddr("receiver");

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePoolPerShare = d18(1, 1);
        defaultPricePoolPerAsset = d18(1, 1);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = spoke.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId, address(this));
        if (!spokeRegistry.isPoolActive(POOL_A)) spokeHandler.addPool(POOL_A);
        spokeHandler.addShareClass(
            POOL_A,
            defaultTypedShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            shareClassSalt(POOL_A.raw(), defaultShareClassId),
            shareTokenRegistrar,
            ""
        );
        vm.prank(shareTokenRegistrar.envoy());
        shareTokenRegistrar.fromHub(
            POOL_A,
            abi.encode(
                uint8(IShareTokenRegistrar.RegistrarCall.SetHook),
                defaultTypedShareClassId.raw(),
                address(fullRestrictionsHook)
            )
        );
        spokeHandler.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spokeHandler.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spokeHandler.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                    user: address(this).toBytes32(), validUntil: MAX_UINT64
                }).serialize()
        );

        // Mock accountingToken calls used by OnOffRamp.deposit() and withdraw()
        vm.mockCall(
            address(mockAccountingToken),
            abi.encodeWithSelector(IAccountingToken.toTokenId.selector),
            abi.encode(uint256(1))
        );
        vm.mockCall(address(mockAccountingToken), abi.encodeWithSelector(IAccountingToken.mint.selector), abi.encode());
        vm.mockCall(
            address(mockAccountingToken),
            abi.encodeWithSelector(IERC6909ExclOperator.approve.selector),
            abi.encode(true)
        );

        // Mock the BalanceSheet deposit for the accounting token (so it doesn't try to register the asset)
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(
                spoke.deposit.selector, POOL_A, defaultTypedShareClassId, address(mockAccountingToken)
            ),
            abi.encode()
        );

        factory = new OnOffRampFactory(address(envoy), spoke, mockAccountingToken);
        manager = factory.newManager(POOL_A, defaultTypedShareClassId);
    }

    function _depositIntoBalanceSheet(uint128 amount) internal {
        erc20.mint(address(this), amount);
        erc20.approve(address(spoke), amount);
        spoke.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, amount);
    }
}

contract OnOffRampIntegrationTest is OnOffRampBaseTest {
    using CastLib for *;

    function testPreviewManagerMatchesDeployedAddress() public view {
        assertEq(factory.previewManager(POOL_A, defaultTypedShareClassId), address(manager));
    }

    function testDepositAndWithdrawHappyPath() public {
        uint128 amount = 100;

        // Enable onramp
        vm.prank(address(envoy));
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), defaultAssetId, true));

        // Enable relayer
        vm.prank(address(envoy));
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Relayer), relayer.toBytes32(), true));

        // Enable offramp destination
        vm.prank(address(envoy));
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Offramp), defaultAssetId, receiver.toBytes32(), true)
        );

        // Set manager permissions
        spokeRegistry.updateManager(POOL_A, address(manager), true);

        // Mint tokens to manager
        erc20.mint(address(manager), amount);

        // Verify initial state
        assertEq(erc20.balanceOf(address(manager)), amount);
        assertEq(spoke.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);
        assertEq(erc20.balanceOf(receiver), 0);

        // Execute deposit
        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));

        // Verify deposit state changes
        assertEq(erc20.balanceOf(address(manager)), 0);
        assertEq(spoke.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), amount);

        // Execute withdraw
        vm.prank(relayer);
        manager.withdraw(address(erc20), erc20TokenId, amount, receiver);

        // Verify withdraw state changes
        assertEq(spoke.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);
        assertEq(erc20.balanceOf(receiver), amount);
    }
}
