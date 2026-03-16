// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";
import {IERC6909ExclOperator, IERC6909MetadataExt} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {AccountingToken} from "../../../../src/managers/spoke/AccountingToken.sol";
import {IAccountingToken} from "../../../../src/managers/spoke/interfaces/IAccountingToken.sol";

import "forge-std/Test.sol";

// ─── Base ────────────────────────────────────────────────────────────────────

contract AccountingTokenTest is Test {
    using CastLib for address;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    address contractUpdater = makeAddr("contractUpdater");

    AccountingToken token;

    address asset = makeAddr("asset");
    address user = makeAddr("user");
    address spender = makeAddr("spender");
    address receiver = makeAddr("receiver");

    uint256 tokenIdA;
    uint256 tokenIdB;
    address minterA = makeAddr("minterA");
    address minterB = makeAddr("minterB");

    function setUp() public virtual {
        token = new AccountingToken(contractUpdater);

        tokenIdA = token.toTokenId(POOL_A, asset, false);
        tokenIdB = token.toTokenId(POOL_B, asset, false);

        // Register minters via trustedCall
        vm.startPrank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(minterA.toBytes32(), true));
        token.trustedCall(POOL_B, SC_1, abi.encode(minterB.toBytes32(), true));
        vm.stopPrank();
    }

    function _mint(address to, uint256 id, uint256 amount) internal {
        address minter = PoolId.wrap(uint64(id >> 160)).raw() == POOL_A.raw() ? minterA : minterB;
        vm.prank(minter);
        token.mint(to, id, amount, SC_1);
    }
}

// ─── Constructor ─────────────────────────────────────────────────────────────

contract AccountingTokenConstructorTest is AccountingTokenTest {
    function testConstructor() public view {
        assertEq(token.contractUpdater(), contractUpdater);
    }
}

// ─── Access Control ──────────────────────────────────────────────────────────

contract AccountingTokenAccessControlTest is AccountingTokenTest {
    function testMintFromCorrectMinter() public {
        vm.prank(minterA);
        token.mint(user, tokenIdA, 100e18, SC_1);
        assertEq(token.balanceOf(user, tokenIdA), 100e18);
    }

    function testBurnFromCorrectMinter() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(minterA);
        token.burn(user, tokenIdA, 50e18, SC_1);
        assertEq(token.balanceOf(user, tokenIdA), 50e18);
    }

    function testMintFromWrongPoolMinterReverts() public {
        // minterB cannot mint tokenIdA (belongs to pool A)
        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(minterB);
        token.mint(user, tokenIdA, 100e18, SC_1);
    }

    function testBurnFromWrongPoolMinterReverts() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(minterB);
        token.burn(user, tokenIdA, 50e18, SC_1);
    }

    function testMintFromRandomAddressReverts() public {
        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(user);
        token.mint(user, tokenIdA, 100e18, SC_1);
    }

    function testBurnFromRandomAddressReverts() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(user);
        token.burn(user, tokenIdA, 50e18, SC_1);
    }
}

// ─── TrustedCall ─────────────────────────────────────────────────────────────

contract AccountingTokenTrustedCallTest is AccountingTokenTest {
    using CastLib for address;

    function testTrustedCallOnlyCallableByContractUpdater() public {
        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(user);
        token.trustedCall(POOL_A, SC_1, abi.encode(user.toBytes32(), true));
    }

    function testTrustedCallEnablesMinter() public {
        address newMinter = makeAddr("newMinter");
        assertFalse(token.minters(POOL_A, newMinter));

        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(newMinter.toBytes32(), true));

        assertTrue(token.minters(POOL_A, newMinter));
    }

    function testTrustedCallDisablesMinter() public {
        assertTrue(token.minters(POOL_A, minterA));

        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(minterA.toBytes32(), false));

        assertFalse(token.minters(POOL_A, minterA));
    }

    function testTrustedCallEmitsUpdateMinter() public {
        address newMinter = makeAddr("newMinter");

        vm.expectEmit();
        emit IAccountingToken.UpdateMinter(POOL_A, newMinter, true);

        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(newMinter.toBytes32(), true));
    }

    function testDisabledMinterCannotMint() public {
        // Disable minterA
        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(minterA.toBytes32(), false));

        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(minterA);
        token.mint(user, tokenIdA, 100e18, SC_1);
    }
}

// ─── Mint / Burn ─────────────────────────────────────────────────────────────

contract AccountingTokenMintBurnTest is AccountingTokenTest {
    function testMintEmitsTransferAndMint() public {
        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(minterA, address(0), user, tokenIdA, 100e18);
        vm.expectEmit();
        emit IAccountingToken.Mint(POOL_A, SC_1, user, tokenIdA, 100e18);

        vm.prank(minterA);
        token.mint(user, tokenIdA, 100e18, SC_1);
    }

    function testMintAccumulates() public {
        _mint(user, tokenIdA, 100e18);
        _mint(user, tokenIdA, 50e18);
        assertEq(token.balanceOf(user, tokenIdA), 150e18);
    }

    function testBurnEmitsTransferAndBurn() public {
        _mint(user, tokenIdA, 100e18);

        vm.expectEmit();
        emit IERC6909ExclOperator.Transfer(minterA, user, address(0), tokenIdA, 60e18);
        vm.expectEmit();
        emit IAccountingToken.Burn(POOL_A, SC_1, user, tokenIdA, 60e18);

        vm.prank(minterA);
        token.burn(user, tokenIdA, 60e18, SC_1);
    }

    function testBurnExactBalance() public {
        _mint(user, tokenIdA, 100e18);

        vm.prank(minterA);
        token.burn(user, tokenIdA, 100e18, SC_1);
        assertEq(token.balanceOf(user, tokenIdA), 0);
    }

    function testBurnInsufficientBalanceReverts() public {
        _mint(user, tokenIdA, 50e18);

        vm.expectRevert(abi.encodeWithSelector(IERC6909ExclOperator.InsufficientBalance.selector, user, tokenIdA));
        vm.prank(minterA);
        token.burn(user, tokenIdA, 51e18, SC_1);
    }
}

// ─── ERC-6909 Transfer ───────────────────────────────────────────────────────

contract AccountingTokenTransferTest is AccountingTokenTest {
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

contract AccountingTokenTransferFromTest is AccountingTokenTest {
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

contract AccountingTokenApproveTest is AccountingTokenTest {
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

contract AccountingTokenTokenIdTest is AccountingTokenTest {
    function testToTokenId() public view {
        uint256 id = token.toTokenId(POOL_A, asset, false);
        assertEq(id, (uint256(POOL_A.raw()) << 160) | uint256(uint160(asset)));
    }

    function testTokenIdIsolatesPoolIds() public view {
        uint256 idA = token.toTokenId(POOL_A, asset, false);
        uint256 idB = token.toTokenId(POOL_B, asset, false);
        assertTrue(idA != idB);
    }

    function testTokenIdEncodesAssetInLower160() public view {
        uint256 id = token.toTokenId(POOL_A, asset, false);
        assertEq(address(uint160(id)), asset);
    }

    function testTokenIdEncodesPoolIdInUpper64() public view {
        uint256 id = token.toTokenId(POOL_A, asset, false);
        assertEq(uint64(id >> 160), POOL_A.raw());
    }

    function testToTokenIdWithLiabilitySetsBit255() public view {
        uint256 id = token.toTokenId(POOL_A, asset, true);
        uint256 idNoLiab = token.toTokenId(POOL_A, asset, false);
        assertEq(id, idNoLiab | (1 << 255));
    }

    function testIsLiabilityReturnsTrueForLiabilityTokenId() public view {
        uint256 id = token.toTokenId(POOL_A, asset, true);
        assertTrue(token.isLiability(id));
    }

    function testIsLiabilityReturnsFalseForNonLiabilityTokenId() public view {
        uint256 id = token.toTokenId(POOL_A, asset, false);
        assertFalse(token.isLiability(id));
    }
}

// ─── Metadata ────────────────────────────────────────────────────────────────

contract AccountingTokenMetadataTest is AccountingTokenTest {
    function testNameDerivedFromAssetSymbol() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.name(tokenIdA), "Accounting USDC");
    }

    function testSymbolDerivedFromAssetSymbol() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.symbol(tokenIdA), "acc-USDC");
    }

    function testDecimalsDelegatesToAsset() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));

        assertEq(token.decimals(tokenIdA), 6);
    }

    function testLiabilityNameDerivedFromAssetSymbol() public {
        uint256 liabId = token.toTokenId(POOL_A, asset, true);
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.name(liabId), "Liability USDC");
    }

    function testLiabilitySymbolDerivedFromAssetSymbol() public {
        uint256 liabId = token.toTokenId(POOL_A, asset, true);
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("USDC"));

        assertEq(token.symbol(liabId), "liab-USDC");
    }
}

// ─── Minter Integration ─────────────────────────────────────────────────────

contract AccountingTokenMinterIntegrationTest is Test {
    using CastLib for address;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    address contractUpdater = makeAddr("contractUpdater");
    AccountingToken token;

    function setUp() public {
        token = new AccountingToken(contractUpdater);
    }

    function testTrustedCallRegisteredMinterCanMint() public {
        address minter = makeAddr("minter");
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_, false);
        address user_ = makeAddr("user");

        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(minter.toBytes32(), true));

        vm.prank(minter);
        token.mint(user_, tokenId, 100e18, SC_1);

        assertEq(token.balanceOf(user_, tokenId), 100e18);
    }

    function testTrustedCallRegisteredMinterCanBurn() public {
        address minter = makeAddr("minter");
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_, false);
        address user_ = makeAddr("user");

        vm.prank(contractUpdater);
        token.trustedCall(POOL_A, SC_1, abi.encode(minter.toBytes32(), true));

        vm.prank(minter);
        token.mint(user_, tokenId, 100e18, SC_1);

        vm.prank(minter);
        token.burn(user_, tokenId, 100e18, SC_1);

        assertEq(token.balanceOf(user_, tokenId), 0);
    }

    function testNonMinterCannotMint() public {
        address asset_ = makeAddr("asset");
        uint256 tokenId = token.toTokenId(POOL_A, asset_, false);

        vm.expectRevert(IAccountingToken.NotMinter.selector);
        vm.prank(makeAddr("random"));
        token.mint(makeAddr("user"), tokenId, 100e18, SC_1);
    }
}
