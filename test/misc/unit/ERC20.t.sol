// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20, IERC20Permit} from "src/misc/interfaces/IERC20.sol";
import {IERC1271} from "src/misc/libraries/SignatureLib.sol";

import {ERC20} from "src/misc/ERC20.sol";

import "forge-std/Test.sol";

contract MockMultisig is IERC1271 {
    address public immutable signer1;
    address public immutable signer2;

    constructor(address signer1_, address signer2_) {
        signer1 = signer1_;
        signer2 = signer2_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4 sig) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (signer1 == ecrecover(digest, v, r, s)) {
            assembly {
                r := mload(add(signature, 0x80))
                s := mload(add(signature, 0xA0))
                v := byte(0, mload(add(signature, 0xC0)))
            }
            if (signer2 == ecrecover(digest, v, r, s)) {
                sig = IERC1271.isValidSignature.selector;
            }
        }
    }

    // Added to be ignored in coverage report
    function test() public {}
}

/// @author Modified from https://github.com/makerdao/xdomain-dss/blob/master/src/test/Dai.t.sol
contract ERC20Test is Test {
    ERC20 token;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        token = new ERC20(18);
    }

    function testPermissions(address anotherWard) public {
        vm.assume(anotherWard != address(this));

        token.rely(anotherWard);
        assertEq(token.wards(anotherWard), 1);
        token.deny(anotherWard);
        assertEq(token.wards(anotherWard), 0);
    }

    function testFile(string memory newName, string memory newSymbol, address invalidOrigin) public {
        vm.assume(invalidOrigin != address(this));

        vm.prank(invalidOrigin);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.file("name", newName);

        vm.expectRevert(ERC20.FileUnrecognizedParam.selector);
        token.file("notName", newName);

        token.file("name", newName);
        assertEq(token.name(), newName);

        token.file("symbol", newSymbol);
        assertEq(token.symbol(), newSymbol);
    }

    function testMint() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(0xBEEF), 1e18);
        token.mint(address(0xBEEF), 1e18);

        assertEq(token.totalSupply(), 1e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
    }

    function testMintBadAddress() public {
        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.mint(address(0), 1e18);
        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.mint(address(token), 1e18);
    }

    function testBurn() public {
        token.mint(address(0xBEEF), 1e18);
        token.rely(address(0xBEEF));

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0xBEEF), address(0), 0.9e18);
        vm.prank(address(0xBEEF));
        token.burn(address(0xBEEF), 0.9e18);

        assertEq(token.totalSupply(), 1e18 - 0.9e18);
        assertEq(token.balanceOf(address(0xBEEF)), 0.1e18);
    }

    function testBurnWithAllowance() public {
        address from = address(0xABCD);

        token.mint(address(0xBEEF), 1e18);
        token.rely(address(from));

        vm.prank(address(from));
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        token.burn(address(0xBEEF), 0.9e18);

        vm.prank(address(0xBEEF));
        token.approve(address(from), 1e18);

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0xBEEF), address(0), 0.9e18);
        vm.prank(address(from));
        token.burn(address(0xBEEF), 0.9e18);
    }

    function testApprove() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), address(0xBEEF), 1e18);
        assertTrue(token.approve(address(0xBEEF), 1e18));

        assertEq(token.allowance(address(this), address(0xBEEF)), 1e18);
    }

    function testTransfer() public {
        token.mint(address(this), 1e18);

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), address(0xBEEF), 1e18);
        assertTrue(token.transfer(address(0xBEEF), 1e18));
        assertEq(token.totalSupply(), 1e18);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
    }

    function testTransferBadAddress() public {
        token.mint(address(this), 1e18);

        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.transfer(address(0), 1e18);
        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.transfer(address(token), 1e18);
    }

    function testTransferFrom() public {
        address from = address(0xABCD);

        token.mint(from, 1e18);

        vm.prank(from);
        token.approve(address(this), 1e18);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, address(0xBEEF), 1e18);
        assertTrue(token.transferFrom(from, address(0xBEEF), 1e18));
        assertEq(token.totalSupply(), 1e18);

        assertEq(token.allowance(from, address(this)), 0);

        assertEq(token.balanceOf(from), 0);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
    }

    function testTransferFromBadAddress() public {
        token.mint(address(this), 1e18);

        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.transferFrom(address(this), address(0), 1e18);
        vm.expectRevert(IERC20.InvalidAddress.selector);
        token.transferFrom(address(this), address(token), 1e18);
    }

    function testInfiniteApproveTransferFrom() public {
        address from = address(0xABCD);

        token.mint(from, 1e18);

        vm.prank(from);
        vm.expectEmit(true, true, true, true);
        emit Approval(from, address(this), type(uint256).max);
        token.approve(address(this), type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, address(0xBEEF), 1e18);
        assertTrue(token.transferFrom(from, address(0xBEEF), 1e18));
        assertEq(token.totalSupply(), 1e18);

        assertEq(token.allowance(from, address(this)), type(uint256).max);

        assertEq(token.balanceOf(from), 0);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
    }

    function testPermit() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Approval(owner, address(0xCAFE), 1e18);
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);

        assertEq(token.allowance(owner, address(0xCAFE)), 1e18);
        assertEq(token.nonces(owner), 1);
    }

    function testPermitContract() public {
        uint256 privateKey1 = 0xBEEF;
        address signer1 = vm.addr(privateKey1);
        uint256 privateKey2 = 0xBEEE;
        address signer2 = vm.addr(privateKey2);

        address mockMultisig = address(new MockMultisig(signer1, signer2));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            uint256(privateKey1),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            uint256(privateKey2),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        bytes memory signature = abi.encode(r, s, bytes32(uint256(v) << 248), r2, s2, bytes32(uint256(v2) << 248));
        vm.expectEmit(true, true, true, true);
        emit Approval(mockMultisig, address(0xCAFE), 1e18);
        token.permit(mockMultisig, address(0xCAFE), 1e18, block.timestamp, signature);

        assertEq(token.allowance(mockMultisig, address(0xCAFE)), 1e18);
        assertEq(token.nonces(mockMultisig), 1);
    }

    function testPermitContractInvalidSignature() public {
        uint256 privateKey1 = 0xBEEF;
        address signer1 = vm.addr(privateKey1);
        uint256 privateKey2 = 0xBEEE;
        address signer2 = vm.addr(privateKey2);

        address mockMultisig = address(new MockMultisig(signer1, signer2));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            uint256(privateKey1),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            uint256(0xCEEE),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        bytes memory signature = abi.encode(r, s, bytes32(uint256(v) << 248), r2, s2, bytes32(uint256(v2) << 248));
        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(mockMultisig, address(0xCAFE), 1e18, block.timestamp, signature);
    }

    function testTransferInsufficientBalance() public {
        token.mint(address(this), 0.9e18);
        vm.expectRevert(IERC20.InsufficientBalance.selector);
        token.transfer(address(0xBEEF), 1e18);
    }

    function testTransferFromInsufficientAllowance() public {
        address from = address(0xABCD);

        token.mint(from, 1e18);

        vm.prank(from);
        token.approve(address(this), 0.9e18);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        token.transferFrom(from, address(0xBEEF), 1e18);
    }

    function testTransferFromInsufficientBalance() public {
        address from = address(0xABCD);

        token.mint(from, 0.9e18);

        vm.prank(from);
        token.approve(address(this), 1e18);

        vm.expectRevert(IERC20.InsufficientBalance.selector);
        token.transferFrom(from, address(0xBEEF), 1e18);
    }

    function testPermitBadNonce() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 1, block.timestamp))
                )
            )
        );

        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
    }

    function testPermitBadDeadline() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp + 1, v, r, s);
    }

    function testPermitPastDeadline() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);
        uint256 deadline = block.timestamp == 0 ? 0 : block.timestamp - 1;

        bytes32 domain_separator = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domain_separator,
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, deadline))
                )
            )
        );

        vm.warp(deadline + 1);

        vm.expectRevert(IERC20Permit.PermitExpired.selector);
        token.permit(owner, address(0xCAFE), 1e18, deadline, v, r, s);
    }

    function testPermitReplay() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
    }

    function testMint(address to, uint256 amount) public {
        if (to != address(0) && to != address(token)) {
            vm.expectEmit(true, true, true, true);
            emit Transfer(address(0), to, amount);
        } else {
            vm.expectRevert(IERC20.InvalidAddress.selector);
        }
        token.mint(to, amount);

        if (to != address(0) && to != address(token)) {
            assertEq(token.totalSupply(), amount);
            assertEq(token.balanceOf(to), amount);
        }
    }

    function testBurn(address from, uint256 mintAmount, uint256 burnAmount) public {
        if (from == address(0) || from == address(token)) return;

        burnAmount = bound(burnAmount, 0, mintAmount);

        token.mint(from, mintAmount);
        token.rely(from);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, address(0), burnAmount);
        vm.prank(from);
        token.burn(from, burnAmount);

        assertEq(token.totalSupply(), mintAmount - burnAmount);
        assertEq(token.balanceOf(from), mintAmount - burnAmount);
    }

    function testApprove(address to, uint256 amount) public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), to, amount);
        assertTrue(token.approve(to, amount));

        assertEq(token.allowance(address(this), to), amount);
    }

    function testTransfer(address to, uint256 amount) public {
        if (to == address(0) || to == address(token)) return;

        token.mint(address(this), amount);

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), to, amount);
        assertTrue(token.transfer(to, amount));
        assertEq(token.totalSupply(), amount);

        if (address(this) == to) {
            assertEq(token.balanceOf(address(this)), amount);
        } else {
            assertEq(token.balanceOf(address(this)), 0);
            assertEq(token.balanceOf(to), amount);
        }
    }

    function testTransferFrom(address to, uint256 approval, uint256 amount) public {
        if (to == address(0) || to == address(token)) return;

        amount = bound(amount, 0, approval);

        address from = address(0xABCD);

        token.mint(from, amount);

        vm.prank(from);
        token.approve(address(this), approval);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, to, amount);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.totalSupply(), amount);

        uint256 app = from == address(this) || approval == type(uint256).max ? approval : approval - amount;
        assertEq(token.allowance(from, address(this)), app);

        if (from == to) {
            assertEq(token.balanceOf(from), amount);
        } else {
            assertEq(token.balanceOf(from), 0);
            assertEq(token.balanceOf(to), amount);
        }
    }

    function testPermit(uint248 privKey, address to, uint256 amount, uint256 deadline) public {
        uint256 privateKey = privKey;
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Approval(owner, to, amount);
        token.permit(owner, to, amount, deadline, v, r, s);

        assertEq(token.allowance(owner, to), amount);
        assertEq(token.nonces(owner), 1);
    }

    function testBurnInsufficientBalance(address to, uint256 mintAmount, uint256 burnAmount) public {
        if (to == address(0) || to == address(token)) return;

        if (mintAmount == type(uint256).max) mintAmount -= 1;
        burnAmount = bound(burnAmount, mintAmount + 1, type(uint256).max);

        token.mint(to, mintAmount);
        vm.expectRevert(IERC20.InsufficientBalance.selector);
        token.burn(to, burnAmount);
    }

    function testTransferInsufficientBalance(address to, uint256 mintAmount, uint256 sendAmount) public {
        if (to == address(0) || to == address(token)) return;

        if (mintAmount == type(uint256).max) mintAmount -= 1;
        sendAmount = bound(sendAmount, mintAmount + 1, type(uint256).max);

        token.mint(address(this), mintAmount);
        vm.expectRevert(IERC20.InsufficientBalance.selector);
        token.transfer(to, sendAmount);
    }

    function testTransferFromInsufficientAllowance(address to, uint256 approval, uint256 amount) public {
        if (to == address(0) || to == address(token)) return;

        if (approval == type(uint256).max) approval -= 1;
        amount = bound(amount, approval + 1, type(uint256).max);

        address from = address(0xABCD);

        token.mint(from, amount);

        vm.prank(from);
        token.approve(address(this), approval);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        token.transferFrom(from, to, amount);
    }

    function testTransferFromInsufficientBalance(address to, uint256 mintAmount, uint256 sendAmount) public {
        if (to == address(0) || to == address(token)) return;

        if (mintAmount == type(uint256).max) mintAmount -= 1;
        sendAmount = bound(sendAmount, mintAmount + 1, type(uint256).max);

        address from = address(0xABCD);

        token.mint(from, mintAmount);

        vm.prank(from);
        token.approve(address(this), sendAmount);

        vm.expectRevert(IERC20.InsufficientBalance.selector);
        token.transferFrom(from, to, sendAmount);
    }

    function testPermitBadNonce(uint128 privateKey, address to, uint256 amount, uint256 deadline, uint256 nonce)
        public
    {
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;
        if (nonce == 0) nonce = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, nonce, deadline))
                )
            )
        );

        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, to, amount, deadline, v, r, s);
    }

    function testPermitBadDeadline(uint128 privateKey, address to, uint256 amount, uint256 deadline) public {
        if (deadline == type(uint256).max) deadline -= 1;
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, to, amount, deadline + 1, v, r, s);
    }

    function testPermitPastDeadline(uint128 privateKey, address to, uint256 amount, uint256 deadline) public {
        if (deadline == type(uint256).max) deadline -= 1;
        vm.warp(deadline);

        // private key cannot be 0 for secp256k1 pubkey generation
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        bytes32 domain_separator = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01", domain_separator, keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.warp(deadline + 1);

        vm.expectRevert(IERC20Permit.PermitExpired.selector);
        token.permit(owner, to, amount, deadline, v, r, s);
    }

    function testPermitReplay(uint128 privateKey, address to, uint256 amount, uint256 deadline) public {
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        token.permit(owner, to, amount, deadline, v, r, s);
        vm.expectRevert(IERC20Permit.InvalidPermit.selector);
        token.permit(owner, to, amount, deadline, v, r, s);
    }
}
