// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";
import {IERC6909ExclOperator, IERC6909MetadataExt} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {ReceiptToken} from "../../../../src/managers/spoke/ReceiptToken.sol";
import {IExecutor} from "../../../../src/managers/spoke/interfaces/IExecutor.sol";
import {IReceiptToken} from "../../../../src/managers/spoke/interfaces/IReceiptToken.sol";
import {IExecutorFactory} from "../../../../src/managers/spoke/interfaces/IExecutorFactory.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";

import "forge-std/Test.sol";

// ─── Base ────────────────────────────────────────────────────────────────────

contract ReceiptTokenTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address factoryAddr = makeAddr("factory");

    ReceiptToken token;

    address asset = makeAddr("asset");
    address user = makeAddr("user");
    address spender = makeAddr("spender");
    address receiver = makeAddr("receiver");

    uint256 tokenIdA;
    uint256 tokenIdB;
    address executorA = makeAddr("executorA");
    address executorB = makeAddr("executorB");

    function setUp() public virtual {
        token = new ReceiptToken(IExecutorFactory(factoryAddr));

        tokenIdA = token.toTokenId(POOL_A, asset);
        tokenIdB = token.toTokenId(POOL_B, asset);

        vm.mockCall(
            factoryAddr, abi.encodeWithSelector(IExecutorFactory.executors.selector, POOL_A), abi.encode(executorA)
        );
        vm.mockCall(
            factoryAddr, abi.encodeWithSelector(IExecutorFactory.executors.selector, POOL_B), abi.encode(executorB)
        );
    }

    function _mint(address to, uint256 id, uint256 amount) internal {
        vm.prank(PoolId.wrap(uint64(id >> 160)).raw() == POOL_A.raw() ? executorA : executorB);
        token.mint(to, id, amount);
    }
}

// ─── Constructor ─────────────────────────────────────────────────────────────

contract ReceiptTokenConstructorTest is ReceiptTokenTest {
    function testConstructor() public view {
        assertEq(address(token.factory()), factoryAddr);
    }
}

// ─── Access Control ──────────────────────────────────────────────────────────

contract ReceiptTokenAccessControlTest is ReceiptTokenTest {
    function testMintFromCorrectExecutor() public {
        vm.prank(executorA);
        token.mint(user, tokenIdA, 100e18);
        assertEq(token.balanceOf(user, tokenIdA), 100e18);
    }

    function testBurnFromCorrectExecutor() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(executorA);
        token.burn(user, tokenIdA, 50e18);
        assertEq(token.balanceOf(user, tokenIdA), 50e18);
    }

    function testMintFromWrongPoolExecutorReverts() public {
        // executorB cannot mint tokenIdA (belongs to pool A)
        vm.expectRevert(IReceiptToken.NotPoolExecutor.selector);
        vm.prank(executorB);
        token.mint(user, tokenIdA, 100e18);
    }

    function testBurnFromWrongPoolExecutorReverts() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectRevert(IReceiptToken.NotPoolExecutor.selector);
        vm.prank(executorB);
        token.burn(user, tokenIdA, 50e18);
    }

    function testMintFromRandomAddressReverts() public {
        vm.expectRevert(IReceiptToken.NotPoolExecutor.selector);
        vm.prank(user);
        token.mint(user, tokenIdA, 100e18);
    }

    function testBurnFromRandomAddressReverts() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectRevert(IReceiptToken.NotPoolExecutor.selector);
        vm.prank(user);
        token.burn(user, tokenIdA, 50e18);
    }
}

// ─── Mint / Burn ─────────────────────────────────────────────────────────────

contract ReceiptTokenMintBurnTest is ReceiptTokenTest {
    function testMintEmitsTransfer() public {
        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(executorA, address(0), user, tokenIdA, 100e18);

        vm.prank(executorA);
        token.mint(user, tokenIdA, 100e18);
    }

    function testMintAccumulates() public {
        _mint(user, tokenIdA, 100e18);
        _mint(user, tokenIdA, 50e18);
        assertEq(token.balanceOf(user, tokenIdA), 150e18);
    }

    function testBurnEmitsTransfer() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(executorA, user, address(0), tokenIdA, 60e18);

        vm.prank(executorA);
        token.burn(user, tokenIdA, 60e18);
    }

    function testBurnExactBalance() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(executorA);
        token.burn(user, tokenIdA, 100e18);
        assertEq(token.balanceOf(user, tokenIdA), 0);
    }

    function testBurnInsufficientBalanceReverts() public {
        _mint(user, tokenIdA, 50e18);

        vm.expectRevert(abi.encodeWithSelector(IERC6909ExclOperator.InsufficientBalance.selector, user, tokenIdA));
        vm.prank(executorA);
        token.burn(user, tokenIdA, 51e18);
    }
}

// ─── ERC-6909 Transfer ───────────────────────────────────────────────────────

contract ReceiptTokenTransferTest is ReceiptTokenTest {
    function testTransfer() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(user, user, receiver, tokenIdA, 40e18);

        vm.prank(user);
        assertTrue(token.transfer(receiver, tokenIdA, 40e18));

        assertEq(token.balanceOf(user, tokenIdA), 60e18);
        assertEq(token.balanceOf(receiver, tokenIdA), 40e18);
    }

    function testTransferInsufficientBalanceReverts() public {
        _mint(user, tokenIdA, 10e18);

        vm.expectRevert(abi.encodeWithSelector(IERC6909ExclOperator.InsufficientBalance.selector, user, tokenIdA));
        vm.prank(user);
        token.transfer(receiver, tokenIdA, 11e18);
    }
}

// ─── ERC-6909 TransferFrom ───────────────────────────────────────────────────

contract ReceiptTokenTransferFromTest is ReceiptTokenTest {
    function testTransferFromWithApproval() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(user);
        token.approve(spender, tokenIdA, 60e18);

        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(spender, user, receiver, tokenIdA, 60e18);

        vm.prank(spender);
        assertTrue(token.transferFrom(user, receiver, tokenIdA, 60e18));

        assertEq(token.balanceOf(user, tokenIdA), 40e18);
        assertEq(token.balanceOf(receiver, tokenIdA), 60e18);
        assertEq(token.allowance(user, spender, tokenIdA), 0);
    }

    function testTransferFromSenderIsCaller() public {
        _mint(user, tokenIdA, 100e18);

        // msg.sender == sender → no allowance check
        vm.prank(user);
        assertTrue(token.transferFrom(user, receiver, tokenIdA, 50e18));

        assertEq(token.balanceOf(user, tokenIdA), 50e18);
        assertEq(token.balanceOf(receiver, tokenIdA), 50e18);
    }

    function testTransferFromInsufficientAllowanceReverts() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(user);
        token.approve(spender, tokenIdA, 10e18);

        vm.expectRevert(abi.encodeWithSelector(IERC6909ExclOperator.InsufficientAllowance.selector, user, tokenIdA));
        vm.prank(spender);
        token.transferFrom(user, receiver, tokenIdA, 11e18);
    }

    function testTransferFromInsufficientBalanceReverts() public {
        _mint(user, tokenIdA, 10e18);

        vm.prank(user);
        token.approve(spender, tokenIdA, 100e18);

        vm.expectRevert(abi.encodeWithSelector(IERC6909ExclOperator.InsufficientBalance.selector, user, tokenIdA));
        vm.prank(spender);
        token.transferFrom(user, receiver, tokenIdA, 11e18);
    }
}

// ─── ERC-6909 Approve ────────────────────────────────────────────────────────

contract ReceiptTokenApproveTest is ReceiptTokenTest {
    function testApprove() public {
        vm.expectEmit();
        emit IERC6909ExclOperator.Approval(user, spender, tokenIdA, 200e18);

        vm.prank(user);
        assertTrue(token.approve(spender, tokenIdA, 200e18));

        assertEq(token.allowance(user, spender, tokenIdA), 200e18);
    }

    function testApproveOverwrites() public {
        vm.startPrank(user);
        token.approve(spender, tokenIdA, 100e18);
        token.approve(spender, tokenIdA, 50e18);
        vm.stopPrank();

        assertEq(token.allowance(user, spender, tokenIdA), 50e18);
    }
}

// ─── Token ID Encoding ───────────────────────────────────────────────────────

contract ReceiptTokenTokenIdTest is ReceiptTokenTest {
    function testToTokenId() public view {
        uint256 id = token.toTokenId(POOL_A, asset);
        assertEq(id, (uint256(POOL_A.raw()) << 160) | uint256(uint160(asset)));
    }

    function testTokenIdIsolatesPoolIds() public view {
        uint256 idA = token.toTokenId(POOL_A, asset);
        uint256 idB = token.toTokenId(POOL_B, asset);
        assertTrue(idA != idB);
    }

    function testTokenIdEncodesAssetInLower160() public view {
        uint256 id = token.toTokenId(POOL_A, asset);
        assertEq(address(uint160(id)), asset);
    }

    function testTokenIdEncodesPoolIdInUpper64() public view {
        uint256 id = token.toTokenId(POOL_A, asset);
        assertEq(uint64(id >> 160), POOL_A.raw());
    }
}

// ─── Metadata ────────────────────────────────────────────────────────────────

contract ReceiptTokenMetadataTest is ReceiptTokenTest {
    function testNameDerivedFromAssetSymbol() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.name(tokenIdA), "Receipt: USDC");
    }

    function testSymbolDerivedFromAssetSymbol() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.symbol(tokenIdA), "rec-USDC");
    }

    function testDecimalsDelegatesToAsset() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));

        assertEq(token.decimals(tokenIdA), 6);
    }
}

// ─── Factory Integration (real CREATE2) ──────────────────────────────────────

contract ReceiptTokenFactoryIntegrationTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);

    address contractUpdater = makeAddr("contractUpdater");
    address gateway = makeAddr("gateway");
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    IExecutorFactory factory;
    ReceiptToken token;

    function setUp() public {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory = IExecutorFactory(
            deployCode(
                "out-ir/Executor.sol/ExecutorFactory.json",
                abi.encode(contractUpdater, address(balanceSheet), gateway)
            )
        );

        token = new ReceiptToken(factory);
    }

    function testFactoryDeployedExecutorCanMint() public {
        IExecutor executor = factory.newExecutor(POOL_A);
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_);

        address user_ = makeAddr("user");
        vm.prank(address(executor));
        token.mint(user_, tokenId, 100e18);

        assertEq(token.balanceOf(user_, tokenId), 100e18);
    }

    function testFactoryDeployedExecutorCanBurn() public {
        IExecutor executor = factory.newExecutor(POOL_A);
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_);

        address user_ = makeAddr("user");
        vm.prank(address(executor));
        token.mint(user_, tokenId, 100e18);

        vm.prank(address(executor));
        token.burn(user_, tokenId, 100e18);

        assertEq(token.balanceOf(user_, tokenId), 0);
    }

    function testNonExecutorCannotMint() public {
        factory.newExecutor(POOL_A);
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_);

        vm.expectRevert(IReceiptToken.NotPoolExecutor.selector);
        vm.prank(makeAddr("random"));
        token.mint(makeAddr("user"), tokenId, 100e18);
    }
}
