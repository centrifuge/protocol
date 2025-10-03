// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import "../../spoke/integration/BaseTest.sol";

import {BalanceSheet} from "../../../src/spoke/BalanceSheet.sol";
import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {VaultDecoder} from "../../../src/managers/decoders/VaultDecoder.sol";
import {MerkleProofManager, PolicyLeaf, Call} from "../../../src/managers/MerkleProofManager.sol";
import {IMerkleProofManager, IERC7751} from "../../../src/managers/interfaces/IMerkleProofManager.sol";

import {MerkleTreeLib} from "../libraries/MerkleTreeLib.sol";

abstract contract MerkleProofManagerBaseTest is BaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    address receiver = makeAddr("receiver");
    MerkleProofManager manager;
    VaultDecoder decoder;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePoolPerShare = d18(1, 1);
        defaultPricePoolPerAsset = d18(1, 1);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = spoke.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId);
        spoke.addPool(POOL_A);
        spoke.addShareClass(
            POOL_A,
            defaultTypedShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            bytes32(""),
            address(fullRestrictionsHook)
        );
        spoke.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spoke.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spoke.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: address(this).toBytes32(),
                validUntil: MAX_UINT64
            }).serialize()
        );

        manager = new MerkleProofManager(POOL_A, address(spoke));
    }

    function _depositIntoBalanceSheet(uint128 amount) internal {
        erc20.mint(address(this), amount);
        erc20.approve(address(balanceSheet), amount);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, amount);
    }

    function _setPolicy(bytes32[][] memory tree) internal {
        bytes32 rootHash = tree[tree.length - 1][0];

        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractPolicy({who: address(this).toBytes32(), what: rootHash}).serialize()
        );
    }

    function _selector(string memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(signature)));
    }

    function _computeHashes(PolicyLeaf[] memory policyLeafs) internal pure returns (bytes32[] memory) {
        bytes32[] memory leafs = new bytes32[](policyLeafs.length);
        for (uint256 i; i < policyLeafs.length; ++i) {
            leafs[i] = keccak256(
                abi.encodePacked(
                    policyLeafs[i].decoder,
                    policyLeafs[i].target,
                    policyLeafs[i].valueNonZero,
                    policyLeafs[i].selector,
                    policyLeafs[i].addresses
                )
            );
        }
        return leafs;
    }
}

contract MerkleProofManagerFailureTests is MerkleProofManagerBaseTest {
    using CastLib for *;

    function testNotStrategist() public {
        Call[] memory calls = new Call[](0);

        vm.expectRevert(IMerkleProofManager.NotAStrategist.selector);
        manager.execute(calls);
    }

    function testInvalidDecoder() public {
        decoder = new VaultDecoder();
        uint128 withdrawAmount = 100_000;
        _depositIntoBalanceSheet(withdrawAmount);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](2);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20)
        });

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(_computeHashes(leafs));

        _setPolicy(tree);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](1);
        proofLeafs[0] = leafs[0]; // withdraw

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            decoder: makeAddr("notADecoder"),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.withdraw.selector,
                POOL_A,
                defaultTypedShareClassId,
                address(erc20),
                erc20TokenId,
                address(manager),
                withdrawAmount
            ),
            value: 0,
            proof: proofs[0]
        });

        vm.expectRevert();
        manager.execute(calls);
    }

    function testNotSetAsBalanceSheetManager() public {
        decoder = new VaultDecoder();
        uint128 withdrawAmount = 100_000;
        _depositIntoBalanceSheet(withdrawAmount);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](2);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20)
        });

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(_computeHashes(leafs));

        _setPolicy(tree);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](1);
        proofLeafs[0] = leafs[0]; // withdraw

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            decoder: address(decoder),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.withdraw.selector,
                POOL_A,
                defaultTypedShareClassId,
                address(erc20),
                erc20TokenId,
                address(manager),
                withdrawAmount
            ),
            value: 0,
            proof: proofs[0]
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7751.WrappedError.selector,
                address(balanceSheet),
                BalanceSheet.withdraw.selector,
                abi.encodeWithSelector(IAuth.NotAuthorized.selector),
                abi.encodeWithSignature("CallFailed()")
            )
        );
        manager.execute(calls);
    }

    function testInvalidProof() public {
        decoder = new VaultDecoder();
        uint128 withdrawAmount = 100_000;
        _depositIntoBalanceSheet(withdrawAmount);

        // Set merkle proof manager as balance sheet manager
        balanceSheet.updateManager(POOL_A, address(manager), true);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](2);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20)
        });

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(_computeHashes(leafs));

        _setPolicy(tree);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](1);
        proofLeafs[0] = leafs[1]; // deposit (should be withdraw)

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            decoder: address(decoder),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.withdraw.selector,
                POOL_A,
                defaultTypedShareClassId,
                address(erc20),
                erc20TokenId,
                address(manager),
                withdrawAmount
            ),
            value: 0,
            proof: proofs[0]
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IMerkleProofManager.InvalidProof.selector,
                PolicyLeaf({
                    decoder: address(decoder),
                    target: address(balanceSheet),
                    selector: BalanceSheet.withdraw.selector,
                    addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, address(erc20), address(manager)),
                    valueNonZero: false
                }),
                proofs[0]
            )
        );
        manager.execute(calls);
    }

    function testInvalidCall() public {
        decoder = new VaultDecoder();
        uint128 withdrawAmount = 100_000;
        _depositIntoBalanceSheet(withdrawAmount);

        // Set merkle proof manager as balance sheet manager
        balanceSheet.updateManager(POOL_A, address(manager), true);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](2);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20)
        });

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(_computeHashes(leafs));

        _setPolicy(tree);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](1);
        proofLeafs[0] = leafs[0]; // withdraw

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            decoder: address(decoder),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.withdraw.selector,
                POOL_A,
                defaultTypedShareClassId,
                address(erc20),
                erc20TokenId,
                makeAddr("otherTarget"), // invalid target, should be address(manager)
                withdrawAmount
            ),
            value: 0,
            proof: proofs[0]
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IMerkleProofManager.InvalidProof.selector,
                PolicyLeaf({
                    decoder: address(decoder),
                    target: address(balanceSheet),
                    selector: BalanceSheet.withdraw.selector,
                    addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, address(erc20), makeAddr("otherTarget")),
                    valueNonZero: false
                }),
                proofs[0]
            )
        );
        manager.execute(calls);
    }
}

contract MerkleProofManagerSuccessTests is MerkleProofManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testReceiveEther() public {
        (bool success,) = address(manager).call{value: 1 ether}("");
        assertTrue(success, "Failed to send Ether");

        assertEq(address(manager).balance, 1 ether);
    }

    function testExecute(uint128 withdrawAmount, uint128 depositAmount) public {
        withdrawAmount = uint128(bound(withdrawAmount, 0, type(uint128).max / 2));
        depositAmount = uint128(bound(depositAmount, 0, withdrawAmount));

        decoder = new VaultDecoder();
        _depositIntoBalanceSheet(withdrawAmount);

        // Set merkle proof manager as balance sheet manager
        balanceSheet.updateManager(POOL_A, address(manager), true);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](4);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(POOL_A, defaultTypedShareClassId, erc20)
        });

        leafs[2] = PolicyLeaf({
            decoder: address(decoder),
            target: address(erc20),
            valueNonZero: false,
            selector: _selector("approve(address,uint256)"),
            addresses: abi.encodePacked(balanceSheet)
        });

        leafs[3] = PolicyLeaf({
            decoder: address(decoder),
            target: address(erc20),
            valueNonZero: false,
            selector: _selector("approve(address,uint256)"),
            addresses: abi.encodePacked(this)
        });

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(_computeHashes(leafs));

        _setPolicy(tree);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](3);
        proofLeafs[0] = leafs[0]; // withdraw
        proofLeafs[1] = leafs[2]; // approve
        proofLeafs[2] = leafs[1]; // deposit

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            decoder: address(decoder),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.withdraw.selector,
                POOL_A,
                defaultTypedShareClassId,
                address(erc20),
                erc20TokenId,
                address(manager),
                withdrawAmount
            ),
            value: 0,
            proof: proofs[0]
        });

        calls[1] = Call({
            decoder: address(decoder),
            target: address(erc20),
            targetData: abi.encodeWithSelector(ERC20.approve.selector, address(balanceSheet), depositAmount),
            value: 0,
            proof: proofs[1]
        });

        calls[2] = Call({
            decoder: address(decoder),
            target: address(balanceSheet),
            targetData: abi.encodeWithSelector(
                BalanceSheet.deposit.selector, POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, depositAmount
            ),
            value: 0,
            proof: proofs[2]
        });

        assertEq(erc20.balanceOf(receiver), 0);
        manager.execute(calls);
        assertEq(erc20.balanceOf(address(manager)), withdrawAmount - depositAmount);
        assertEq(erc20.balanceOf(address(balanceSheet.escrow(POOL_A))), depositAmount);
    }
}
