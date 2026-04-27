// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";

import {FlashLoanHelper} from "../../../../src/managers/spoke/FlashLoanHelper.sol";
import {IOnchainPM} from "../../../../src/managers/spoke/interfaces/IOnchainPM.sol";
import {IFlashLoanHelper} from "../../../../src/managers/spoke/interfaces/IFlashLoanHelper.sol";
import {IOnchainPMFactory} from "../../../../src/managers/spoke/interfaces/IOnchainPMFactory.sol";
import {IAaveV3Pool, IAaveV3FlashLoanReceiver} from "../../../../src/managers/spoke/interfaces/IAaveV3Pool.sol";

import "forge-std/Test.sol";

// ─── Mock ERC20 ──────────────────────────────────────────────────────────────

contract MockToken {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─── Mock Aave V3 Pool ──────────────────────────────────────────────────────

contract MockAavePool {
    uint256 public premium = 9; // 0.09% premium (9 bps, Aave default)

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    )
        external
    {
        // Transfer tokens to receiver
        MockToken(asset).transfer(receiverAddress, amount);

        // Call executeOperation on receiver
        uint256 fee = amount * premium / 10_000;
        bool success =
            IAaveV3FlashLoanReceiver(receiverAddress).executeOperation(asset, amount, fee, receiverAddress, params);
        require(success, "Flash loan failed");

        // Pull repayment
        MockToken(asset).transferFrom(receiverAddress, address(this), amount + fee);
    }
}

// ─── FlashLoanHelper Tests ─────────────────────────────────────────────────

contract FlashLoanHelperTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);

    FlashLoanHelper receiver;
    MockAavePool pool;
    MockToken token;
    address factory;

    function setUp() public {
        factory = makeAddr("factory");
        receiver = new FlashLoanHelper(IOnchainPMFactory(factory));
        pool = new MockAavePool();
        token = new MockToken();
    }

    function _mockFactory(address onchainPM) internal {
        PoolId poolId = MockOnchainPM(onchainPM).poolId();
        vm.mockCall(
            factory, abi.encodeWithSelector(IOnchainPMFactory.getAddress.selector, poolId), abi.encode(onchainPM)
        );
    }

    function testExecuteOperationRevertsNotPool() public {
        vm.expectRevert(IFlashLoanHelper.NotPool.selector);
        receiver.executeOperation(address(token), 100, 1, address(receiver), "");
    }

    function testExecuteOperationRevertsNotInitiator() public {
        WrongInitiatorPool wrongPool = new WrongInitiatorPool();
        MockOnchainPM mockPM = new MockOnchainPM(POOL_A, address(token), address(receiver), 0);
        _mockFactory(address(mockPM));

        vm.prank(address(mockPM));
        vm.expectRevert(IFlashLoanHelper.NotInitiator.selector);
        receiver.requestFlashLoan(IAaveV3Pool(address(wrongPool)), address(token), 100, IOnchainPM(address(mockPM)), "");
    }

    function testRequestFlashLoanRevertsNotOnchainPM() public {
        MockOnchainPM mockPM = new MockOnchainPM(POOL_A, address(token), address(receiver), 0);
        _mockFactory(address(mockPM));

        // Call from address that is not the onchainPM
        vm.expectRevert(IFlashLoanHelper.NotOnchainPM.selector);
        receiver.requestFlashLoan(IAaveV3Pool(address(pool)), address(token), 0, IOnchainPM(address(mockPM)), "");
    }

    function testRequestFlashLoanRevertsNotAuthorized() public {
        MockOnchainPM mockPM = new MockOnchainPM(POOL_A, address(token), address(receiver), 0);

        // Factory returns a different address — mockPM is not factory-deployed
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IOnchainPMFactory.getAddress.selector, POOL_A),
            abi.encode(makeAddr("other"))
        );

        vm.prank(address(mockPM));
        vm.expectRevert(IFlashLoanHelper.NotAuthorized.selector);
        receiver.requestFlashLoan(IAaveV3Pool(address(pool)), address(token), 0, IOnchainPM(address(mockPM)), "");
    }

    function testRequestFlashLoanRevertsAlreadyActive() public {
        MockOnchainPM mockPM = new MockOnchainPM(POOL_A, address(token), address(receiver), 0);
        _mockFactory(address(mockPM));
        ReentrantPool reentrantPool = new ReentrantPool(receiver, mockPM);

        vm.prank(address(mockPM));
        vm.expectRevert(IFlashLoanHelper.AlreadyActive.selector);
        receiver.requestFlashLoan(
            IAaveV3Pool(address(reentrantPool)), address(token), 0, IOnchainPM(address(mockPM)), ""
        );
    }

    function testFullFlashLoanFlow() public {
        uint256 loanAmount = 1000e18;
        uint256 fee = loanAmount * 9 / 10_000; // 0.09%

        token.mint(address(pool), loanAmount);

        MockOnchainPM mockPM = new MockOnchainPM(POOL_A, address(token), address(receiver), loanAmount + fee);
        token.mint(address(mockPM), loanAmount + fee);
        _mockFactory(address(mockPM));

        bytes memory callbackData = abi.encode(new bytes32[](0), new bytes[](0), uint128(0));

        vm.prank(address(mockPM));
        receiver.requestFlashLoan(
            IAaveV3Pool(address(pool)), address(token), loanAmount, IOnchainPM(address(mockPM)), callbackData
        );

        assertEq(token.balanceOf(address(pool)), loanAmount + fee);
    }
}

// ─── Helper mock contracts ──────────────────────────────────────────────────

contract WrongInitiatorPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    )
        external
    {
        // Call with wrong initiator (address(0x1) instead of receiverAddress)
        IAaveV3FlashLoanReceiver(receiverAddress).executeOperation(asset, amount, 0, address(0x1), params);
    }
}

/// @dev Attempts to re-enter requestFlashLoan during the flash loan callback, triggering AlreadyActive.
///      AlreadyActive is the first check, so it fires regardless of who the caller is.
contract ReentrantPool {
    FlashLoanHelper immutable helper;
    MockOnchainPM immutable onchainPM;

    constructor(FlashLoanHelper helper_, MockOnchainPM onchainPM_) {
        helper = helper_;
        onchainPM = onchainPM_;
    }

    function flashLoanSimple(address, address asset, uint256, bytes calldata, uint16) external {
        // Re-enter requestFlashLoan — _pool is already set so AlreadyActive fires first,
        // before the msg.sender == onchainPM check.
        helper.requestFlashLoan(IAaveV3Pool(address(this)), asset, 0, IOnchainPM(address(onchainPM)), "");
    }
}

contract MockOnchainPM {
    PoolId public poolId;
    address public token;
    address public recipient;
    uint256 public amount;

    constructor(PoolId poolId_, address token_, address recipient_, uint256 amount_) {
        poolId = poolId_;
        token = token_;
        recipient = recipient_;
        amount = amount_;
    }

    function executeCallback(bytes32[] calldata, bytes[] calldata, uint128) external {
        // Simulate inner script: transfer tokens back to the receiver for repayment
        MockToken(token).transfer(recipient, amount);
    }
}
