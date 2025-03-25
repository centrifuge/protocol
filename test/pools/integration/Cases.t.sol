// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IMulticall} from "src/misc/interfaces/IMulticall.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {MessageLib, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AccountId, newAccountId} from "src/common/types/AccountId.sol";

import {PoolsDeployer, ISafe} from "script/PoolsDeployer.s.sol";
import {AccountType} from "src/pools/interfaces/IPoolRouter.sol";
import {JournalEntry} from "src/common/types/JournalEntry.sol";

import {MockVaults} from "test/pools/mocks/MockVaults.sol";
import {ShareClassIdTest} from "../unit/types/ShareClassId.t.sol";

contract TestCases is PoolsDeployer, Test {
    using CastLib for string;
    using CastLib for bytes32;
    using MathLib for *;

    uint16 constant CHAIN_CP = 5;
    uint16 constant CHAIN_CV = 6;

    string constant SC_NAME = "ExampleName";
    string constant SC_SYMBOL = "ExampleSymbol";
    bytes32 constant SC_SALT = bytes32("ExampleSalt");
    bytes32 constant SC_HOOK = bytes32("ExampleHookData");

    address immutable FM = makeAddr("FM");
    address immutable ANY = makeAddr("Anyone");
    bytes32 immutable INVESTOR = bytes32("Investor");

    AssetId immutable USDC_C2 = newAssetId(CHAIN_CV, 1);

    uint128 constant INVESTOR_AMOUNT = 100 * 1e6; // USDC_C2
    uint128 constant SHARE_AMOUNT = 10 * 1e18; // Share from USD
    uint128 constant APPROVED_INVESTOR_AMOUNT = INVESTOR_AMOUNT / 5;
    uint128 constant APPROVED_SHARE_AMOUNT = SHARE_AMOUNT / 5;
    D18 immutable NAV_PER_SHARE = d18(2, 1);

    uint64 constant GAS = 100 wei;

    MockVaults cv;

    function _mockStuff() private {
        cv = new MockVaults(CHAIN_CV, gateway);
        wire(cv, address(this));

        gasService.file("messageGasLimit", GAS);
    }

    function setUp() public {
        // Deployment
        deployPools(CHAIN_CP, ISafe(address(0)), address(this));
        _mockStuff();
        removePoolsDeployerAccess(address(this));

        // Initialize accounts
        vm.deal(FM, 1 ether);

        // Label contracts & actors (for debugging)
        vm.label(address(transientValuation), "TransientValuation");
        vm.label(address(identityValuation), "IdentityValuation");
        vm.label(address(poolRegistry), "PoolRegistry");
        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(accounting), "Accounting");
        vm.label(address(holdings), "Holdings");
        vm.label(address(multiShareClass), "MultiShareClass");
        vm.label(address(poolRouter), "PoolRouter");
        vm.label(address(gateway), "Gateway");
        vm.label(address(messageProcessor), "MessageProcessor");
        vm.label(address(cv), "CV");

        // We should not use the ChainID
        vm.chainId(0xDEAD);
    }

    /// forge-config: default.isolate = true
    function testPoolCreation() public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        (string memory name, string memory symbol, uint8 decimals) = assetRegistry.asset(USDC_C2);
        assertEq(name, "USD Coin");
        assertEq(symbol, "USDC");
        assertEq(decimals, 6);

        vm.prank(FM);
        poolId = poolRouter.createPool(FM, USD, multiShareClass);

        scId = multiShareClass.previewNextShareClassId(poolId);

        (bytes[] memory cs, uint256 c) = (new bytes[](6), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, bytes("Testing pool"));
        cs[c++] = abi.encodeWithSelector(poolRouter.addShareClass.selector, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        cs[c++] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);
        cs[c++] = abi.encodeWithSelector(poolRouter.notifyShareClass.selector, CHAIN_CV, scId, SC_HOOK);
        cs[c++] =
            abi.encodeWithSelector(poolRouter.createHolding.selector, scId, USDC_C2, identityValuation, false, 0x01);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.updateVault.selector,
            scId,
            USDC_C2,
            bytes32("target"),
            bytes32("factory"),
            VaultUpdateKind.DeployAndLink
        );
        assertEq(c, cs.length);

        vm.prank(FM);
        poolRouter.execute{value: GAS}(poolId, cs);

        assertEq(poolRegistry.metadata(poolId), "Testing pool");
        assertEq(multiShareClass.exists(poolId, scId), true);

        MessageLib.NotifyPool memory m0 = MessageLib.deserializeNotifyPool(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());

        MessageLib.NotifyShareClass memory m1 = MessageLib.deserializeNotifyShareClass(cv.lastMessages(1));
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.name, SC_NAME);
        assertEq(m1.symbol, SC_SYMBOL.toBytes32());
        assertEq(m1.decimals, 18);
        assertEq(m1.salt, SC_SALT);
        assertEq(m1.hook, SC_HOOK);

        MessageLib.UpdateContract memory m2 = MessageLib.deserializeUpdateContract(cv.lastMessages(2));
        assertEq(m2.scId, scId.raw());
        assertEq(m2.target, bytes32("target"));

        MessageLib.UpdateContractVaultUpdate memory m3 = MessageLib.deserializeUpdateContractVaultUpdate(m2.payload);
        assertEq(m3.assetId, USDC_C2.raw());
        assertEq(m3.vaultOrFactory, bytes32("factory"));
        assertEq(m3.kind, uint8(VaultUpdateKind.DeployAndLink));

        cv.resetMessages();
    }

    /// forge-config: default.isolate = true
    function testDeposit() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testPoolCreation();

        cv.requestDeposit(poolId, scId, USDC_C2, INVESTOR, INVESTOR_AMOUNT);

        IERC7726 valuation = holdings.valuation(poolId, scId, USDC_C2);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.approveDeposits.selector, scId, USDC_C2, APPROVED_INVESTOR_AMOUNT, valuation
        );
        cs[c++] = abi.encodeWithSelector(poolRouter.issueShares.selector, scId, USDC_C2, NAV_PER_SHARE);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolRouter.execute(poolId, cs);

        vm.prank(ANY);
        vm.deal(ANY, GAS);
        poolRouter.claimDeposit{value: GAS}(poolId, scId, USDC_C2, INVESTOR);

        MessageLib.FulfilledDepositRequest memory m0 = MessageLib.deserializeFulfilledDepositRequest(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.investor, INVESTOR);
        assertEq(m0.assetId, USDC_C2.raw());
        assertEq(m0.assetAmount, APPROVED_INVESTOR_AMOUNT);
        assertEq(m0.shareAmount, SHARE_AMOUNT);

        cv.resetMessages();
    }

    /// forge-config: default.isolate = true
    function testRedeem() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testDeposit();

        cv.requestRedeem(poolId, scId, USDC_C2, INVESTOR, SHARE_AMOUNT);

        IERC7726 valuation = holdings.valuation(poolId, scId, USDC_C2);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.approveRedeems.selector, scId, USDC_C2, APPROVED_SHARE_AMOUNT);
        cs[c++] = abi.encodeWithSelector(poolRouter.revokeShares.selector, scId, USDC_C2, NAV_PER_SHARE, valuation);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolRouter.execute(poolId, cs);

        vm.prank(ANY);
        vm.deal(ANY, GAS);
        poolRouter.claimRedeem{value: GAS}(poolId, scId, USDC_C2, INVESTOR);

        MessageLib.FulfilledRedeemRequest memory m0 = MessageLib.deserializeFulfilledRedeemRequest(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.investor, INVESTOR);
        assertEq(m0.assetId, USDC_C2.raw());
        assertEq(
            m0.assetAmount,
            NAV_PER_SHARE.mulUint128(uint128(valuation.getQuote(APPROVED_SHARE_AMOUNT, USD.addr(), USDC_C2.addr())))
        );
        assertEq(m0.shareAmount, APPROVED_SHARE_AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testExecuteNoSendNoPay() public {
        vm.startPrank(FM);

        PoolId poolId = poolRouter.createPool(FM, USD, multiShareClass);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, "");

        poolRouter.execute(poolId, cs);

        // Check no messages were sent as intended
        assertEq(cv.messageCount(), 0);
    }

    /// forge-config: default.isolate = true
    function testExecuteSendNoPay() public {
        vm.startPrank(FM);

        PoolId poolId = poolRouter.createPool(FM, USD, multiShareClass);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);

        vm.expectRevert(bytes("Gateway/cannot-topup-with-nothing"));
        poolRouter.execute(poolId, cs);
    }

    /// Test the following:
    /// - multicall()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///   - execute(poolB)
    ///      - notifyPool()
    ///
    /// will pay only for one message. The batch sent is [NotifyPool, NotifyPool].
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticall() public {
        vm.startPrank(FM);

        PoolId poolA = poolRouter.createPool(FM, USD, multiShareClass);
        PoolId poolB = poolRouter.createPool(FM, USD, multiShareClass);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolA, innerCalls);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolB, innerCalls);
        assertEq(c, cs.length);

        poolRouter.multicall{value: GAS}(cs);
    }

    function testCalUpdateJournal() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();

        AccountId extraAccountId = newAccountId(123, uint8(AccountType.ASSET));

        (bytes[] memory cs, uint256 c) = (new bytes[](1), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.createAccount.selector, extraAccountId, true);
        vm.prank(FM);
        poolRouter.execute(poolId, cs);

        (JournalEntry[] memory debits, uint256 i) = (new JournalEntry[](3), 0);
        debits[i++] = JournalEntry(1000, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.ASSET)));
        debits[i++] = JournalEntry(250, extraAccountId);
        debits[i++] = JournalEntry(130, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EQUITY)));

        (JournalEntry[] memory credits, uint256 j) = (new JournalEntry[](2), 0);
        credits[j++] = JournalEntry(1250, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EQUITY)));
        credits[j++] = JournalEntry(130, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.LOSS)));

        cv.updateJournal(poolId, scId, debits, credits);
    }

    function testCalUpdateHolding() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();
        uint128 poolDecimals = (10 ** assetRegistry.decimals(USD.raw())).toUint128();
        uint128 assetDecimals = (10 ** assetRegistry.decimals(USDC_C2.raw())).toUint128();

        JournalEntry[] memory debits = new JournalEntry[](0);
        (JournalEntry[] memory credits, uint256 i) = (new JournalEntry[](1), 0);
        credits[i++] =
            JournalEntry(130 * poolDecimals, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.GAIN)));

        cv.updateHolding(poolId, scId, USDC_C2, 1000 * assetDecimals, D18.wrap(1e18), true, debits, credits);
        assertEq(holdings.amount(poolId, scId, USDC_C2), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 1000 * poolDecimals);
        assertEq(
            accounting.accountValue(poolId, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.GAIN))),
            int128(130 * poolDecimals)
        );
        assertEq(
            accounting.accountValue(poolId, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EQUITY))),
            int128(870 * poolDecimals)
        );

        extensionCalUpdateHoldingLoss(poolId, scId, poolDecimals, assetDecimals);
    }

    function extensionCalUpdateHoldingLoss(
        PoolId poolId,
        ShareClassId scId,
        uint128 poolDecimals,
        uint128 assetDecimals
    ) public {
        (JournalEntry[] memory debits, uint256 j) = (new JournalEntry[](1), 0);
        debits[j++] =
            JournalEntry(12 * poolDecimals, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EXPENSE)));
        (JournalEntry[] memory credits, uint256 k) = (new JournalEntry[](1), 0);
        credits[k++] =
            JournalEntry(12 * poolDecimals, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.LOSS)));

        cv.updateHolding(poolId, scId, USDC_C2, 500 * assetDecimals, D18.wrap(1e18), false, debits, credits);

        assertEq(holdings.amount(poolId, scId, USDC_C2), 500 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 500 * poolDecimals);
        assertEq(
            accounting.accountValue(poolId, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.LOSS))),
            int128(12 * poolDecimals)
        );
        assertEq(
            accounting.accountValue(poolId, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EXPENSE))),
            int128(12 * poolDecimals)
        );
        assertEq(
            accounting.accountValue(poolId, holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.EQUITY))),
            // 1000 - 130 - (500-12) = 382
            int128(382 * poolDecimals)
        );
    }

    function testCalUpdateShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();

        cv.updateShares(poolId, scId, 100, true);

        (uint128 totalIssuance,) = multiShareClass.metrics(scId);
        assertEq(totalIssuance, 100);

        cv.updateShares(poolId, scId, 45, false);

        (uint128 totalIssuance2,) = multiShareClass.metrics(scId);
        assertEq(totalIssuance2, 55);
    }
}
