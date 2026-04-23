// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Re-exported for test files importing from VaultBaseTest

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC6909Fungible} from "../../../src/misc/interfaces/IERC6909.sol";

import {MockAdapter} from "../../core/mocks/MockAdapter.sol";

import {Spoke} from "../../../src/core/spoke/Spoke.sol";
import {PoolId, newPoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {VaultKind} from "../../../src/core/spoke/interfaces/IVault.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {VaultDetails} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";
import {VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";
import {MAX_MESSAGE_COST} from "../../../src/core/messaging/interfaces/IGasService.sol";
import {IVaultFactory} from "../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {SyncDepositVault} from "../../../src/vaults/SyncDepositVault.sol";
import {RequestCallbackMessageLib} from "../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import "forge-std/Test.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";

/// @dev Direct centrifuge chain simulator — calls spoke/vaultRegistry/syncManager directly as a ward
///      instead of routing through adapters. Replaces MockCentrifugeChain in VaultBaseTest.
contract MockCentrifugeChainDirect is Test {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;
    using RequestCallbackMessageLib for *;

    Spoke public spoke;
    VaultRegistry public vaultRegistry;
    SyncManager public syncManager;

    constructor(Spoke spoke_, VaultRegistry vaultRegistry_, SyncManager syncManager_) {
        spoke = spoke_;
        vaultRegistry = vaultRegistry_;
        syncManager = syncManager_;
    }

    function addPool(uint64 poolId) public {
        spoke.addPool(PoolId.wrap(poolId));
    }

    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public {
        spoke.addShareClass(PoolId.wrap(poolId), ShareClassId.wrap(scId), tokenName, tokenSymbol, decimals, salt, hook);
    }

    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, keccak256(abi.encodePacked(poolId, scId)), hook);
    }

    function updateMember(uint64 poolId, bytes16 scId, address user, uint64 validUntil) public {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(user.toBytes32(), validUntil).serialize()
        );
    }

    function freeze(uint64 poolId, bytes16 scId, address user) public {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze(user.toBytes32()).serialize()
        );
    }

    function unfreeze(uint64 poolId, bytes16 scId, address user) public {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(user.toBytes32()).serialize()
        );
    }

    function updatePricePoolPerShare(uint64 poolId, bytes16 scId, uint128 price, uint64 computedAt) public {
        spoke.updatePricePoolPerShare(PoolId.wrap(poolId), ShareClassId.wrap(scId), D18.wrap(price), computedAt);
    }

    function updatePricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 computedAt)
        public
    {
        spoke.updatePricePoolPerAsset(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), D18.wrap(price), computedAt
        );
    }

    function isFulfilledDepositRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) public {
        // NOTE: hardcoding pricePoolPerAsset to 1 (matching MockCentrifugeChain behaviour)
        isApprovedDeposits(poolId, scId, assetId, fulfilledAssetAmount, d18(1, 1));
        isIssuedShares(poolId, scId, assetId, fulfilledShareAmount, d18(1, 1));
        spoke.requestCallback(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            RequestCallbackMessageLib.FulfilledDepositRequest({
                    investor: investor,
                    fulfilledAssetAmount: fulfilledAssetAmount,
                    fulfilledShareAmount: fulfilledShareAmount,
                    cancelledAssetAmount: cancelledAssetAmount
                }).serialize()
        );
    }

    function isApprovedDeposits(uint64 poolId, bytes16 scId, uint128 assetId, uint128 assets, D18 pricePoolPerAsset)
        public
    {
        spoke.requestCallback(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            RequestCallbackMessageLib.ApprovedDeposits({
                    assetAmount: assets, pricePoolPerAsset: pricePoolPerAsset.raw()
                }).serialize()
        );
    }

    function isIssuedShares(uint64 poolId, bytes16 scId, uint128 assetId, uint128 shares, D18 pricePoolPerShare)
        public
    {
        spoke.requestCallback(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            RequestCallbackMessageLib.IssuedShares({shareAmount: shares, pricePoolPerShare: pricePoolPerShare.raw()})
                .serialize()
        );
    }

    function isFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) public {
        // NOTE: hardcoding pricePoolPerShare to 1 (matching MockCentrifugeChain behaviour)
        isRevokedShares(poolId, scId, assetId, fulfilledAssetAmount, fulfilledShareAmount, d18(1, 1));
        spoke.requestCallback(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            RequestCallbackMessageLib.FulfilledRedeemRequest({
                    investor: investor,
                    fulfilledAssetAmount: fulfilledAssetAmount,
                    fulfilledShareAmount: fulfilledShareAmount,
                    cancelledShareAmount: cancelledShareAmount
                }).serialize()
        );
    }

    function isRevokedShares(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assets,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) public {
        spoke.requestCallback(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            RequestCallbackMessageLib.RevokedShares({
                    assetAmount: assets, shareAmount: shareAmount, pricePoolPerShare: pricePoolPerShare.raw()
                }).serialize()
        );
    }

    function linkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vd = vaultRegistry.vaultDetails(IBaseVault(vault));
        vaultRegistry.linkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), vd.assetId, IBaseVault(vault));
    }

    function unlinkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vd = vaultRegistry.vaultDetails(IBaseVault(vault));
        vaultRegistry.unlinkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), vd.assetId, IBaseVault(vault));
    }

    function updateMaxReserve(uint64 poolId, bytes16 scId, address vault, uint128 maxReserve) public {
        VaultDetails memory vd = vaultRegistry.vaultDetails(IBaseVault(vault));
        syncManager.setMaxReserve(PoolId.wrap(poolId), ShareClassId.wrap(scId), vd.asset, vd.tokenId, maxReserve);
    }
}

/// @dev Replacement for BaseTest that uses CentrifugeIntegrationTest infrastructure instead of
///      MockCentrifugeChain + mock adapters for hub→spoke messages. Hub→spoke messages are sent
///      directly to spoke as a ward; spoke→hub messages still flow through real mock adapters
///      so adapter1.values_bytes("send") works for message assertions.
contract VaultBaseTest is CentrifugeIntegrationTest {
    MockCentrifugeChainDirect centrifugeChain;
    MockAdapter adapter1;
    MockAdapter adapter2;
    MockAdapter adapter3;
    IAdapter[] testAdapters;
    ERC20 public erc20;
    IERC6909Fungible public erc6909;

    address self = address(this);
    address investor = makeAddr("investor");
    address nonMember = makeAddr("nonMember");
    address randomUser = makeAddr("randomUser");
    uint128 constant MAX_UINT128 = type(uint128).max;
    uint64 constant MAX_UINT64 = type(uint64).max;

    uint16 public constant OTHER_CHAIN_ID = 1;
    uint16 public constant THIS_CHAIN_ID = LOCAL_CENTRIFUGE_ID;
    uint32 public constant BLOCK_CHAIN_ID = 23;
    PoolId public immutable POOL_A = newPoolId(OTHER_CHAIN_ID, 1);
    uint256 public constant ESTIMATE_ADAPTER_1 = 1_000_000;
    uint256 public constant ESTIMATE_ADAPTER_2 = 1_250_000;
    uint256 public constant ESTIMATE_ADAPTER_3 = 1_750_000;
    uint256 public constant ESTIMATE_ADAPTERS = ESTIMATE_ADAPTER_1 + ESTIMATE_ADAPTER_2 + ESTIMATE_ADAPTER_3;
    uint256 public constant GAS_COST_LIMIT = MAX_MESSAGE_COST;
    uint256 public constant DEFAULT_GAS = ESTIMATE_ADAPTERS + GAS_COST_LIMIT * 3;
    uint256 public constant VAULT_DEFAULT_SUBSIDY = DEFAULT_GAS * 100;

    uint256 public erc20TokenId = 0;
    uint256 public defaultErc6909TokenId = 16;
    uint128 public defaultAssetId = newAssetId(LOCAL_CENTRIFUGE_ID, 1).raw();
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;
    bytes16 public defaultShareClassId = bytes16(bytes("1"));

    receive() external payable {
        // For repayments used in registerAsset and crosschainTransferShares
    }

    function setUp() public virtual override {
        super.setUp(); // deploys FullDeployer with LOCAL_CENTRIFUGE_ID

        // Give address(this) auth on all relevant contracts
        vm.startPrank(address(root));
        gateway.rely(address(this));
        multiAdapter.rely(address(this));
        messageDispatcher.rely(address(this));
        messageProcessor.rely(address(this));
        poolEscrowFactory.rely(address(this));
        tokenFactory.rely(address(this));
        spoke.rely(address(this));
        balanceSheet.rely(address(this));
        contractUpdater.rely(address(this));
        vaultRegistry.rely(address(this));
        tokenRecoverer.rely(address(this));
        refundEscrowFactory.rely(address(this));
        asyncVaultFactory.rely(address(this));
        asyncRequestManager.rely(address(this));
        syncDepositVaultFactory.rely(address(this));
        syncManager.rely(address(this));
        vaultRouter.rely(address(this));
        freezeOnlyHook.rely(address(this));
        fullRestrictionsHook.rely(address(this));
        freelyTransferableHook.rely(address(this));
        redemptionRestrictionsHook.rely(address(this));
        vm.stopPrank();

        vm.prank(address(protocolGuardian));
        root.rely(address(this));

        // Deploy mock adapters for OTHER_CHAIN_ID so spoke→hub outgoing messages are captured
        adapter1 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);
        adapter2 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);
        adapter3 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);

        adapter1.setReturn("estimate", ESTIMATE_ADAPTER_1);
        adapter2.setReturn("estimate", ESTIMATE_ADAPTER_2);
        adapter3.setReturn("estimate", ESTIMATE_ADAPTER_3);

        testAdapters.push(adapter1);
        testAdapters.push(adapter2);
        testAdapters.push(adapter3);

        // Route outgoing messages through mock adapters
        multiAdapter.setAdapters(
            OTHER_CHAIN_ID, PoolId.wrap(0), testAdapters, uint8(testAdapters.length), uint8(testAdapters.length)
        );
        multiAdapter.setAdapters(
            OTHER_CHAIN_ID, POOL_A, testAdapters, uint8(testAdapters.length), uint8(testAdapters.length)
        );

        // Deploy direct chain simulator and give it auth on relevant contracts
        centrifugeChain = new MockCentrifugeChainDirect(spoke, vaultRegistry, syncManager);
        spoke.rely(address(centrifugeChain));
        vaultRegistry.rely(address(centrifugeChain));
        syncManager.rely(address(centrifugeChain));

        // Deploy test assets
        erc20 = _newErc20("X's Dollar", "USDX", 6);
        erc6909 = new MockERC6909();

        // Subsidy and balance sheet manager for POOL_A
        subsidyManager.deposit{value: 0.5 ether}(POOL_A);
        balanceSheet.updateManager(POOL_A, address(this), true);

        // Prevent confusion with block.chainid
        vm.chainId(BLOCK_CHAIN_ID);
    }

    // --- Helpers ---

    function deployVault(
        VaultKind vaultKind,
        uint8 shareTokenDecimals,
        address hook,
        bytes16 scId,
        address asset,
        uint256 assetTokenId,
        uint16 /* TODO: destinationChain */
    ) public returns (uint64 poolId, address vaultAddress, uint128 assetId) {
        try spoke.shareToken(POOL_A, ShareClassId.wrap(scId)) {}
        catch {
            if (spoke.pool(POOL_A) == 0) {
                centrifugeChain.addPool(POOL_A.raw());
            }
            centrifugeChain.addShareClass(POOL_A.raw(), scId, "name", "symbol", shareTokenDecimals, hook);
            centrifugeChain.updatePricePoolPerShare(POOL_A.raw(), scId, uint128(10 ** 18), uint64(block.timestamp));
        }

        try spoke.assetToId(asset, assetTokenId) {
            assetId = spoke.assetToId(asset, assetTokenId).raw();
        } catch {
            assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, assetTokenId, address(this)).raw();
            centrifugeChain.updatePricePoolPerAsset(
                POOL_A.raw(), scId, assetId, uint128(10 ** 18), uint64(block.timestamp)
            );
        }

        if (address(spoke.requestManager(POOL_A)) == address(0)) {
            spoke.setRequestManager(POOL_A, asyncRequestManager);
        }
        balanceSheet.updateManager(POOL_A, address(asyncRequestManager), true);
        balanceSheet.updateManager(POOL_A, address(syncManager), true);

        syncManager.setMaxReserve(POOL_A, ShareClassId.wrap(scId), asset, 0, type(uint128).max);

        IVaultFactory vaultFactory = _vaultKindToVaultFactory(vaultKind);
        vaultRegistry.updateVault(
            POOL_A, ShareClassId.wrap(scId), AssetId.wrap(assetId), address(vaultFactory), VaultUpdateKind.DeployAndLink
        );

        vaultAddress = IShareToken(spoke.shareToken(POOL_A, ShareClassId.wrap(scId))).vault(asset);
        poolId = POOL_A.raw();
    }

    function deployVault(VaultKind vaultKind, uint8 decimals, bytes16 scId)
        public
        returns (uint64 poolId, address vaultAddress, uint128 assetId)
    {
        return deployVault(
            vaultKind, decimals, address(fullRestrictionsHook), scId, address(erc20), erc20TokenId, OTHER_CHAIN_ID
        );
    }

    function deploySimpleVault(VaultKind vaultKind)
        public
        returns (uint64 poolId, address vaultAddress, uint128 assetId)
    {
        return deployVault(
            vaultKind,
            6,
            address(fullRestrictionsHook),
            bytes16(bytes("1")),
            address(erc20),
            erc20TokenId,
            OTHER_CHAIN_ID
        );
    }

    function deposit(address _vault, address _investor, uint256 amount) public {
        deposit(_vault, _investor, amount, true);
    }

    function deposit(address _vault, address _investor, uint256 amount, bool claimDeposit) public {
        AsyncVault vault = AsyncVault(_vault);
        erc20.mint(_investor, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), _investor, type(uint64).max);
        vm.startPrank(_investor);
        erc20.approve(_vault, amount);
        vault.requestDeposit(amount, _investor, _investor);
        uint128 assetId = spoke.assetToId(address(erc20), erc20TokenId).raw();
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(_investor)),
            assetId,
            uint128(amount),
            uint128(amount),
            0
        );
        if (claimDeposit) {
            vault.deposit(amount, _investor);
        }
        vm.stopPrank();
    }

    function depositSync(address _vault, address _investor, uint256 amount) public {
        SyncDepositVault vault = SyncDepositVault(_vault);
        ERC20 asset = ERC20(vault.asset());
        asset.mint(_investor, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), _investor, type(uint64).max);
        vm.startPrank(_investor);
        asset.approve(_vault, amount);
        vault.deposit(amount, _investor);
        vm.stopPrank();
    }

    function _newErc20(string memory name, string memory symbol, uint8 decimals) internal returns (ERC20) {
        ERC20 asset = new ERC20(decimals);
        asset.file("name", name);
        asset.file("symbol", symbol);
        return asset;
    }

    function random(uint256 maxValue, uint256 nonce) internal view returns (uint256) {
        if (maxValue == 1) return maxValue;
        uint256 randomnumber = uint256(keccak256(abi.encodePacked(block.timestamp, self, nonce))) % (maxValue - 1);
        return randomnumber + 1;
    }

    function _vaultKindToVaultFactory(VaultKind vaultKind) internal view returns (IVaultFactory vaultFactory) {
        if (vaultKind == VaultKind.Async) {
            vaultFactory = asyncVaultFactory;
        } else if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            vaultFactory = syncDepositVaultFactory;
        } else {
            revert("VaultBaseTest/unsupported-vault-kind");
        }
    }

    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }
}
