// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../../src/misc/interfaces/IERC165.sol";
import {IEscrow} from "../../../../src/misc/interfaces/IEscrow.sol";
import {IERC7751} from "../../../../src/misc/interfaces/IERC7751.sol";
import {IERC6909ExclOperator} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {OnOffRampFactory} from "../../../../src/managers/spoke/OnOffRamp.sol";
import {IOnOffRamp} from "../../../../src/managers/spoke/interfaces/IOnOffRamp.sol";
import {IAccountingToken} from "../../../../src/managers/spoke/interfaces/IAccountingToken.sol";
import {IDepositManager, IWithdrawManager} from "../../../../src/managers/spoke/interfaces/IBalanceSheetManager.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract OnOffRampTest is Test {
    using CastLib for *;

    ISpoke spoke = ISpoke(address(new IsContract()));
    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));
    IERC20 erc20 = IERC20(address(new IsContract()));
    IAccountingToken accountingToken = IAccountingToken(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2); // For invalid pool tests
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    AssetId constant ASSET_ID = AssetId.wrap(100);
    uint128 constant DEFAULT_AMOUNT = 100;
    uint128 constant DEFAULT_ASSET_ID = 100;
    uint256 constant ERC20_TOKEN_ID = 0;

    // Selector for the BalanceSheet withdraw function
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint64,bytes16,address,uint256,address,uint128)"));

    address envoy = makeAddr("envoy");
    address relayer = makeAddr("relayer");
    address receiver = makeAddr("receiver");

    OnOffRampFactory factory;
    IOnOffRamp manager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {
        // Mock spoke.spoke() to return our spoke mock
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));

        // Mock spokeRegistry.idToAsset() to return asset address and tokenId
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), ASSET_ID),
            abi.encode(address(erc20), ERC20_TOKEN_ID)
        );

        // Mock ERC20 functions
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.balanceOf.selector, address(manager)), abi.encode(0));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        // Mock accountingToken functions
        vm.mockCall(
            address(accountingToken),
            abi.encodeWithSelector(IAccountingToken.toTokenId.selector),
            abi.encode(uint256(1))
        );
        vm.mockCall(address(accountingToken), abi.encodeWithSelector(IAccountingToken.mint.selector), abi.encode());
        vm.mockCall(
            address(accountingToken), abi.encodeWithSelector(IERC6909ExclOperator.approve.selector), abi.encode(true)
        );
    }

    function _deployManager() internal {
        factory = new OnOffRampFactory(envoy, spoke, accountingToken);

        // Mock spoke.spokeRegistry().hasShareClass() so the factory's existence check passes
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.hasShareClass.selector, POOL_A, SC_1),
            abi.encode(true)
        );

        manager = factory.newManager(POOL_A, SC_1);

        // Update the mock to return the actual manager address for balance checks
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.balanceOf.selector, address(manager)), abi.encode(0));
    }

    function _mockBalanceSheetDeposit(uint128 amount, bool shouldRevert, bytes memory revertData) internal {
        bytes memory callData =
            abi.encodeWithSelector(ISpoke.deposit.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, amount);

        if (shouldRevert) {
            vm.mockCallRevert(address(spoke), callData, revertData);
        } else {
            vm.mockCall(address(spoke), callData, abi.encode());
        }

        // Mock the accounting token deposit to BalanceSheet (liability token)
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.deposit.selector, POOL_A, SC_1, address(accountingToken)),
            abi.encode()
        );
    }

    function _mockBalanceSheetWithdraw(uint128 amount, address receiver_, bool shouldRevert, bytes memory revertData)
        internal
    {
        bytes memory callData =
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver_, amount);

        if (shouldRevert) {
            vm.mockCallRevert(address(spoke), callData, revertData);
        } else {
            vm.mockCall(address(spoke), callData, abi.encode());
        }

        // Mock the accounting token deposit to BalanceSheet (non-liability token)
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.deposit.selector, POOL_A, SC_1, address(accountingToken)),
            abi.encode()
        );
    }

    function _mockManagerPermissions(bool isManager) internal {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.manager.selector, POOL_A, address(manager)),
            abi.encode(isManager)
        );
    }

    function _enableOnramp() internal {
        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), DEFAULT_ASSET_ID, true));
    }

    function _enableRelayer(address relayer_) internal {
        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Relayer), relayer_.toBytes32(), true));
    }

    function _enableOfframp(address receiver_) internal {
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Offramp), DEFAULT_ASSET_ID, receiver_.toBytes32(), true)
        );
    }

    function _disableOfframp(address receiver_) internal {
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Offramp), DEFAULT_ASSET_ID, receiver_.toBytes32(), false)
        );
    }
}

contract OnOffRampUpdateContractFailureTests is OnOffRampTest {
    using CastLib for *;

    function testInvalidSource(address notContractUpdater) public {
        vm.assume(notContractUpdater != envoy);

        vm.expectRevert(IOnOffRamp.NotEnvoy.selector);
        vm.prank(notContractUpdater);
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), DEFAULT_ASSET_ID, true));
    }

    function testInvalidPool() public {
        vm.expectRevert(IOnOffRamp.InvalidPoolId.selector);
        vm.prank(envoy);
        manager.fromHub(POOL_B, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), DEFAULT_ASSET_ID, true));
    }

    function testERC6909NotSupportedOnramp() public {
        // Mock spokeRegistry.idToAsset() to return non-zero tokenId
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), ASSET_ID),
            abi.encode(address(erc20), 1)
        );

        vm.expectRevert(IOnOffRamp.ERC6909NotSupported.selector);
        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), DEFAULT_ASSET_ID, true));
    }

    function testERC6909NotSupportedOfframp() public {
        // Mock spokeRegistry.idToAsset() to return non-zero tokenId for offramp
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), ASSET_ID),
            abi.encode(address(erc20), 1)
        );

        vm.expectRevert(IOnOffRamp.ERC6909NotSupported.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Offramp), DEFAULT_ASSET_ID, receiver.toBytes32(), true)
        );
    }

    function testUnknownTrustedCall() public {
        vm.expectRevert(IOnOffRamp.UnknownTrustedCall.selector);
        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(99), DEFAULT_ASSET_ID, bytes32(""), true));
    }
}

contract OnOffRampDepositFailureTests is OnOffRampTest {
    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOffRamp.NotAllowedOnrampAsset.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testNotManager(uint128 amount) public {
        _enableOnramp();
        _mockManagerPermissions(false);
        _mockBalanceSheetDeposit(amount, true, abi.encodeWithSelector(IAuth.NotAuthorized.selector));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testInsufficientBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOnramp();
        _mockManagerPermissions(true);
        bytes memory wrappedErrorData = abi.encode("insufficient balance");
        _mockBalanceSheetDeposit(amount, true, abi.encodeWithSelector(IERC7751.WrappedError.selector, wrappedErrorData));

        // Expect any revert for wrapped errors
        vm.expectRevert();
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }
}

contract OnOffRampDepositSuccessTests is OnOffRampTest {
    function testDeposit(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOnramp();
        _mockManagerPermissions(true);
        _mockBalanceSheetDeposit(amount, false, "");

        // Mock initial balance
        vm.mockCall(
            address(erc20), abi.encodeWithSelector(IERC20.balanceOf.selector, address(manager)), abi.encode(amount)
        );
        assertEq(erc20.balanceOf(address(manager)), amount);

        // Expect balance sheet deposit to be called with correct parameters
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.deposit.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, amount)
        );

        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testOnrampDisable() public {
        _enableOnramp();

        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp), DEFAULT_ASSET_ID, false));

        vm.expectRevert(IOnOffRamp.NotAllowedOnrampAsset.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, 100, address(manager));
    }
}

contract OnOffRampWithdrawFailureTests is OnOffRampTest {
    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOffRamp.NotRelayer.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, address(this));
    }

    function testZeroAddressReceiver(uint128 amount) public {
        _enableRelayer(relayer);

        vm.prank(relayer);
        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, address(0));
    }

    function testInvalidDestination(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableRelayer(relayer);
        _mockManagerPermissions(true);

        vm.prank(relayer);
        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testDisabledDestination(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableRelayer(relayer);
        _disableOfframp(receiver);
        _mockManagerPermissions(true);

        vm.prank(relayer);
        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testNotManager(uint128 amount) public {
        _enableRelayer(relayer);
        _enableOfframp(receiver);
        _mockManagerPermissions(false);
        _mockBalanceSheetWithdraw(amount, receiver, true, abi.encodeWithSelector(IAuth.NotAuthorized.selector));

        vm.prank(relayer);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testInsufficientBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);
        _enableRelayer(relayer);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, true, abi.encodeWithSelector(IEscrow.InsufficientBalance.selector));

        vm.prank(relayer);
        // Expect any revert for insufficient balance
        vm.expectRevert();
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }
}

contract OnOffRampWithdrawSuccessTests is OnOffRampTest {
    function testWithdraw(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);
        _enableRelayer(relayer);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, false, "");

        // Expect balance sheet withdraw to be called with correct parameters
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver, amount)
        );

        vm.prank(relayer);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }
}

contract OnOffRampTrustedWithdrawFailureTests is OnOffRampTest {
    using CastLib for *;

    function testWithdrawTrustedCallZeroAddressReceiver(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, bytes32(0))
        );
    }

    function testWithdrawTrustedCallInvalidDestination(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        // Don't enable offramp for receiver
        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallDisabledDestination(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        // Enable then disable offramp
        _enableOfframp(receiver);
        _disableOfframp(receiver);

        vm.expectRevert(IOnOffRamp.InvalidOfframpDestination.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallNotContractUpdater(uint128 amount, address notContractUpdater) public {
        vm.assume(notContractUpdater != envoy);
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);

        vm.expectRevert(IOnOffRamp.NotEnvoy.selector);
        vm.prank(notContractUpdater);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallInvalidPoolId(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);

        vm.expectRevert(IOnOffRamp.InvalidPoolId.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_B, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallNotManager(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);
        _mockManagerPermissions(false);
        _mockBalanceSheetWithdraw(amount, receiver, true, abi.encodeWithSelector(IAuth.NotAuthorized.selector));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallInsufficientBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, true, abi.encodeWithSelector(IEscrow.InsufficientBalance.selector));

        vm.expectRevert(IEscrow.InsufficientBalance.selector);
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }
}

contract OnOffRampTrustedWithdrawSuccessTests is OnOffRampTest {
    using CastLib for *;

    function testWithdrawTrustedCall(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));

        _enableOfframp(receiver);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, false, "");

        // Expect balance sheet withdraw to be called with correct parameters
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver, amount)
        );

        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallMultipleReceivers(uint128 amount1, uint128 amount2) public {
        amount1 = uint128(bound(amount1, 1, type(uint128).max / 2));
        amount2 = uint128(bound(amount2, 1, type(uint128).max / 2));

        address receiver2 = makeAddr("receiver2");

        _enableOfframp(receiver);
        _enableOfframp(receiver2);
        _mockManagerPermissions(true);

        // First withdrawal to receiver
        _mockBalanceSheetWithdraw(amount1, receiver, false, "");
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver, amount1)
        );

        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount1, receiver.toBytes32())
        );

        // Second withdrawal to receiver2
        _mockBalanceSheetWithdraw(amount2, receiver2, false, "");
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver2, amount2)
        );

        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount2, receiver2.toBytes32())
        );
    }

    function testWithdrawTrustedCallDoesNotRequireRelayer() public {
        uint128 amount = 100;

        // Enable offramp but NOT relayer
        _enableOfframp(receiver);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, false, "");

        // Should succeed without enabling relayer (since this is a trusted call)
        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }

    function testWithdrawTrustedCallZeroAmount() public {
        uint128 amount = 0;

        _enableOfframp(receiver);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, false, "");

        // Should allow zero amount withdrawal
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(WITHDRAW_SELECTOR, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver, amount)
        );

        vm.prank(envoy);
        manager.fromHub(
            POOL_A, abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw), DEFAULT_ASSET_ID, amount, receiver.toBytes32())
        );
    }
}

contract OnOffRampERC165Tests is OnOffRampTest {
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 depositManager = 0xc864037c;
        bytes4 withdrawManager = 0x3e55212a;

        vm.assume(
            unsupportedInterfaceId != erc165 && unsupportedInterfaceId != depositManager
                && unsupportedInterfaceId != withdrawManager
        );

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IDepositManager).interfaceId, depositManager);
        assertEq(type(IWithdrawManager).interfaceId, withdrawManager);

        assertEq(manager.supportsInterface(erc165), true);
        assertEq(manager.supportsInterface(depositManager), true);
        assertEq(manager.supportsInterface(withdrawManager), true);

        assertEq(manager.supportsInterface(unsupportedInterfaceId), false);
    }
}
