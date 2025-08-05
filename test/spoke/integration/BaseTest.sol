// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import "../../../src/misc/interfaces/IERC20.sol";
import {ERC20} from "../../../src/misc/ERC20.sol";
import {IERC6909Fungible} from "../../../src/misc/interfaces/IERC6909.sol";

import {MockAdapter} from "../../common/mocks/MockAdapter.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";
import {newAssetId} from "../../../src/common/types/AssetId.sol";
import {ISafe} from "../../../src/common/interfaces/IGuardian.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {PoolId, newPoolId} from "../../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST} from "../../../src/common/interfaces/IGasService.sol";
import {MessageLib, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";

import {VaultKind} from "../../../src/spoke/interfaces/IVault.sol";
import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";
import {IVaultFactory} from "../../../src/spoke/factories/interfaces/IVaultFactory.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";

import {
    ExtendedSpokeDeployer, ExtendedSpokeActionBatcher, CommonInput
} from "../../../script/ExtendedSpokeDeployer.s.sol";

import {MockCentrifugeChain} from "../mocks/MockCentrifugeChain.sol";

import "forge-std/Test.sol";

contract BaseTest is ExtendedSpokeDeployer, Test, ExtendedSpokeActionBatcher {
    using MessageLib for *;

    MockCentrifugeChain centrifugeChain;
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
    address immutable ADMIN = address(adminSafe);

    uint128 constant MAX_UINT128 = type(uint128).max;
    uint64 constant MAX_UINT64 = type(uint64).max;

    // default values
    uint16 public constant OTHER_CHAIN_ID = 1;
    uint16 public constant THIS_CHAIN_ID = OTHER_CHAIN_ID + 100;
    uint32 public constant BLOCK_CHAIN_ID = 23;
    PoolId public immutable POOL_A = newPoolId(OTHER_CHAIN_ID, 1);
    uint256 public constant ESTIMATE_ADAPTER_1 = 1_000_000; // 1M gas
    uint256 public constant ESTIMATE_ADAPTER_2 = 1_250_000; // 1.25M gas
    uint256 public constant ESTIMATE_ADAPTER_3 = 1_750_000; // 1.75M gas
    uint256 public constant ESTIMATE_ADAPTERS = ESTIMATE_ADAPTER_1 + ESTIMATE_ADAPTER_2 + ESTIMATE_ADAPTER_3;
    uint256 public constant GAS_COST_LIMIT = MAX_MESSAGE_COST; // 3M gas
    uint256 public constant DEFAULT_GAS = ESTIMATE_ADAPTERS + GAS_COST_LIMIT * 3;
    uint256 public constant DEFAULT_SUBSIDY = DEFAULT_GAS * 100;

    uint256 public erc20TokenId = 0;
    uint256 public defaultErc6909TokenId = 16;
    uint128 public defaultAssetId = newAssetId(THIS_CHAIN_ID, 1).raw();
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;
    bytes16 public defaultShareClassId = bytes16(bytes("1"));

    function setUp() public virtual {
        // deploy core contracts
        CommonInput memory input = CommonInput({
            centrifugeId: THIS_CHAIN_ID,
            adminSafe: ISafe(ADMIN),
            maxBatchGasLimit: uint128(GAS_COST_LIMIT) * 100,
            version: bytes32(0)
        });

        setDeployer(address(this));
        labelAddresses("");
        deployExtendedSpoke(input, this);
        // removeExtendedSpokeDeployerAccess(address(adapter)); // need auth permissions in tests

        // deploy mock adapters
        adapter1 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);
        adapter2 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);
        adapter3 = new MockAdapter(OTHER_CHAIN_ID, multiAdapter);

        adapter1.setReturn("estimate", ESTIMATE_ADAPTER_1);
        adapter2.setReturn("estimate", ESTIMATE_ADAPTER_2);
        adapter3.setReturn("estimate", ESTIMATE_ADAPTER_3);

        testAdapters.push(adapter1);
        testAdapters.push(adapter2);
        testAdapters.push(adapter3);

        centrifugeChain = new MockCentrifugeChain(testAdapters, spoke, syncManager);
        erc20 = _newErc20("X's Dollar", "USDX", 6);
        erc6909 = new MockERC6909();

        multiAdapter.file("adapters", OTHER_CHAIN_ID, testAdapters);

        // We should not use the block ChainID
        vm.chainId(BLOCK_CHAIN_ID);
    }

    // helpers
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
            if (spoke.pools(POOL_A) == 0) {
                centrifugeChain.addPool(POOL_A.raw());
            }
            centrifugeChain.addShareClass(POOL_A.raw(), scId, "name", "symbol", shareTokenDecimals, hook);
            centrifugeChain.updatePricePoolPerShare(POOL_A.raw(), scId, uint128(10 ** 18), uint64(block.timestamp));
        }

        try spoke.assetToId(asset, assetTokenId) {
            assetId = spoke.assetToId(asset, assetTokenId).raw();
        } catch {
            assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, assetTokenId).raw();
            centrifugeChain.updatePricePoolPerAsset(
                POOL_A.raw(), scId, assetId, uint128(10 ** 18), uint64(block.timestamp)
            );
        }

        spoke.setRequestManager(POOL_A, ShareClassId.wrap(scId), AssetId.wrap(assetId), asyncRequestManager);
        balanceSheet.updateManager(POOL_A, address(asyncRequestManager), true);
        balanceSheet.updateManager(POOL_A, address(syncManager), true);

        syncManager.setMaxReserve(POOL_A, ShareClassId.wrap(scId), asset, 0, type(uint128).max);

        IVaultFactory vaultFactory = _vaultKindToVaultFactory(vaultKind);

        spoke.updateVault(
            POOL_A, ShareClassId.wrap(scId), AssetId.wrap(assetId), address(vaultFactory), VaultUpdateKind.DeployAndLink
        );

        vaultAddress = IShareToken(spoke.shareToken(POOL_A, ShareClassId.wrap(scId))).vault(asset);
        poolId = POOL_A.raw();

        gateway.setRefundAddress(POOL_A, gateway);
        gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
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
        erc20.approve(_vault, amount); // add allowance
        vault.requestDeposit(amount, _investor, _investor);
        // trigger executed collectInvest
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

    // Helpers
    function _newErc20(string memory name, string memory symbol, uint8 decimals) internal returns (ERC20) {
        ERC20 asset = new ERC20(decimals);
        asset.file("name", name);
        asset.file("symbol", symbol);
        return asset;
    }

    function random(uint256 maxValue, uint256 nonce) internal view returns (uint256) {
        if (maxValue == 1) {
            return maxValue;
        }
        uint256 randomnumber = uint256(keccak256(abi.encodePacked(block.timestamp, self, nonce))) % (maxValue - 1);
        return randomnumber + 1;
    }

    function _vaultKindToVaultFactory(VaultKind vaultKind) internal view returns (IVaultFactory vaultFactory) {
        if (vaultKind == VaultKind.Async) {
            vaultFactory = asyncVaultFactory;
        } else if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            vaultFactory = syncDepositVaultFactory;
        } else {
            revert("BaseTest/unsupported-vault-kind");
        }

        return vaultFactory;
    }

    // assumptions
    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }
}
