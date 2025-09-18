// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../../src/misc/interfaces/IERC165.sol";
import {IEscrow} from "../../../../src/misc/interfaces/IEscrow.sol";
import {IERC7751} from "../../../../src/misc/interfaces/IERC7751.sol";

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";

import {ISpoke} from "../../../../src/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "../../../../src/spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../../../../src/spoke/interfaces/IUpdateContract.sol";
import {UpdateContractMessageLib} from "../../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {OnOfframpManagerFactory} from "../../../../src/managers/spoke/OnOfframpManager.sol";
import {IOnOfframpManager} from "../../../../src/managers/spoke/interfaces/IOnOfframpManager.sol";
import {IDepositManager, IWithdrawManager} from "../../../../src/managers/spoke/interfaces/IBalanceSheetManager.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract OnOfframpManagerTest is Test {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    IBalanceSheet balanceSheet = IBalanceSheet(address(new IsContract()));
    ISpoke spoke = ISpoke(address(new IsContract()));
    IERC20 erc20 = IERC20(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2); // For invalid pool tests
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    AssetId constant ASSET_ID = AssetId.wrap(100);
    uint128 constant DEFAULT_AMOUNT = 100;
    uint128 constant DEFAULT_ASSET_ID = 100;
    uint256 constant ERC20_TOKEN_ID = 0;

    address contractUpdater = makeAddr("contractUpdater");
    address relayer = makeAddr("relayer");
    address receiver = makeAddr("receiver");

    OnOfframpManagerFactory factory;
    IOnOfframpManager manager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {
        // Mock balanceSheet.spoke() to return our spoke mock
        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        // Mock spoke.idToAsset() to return asset address and tokenId
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.idToAsset.selector, ASSET_ID),
            abi.encode(address(erc20), ERC20_TOKEN_ID)
        );

        // Mock ERC20 functions
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.balanceOf.selector, address(manager)), abi.encode(0));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
    }

    function _deployManager() internal {
        factory = new OnOfframpManagerFactory(contractUpdater, balanceSheet);

        // Mock balanceSheet.spoke().shareToken() to prevent revert during deployment
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.shareToken.selector, POOL_A, SC_1),
            abi.encode(address(new IsContract()))
        );

        manager = factory.newManager(POOL_A, SC_1);

        // Update the mock to return the actual manager address for balance checks
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20.balanceOf.selector, address(manager)), abi.encode(0));
    }

    function _mockBalanceSheetDeposit(uint128 amount, bool shouldRevert, bytes memory revertData) internal {
        bytes memory callData =
            abi.encodeWithSelector(IBalanceSheet.deposit.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, amount);

        if (shouldRevert) {
            vm.mockCallRevert(address(balanceSheet), callData, revertData);
        } else {
            vm.mockCall(address(balanceSheet), callData, abi.encode());
        }
    }

    function _mockBalanceSheetWithdraw(uint128 amount, address receiver_, bool shouldRevert, bytes memory revertData)
        internal
    {
        bytes memory callData = abi.encodeWithSelector(
            IBalanceSheet.withdraw.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver_, amount
        );

        if (shouldRevert) {
            vm.mockCallRevert(address(balanceSheet), callData, revertData);
        } else {
            vm.mockCall(address(balanceSheet), callData, abi.encode());
        }
    }

    function _mockManagerPermissions(bool isManager) internal {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.manager.selector, POOL_A, address(manager)),
            abi.encode(isManager)
        );

        // Also mock updateManager to not revert when called using function signature since not in interface
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSignature("updateManager(uint64,address,bool)", POOL_A.raw(), address(manager), isManager),
            abi.encode()
        );
    }

    function _enableOnramp() internal {
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function _enableRelayer(address relayer_) internal {
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("relayer"),
                    assetId: 0,
                    what: relayer_.toBytes32(),
                    isEnabled: true
                })
            )
        );
    }

    function _enableOfframp(address receiver_) internal {
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("offramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: receiver_.toBytes32(),
                    isEnabled: true
                })
            )
        );
    }

    function _disableOfframp(address receiver_) internal {
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("offramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: receiver_.toBytes32(),
                    isEnabled: false
                })
            )
        );
    }
}

contract OnOfframpManagerUpdateContractFailureTests is OnOfframpManagerTest {
    using CastLib for *;

    function testInvalidSource(address notContractUpdater) public {
        vm.assume(notContractUpdater != contractUpdater);

        vm.expectRevert(IOnOfframpManager.NotContractUpdater.selector);
        vm.prank(notContractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function testInvalidPool() public {
        vm.expectRevert(IOnOfframpManager.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        manager.update(
            POOL_B,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function testInvalidShareClass() public {
        ShareClassId wrongScId = ShareClassId.wrap(bytes16("wrong_sc"));

        vm.expectRevert(IOnOfframpManager.InvalidShareClassId.selector);
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            wrongScId,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function testERC6909NotSupportedOnramp() public {
        // Mock spoke.idToAsset() to return non-zero tokenId
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(ISpoke.idToAsset.selector, ASSET_ID), abi.encode(address(erc20), 1)
        );

        vm.expectRevert(IOnOfframpManager.ERC6909NotSupported.selector);
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function testERC6909NotSupportedOfframp() public {
        // Mock spoke.idToAsset() to return non-zero tokenId for offramp
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(ISpoke.idToAsset.selector, ASSET_ID), abi.encode(address(erc20), 1)
        );

        vm.expectRevert(IOnOfframpManager.ERC6909NotSupported.selector);
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("offramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: receiver.toBytes32(),
                    isEnabled: true
                })
            )
        );
    }

    function testUnknownUpdateContractKind() public {
        vm.expectRevert(IOnOfframpManager.UnknownUpdateContractKind.selector);
        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("unknown"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: true
                })
            )
        );
    }

    function testUnknownUpdateContractType() public {
        // Create payload with valid enum but unsupported type (Valuation instead of UpdateAddress)
        bytes memory invalidPayload = abi.encodePacked(uint8(1), bytes32("test"));

        vm.expectRevert(IUpdateContract.UnknownUpdateContractType.selector);
        vm.prank(contractUpdater);
        manager.update(POOL_A, SC_1, invalidPayload);
    }
}

contract OnOfframpManagerDepositFailureTests is OnOfframpManagerTest {
    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOfframpManager.NotAllowedOnrampAsset.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testNotBalanceSheetManager(uint128 amount) public {
        _enableOnramp();
        _mockManagerPermissions(false);
        _mockBalanceSheetDeposit(amount, true, abi.encodeWithSelector(IAuth.NotAuthorized.selector));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testInsufficientBalance(uint128 amount) public {
        vm.assume(amount > 0);

        _enableOnramp();
        _mockManagerPermissions(true);
        bytes memory wrappedErrorData = abi.encode("insufficient balance");
        _mockBalanceSheetDeposit(amount, true, abi.encodeWithSelector(IERC7751.WrappedError.selector, wrappedErrorData));

        // Expect any revert for wrapped errors
        vm.expectRevert();
        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }
}

contract OnOfframpManagerDepositSuccessTests is OnOfframpManagerTest {
    function testDeposit(uint128 amount) public {
        vm.assume(amount > 0);

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
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.deposit.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, amount)
        );

        manager.deposit(address(erc20), ERC20_TOKEN_ID, amount, address(manager));
    }

    function testOnrampDisable() public {
        _enableOnramp();

        vm.prank(contractUpdater);
        manager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.serialize(
                UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"),
                    assetId: DEFAULT_ASSET_ID,
                    what: bytes32(""),
                    isEnabled: false
                })
            )
        );

        vm.expectRevert(IOnOfframpManager.NotAllowedOnrampAsset.selector);
        manager.deposit(address(erc20), ERC20_TOKEN_ID, 100, address(manager));
    }
}

contract OnOfframpManagerWithdrawFailureTests is OnOfframpManagerTest {
    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOfframpManager.NotRelayer.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, address(this));
    }

    function testZeroAddressReceiver(uint128 amount) public {
        _enableRelayer(relayer);

        vm.prank(relayer);
        vm.expectRevert(IOnOfframpManager.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, address(0));
    }

    function testInvalidDestination(uint128 amount) public {
        vm.assume(amount > 0);

        _enableRelayer(relayer);
        _mockManagerPermissions(true);

        vm.prank(relayer);
        vm.expectRevert(IOnOfframpManager.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testDisabledDestination(uint128 amount) public {
        vm.assume(amount > 0);

        _enableRelayer(relayer);
        _disableOfframp(receiver);
        _mockManagerPermissions(true);

        vm.prank(relayer);
        vm.expectRevert(IOnOfframpManager.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testNotBalanceSheetManager(uint128 amount) public {
        _enableRelayer(relayer);
        _enableOfframp(receiver);
        _mockManagerPermissions(false);
        _mockBalanceSheetWithdraw(amount, receiver, true, abi.encodeWithSelector(IAuth.NotAuthorized.selector));

        vm.prank(relayer);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }

    function testInsufficientBalance(uint128 amount) public {
        vm.assume(amount > 0);

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

contract OnOfframpManagerWithdrawSuccessTests is OnOfframpManagerTest {
    function testWithdraw(uint128 amount) public {
        vm.assume(amount > 0);

        _enableOfframp(receiver);
        _enableRelayer(relayer);
        _mockManagerPermissions(true);
        _mockBalanceSheetWithdraw(amount, receiver, false, "");

        // Expect balance sheet withdraw to be called with correct parameters
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(
                IBalanceSheet.withdraw.selector, POOL_A, SC_1, address(erc20), ERC20_TOKEN_ID, receiver, amount
            )
        );

        vm.prank(relayer);
        manager.withdraw(address(erc20), ERC20_TOKEN_ID, amount, receiver);
    }
}

contract OnOfframpManagerERC165Tests is OnOfframpManagerTest {
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
