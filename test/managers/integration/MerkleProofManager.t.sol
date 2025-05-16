// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "test/spoke/BaseTest.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {BalanceSheet} from "src/spoke/BalanceSheet.sol";

import {MerkleProofManager, PolicyLeaf} from "src/managers/MerkleProofManager.sol";
import {VaultDecoder} from "src/managers/decoders/VaultDecoder.sol";
import {MerkleTreeLib} from "test/managers/libraries/MerkleTreeLib.sol";

contract BalanceSheetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

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
            fullRestrictionsHook
        );
        spoke.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(this).toBytes32(), validUntil: MAX_UINT64}).serialize()
        );

        manager = new MerkleProofManager(POOL_A, balanceSheet, address(this));
    }

    function testExecute(uint128 withdrawAmount, uint128 depositAmount) public {
        withdrawAmount = uint128(bound(withdrawAmount, 0, type(uint128).max / 2));
        depositAmount = uint128(bound(depositAmount, 0, withdrawAmount));

        address receiver = makeAddr("receiver");
        decoder = new VaultDecoder();

        // Deposit ERC20 in balance sheet
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);

        erc20.mint(address(this), withdrawAmount);
        erc20.approve(address(balanceSheet), withdrawAmount);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, withdrawAmount);

        // Set merkle proof manager as balance sheet manager
        balanceSheet.updateManager(POOL_A, address(manager), true);

        // Generate policy root hash
        PolicyLeaf[] memory leafs = new PolicyLeaf[](4);
        leafs[0] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("withdraw(uint64,bytes16,address,uint256,address,uint128)"),
            addresses: abi.encodePacked(erc20, manager)
        });

        leafs[1] = PolicyLeaf({
            decoder: address(decoder),
            target: address(balanceSheet),
            valueNonZero: false,
            selector: _selector("deposit(uint64,bytes16,address,uint256,uint128)"),
            addresses: abi.encodePacked(erc20)
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
        manager.setPolicy(address(this), tree[tree.length - 1][0]);

        // Generate proof for execution
        PolicyLeaf[] memory proofLeafs = new PolicyLeaf[](3);
        proofLeafs[0] = leafs[0]; // withdraw
        proofLeafs[1] = leafs[2]; // approve
        proofLeafs[2] = leafs[1]; // deposit

        (bytes32[][] memory proofs) = MerkleTreeLib.getProofsUsingTree(_computeHashes(proofLeafs), tree);

        // Execute
        bytes[] memory targetData = new bytes[](3);
        targetData[0] = abi.encodeWithSelector(
            BalanceSheet.withdraw.selector,
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(manager),
            withdrawAmount
        );
        targetData[1] = abi.encodeWithSelector(ERC20.approve.selector, address(balanceSheet), depositAmount);
        targetData[2] = abi.encodeWithSelector(
            BalanceSheet.deposit.selector, POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, depositAmount
        );

        address[] memory targets = new address[](3);
        targets[0] = address(balanceSheet);
        targets[1] = address(erc20);
        targets[2] = address(balanceSheet);

        uint256[] memory values = new uint256[](3);

        address[] memory decoders = new address[](3);
        decoders[0] = address(decoder);
        decoders[1] = address(decoder);
        decoders[2] = address(decoder);

        assertEq(erc20.balanceOf(receiver), 0);
        manager.execute(proofs, decoders, targets, targetData, values);
        assertEq(erc20.balanceOf(address(manager)), withdrawAmount - depositAmount);
        assertEq(erc20.balanceOf(address(balanceSheet.escrow(POOL_A))), depositAmount);
    }

    function _selector(string memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(signature)));
    }

    function _computeHashes(PolicyLeaf[] memory policyLeafs) internal pure returns (bytes32[] memory) {
        bytes32[] memory leafs = new bytes32[](policyLeafs.length);
        for (uint256 i; i < policyLeafs.length; ++i) {
            leafs[i] = policyLeafs[i].computeHash();
        }
        return leafs;
    }
}
