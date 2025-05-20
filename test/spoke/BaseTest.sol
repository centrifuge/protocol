// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import "src/misc/interfaces/IERC20.sol";
import {IERC6909Fungible} from "src/misc/interfaces/IERC6909.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

import {MessageType, MessageLib, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {newAssetId} from "src/common/types/AssetId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {MESSAGE_COST_ENV} from "script/CommonDeployer.s.sol";

// core contracts
import {AsyncRequestManager} from "src/spoke/vaults/AsyncRequestManager.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {Escrow} from "src/spoke/Escrow.sol";
import {AsyncVaultFactory} from "src/spoke/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {AsyncVault} from "src/spoke/vaults/AsyncVault.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {IVaultFactory} from "src/spoke/interfaces/factories/IVaultFactory.sol";
import {VaultKind} from "src/spoke/interfaces/vaults/IBaseVaults.sol";

// scripts
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

// mocks
import {MockCentrifugeChain} from "test/spoke/mocks/MockCentrifugeChain.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {MockSafe} from "test/spoke/mocks/MockSafe.sol";

// test env
import "forge-std/Test.sol";

contract BaseTest is SpokeDeployer, Test {
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

    uint128 constant MAX_UINT128 = type(uint128).max;
    uint64 constant MAX_UINT64 = type(uint64).max;

    // default values
    uint16 public constant OTHER_CHAIN_ID = 1;
    uint16 public constant THIS_CHAIN_ID = OTHER_CHAIN_ID + 100;
    uint32 public constant BLOCK_CHAIN_ID = 23;
    PoolId public immutable POOL_A = newPoolId(OTHER_CHAIN_ID, 1);
    uint256 public constant ESTIMATE_ADAPTER_1 = 1 gwei;
    uint256 public constant ESTIMATE_ADAPTER_2 = 1.25 gwei;
    uint256 public constant ESTIMATE_ADAPTER_3 = 1.75 gwei;
    uint256 public constant ESTIMATE_ADAPTERS = ESTIMATE_ADAPTER_1 + ESTIMATE_ADAPTER_2 + ESTIMATE_ADAPTER_3;
    uint256 public constant GAS_COST_LIMIT = 0.5 gwei;
    uint256 public constant DEFAULT_GAS = ESTIMATE_ADAPTERS + GAS_COST_LIMIT * 3;
    uint256 public constant DEFAULT_SUBSIDY = DEFAULT_GAS * 100;

    uint256 public erc20TokenId = 0;
    uint256 public defaultErc6909TokenId = 16;
    uint128 public defaultAssetId = newAssetId(THIS_CHAIN_ID, 1).raw();
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;
    bytes16 public defaultShareClassId = bytes16(bytes("1"));

    function setUp() public virtual {
        // We should not use the block ChainID
        vm.chainId(BLOCK_CHAIN_ID);

        // make yourself owner of the adminSafe
        address[] memory pausers = new address[](1);
        pausers[0] = self;
        ISafe adminSafe = new MockSafe(pausers, 1);

        // deploy core contracts
        vm.setEnv(MESSAGE_COST_ENV, vm.toString(GAS_COST_LIMIT));
        deploySpoke(THIS_CHAIN_ID, adminSafe, address(this), true);
        guardian.file("safe", address(adminSafe));

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

        // wire contracts
        wire(OTHER_CHAIN_ID, adapter1, address(this));
        // remove deployer access
        // removeSpokeDeployerAccess(address(adapter)); // need auth permissions in tests

        centrifugeChain = new MockCentrifugeChain(testAdapters, spoke, syncRequestManager);
        erc20 = _newErc20("X's Dollar", "USDX", 6);
        erc6909 = new MockERC6909();

        multiAdapter.file("adapters", OTHER_CHAIN_ID, testAdapters);

        // Label contracts
        vm.label(address(root), "Root");
        vm.label(address(asyncRequestManager), "AsyncRequestManager");
        vm.label(address(syncRequestManager), "SyncRequestManager");
        vm.label(address(spoke), "Spoke");
        vm.label(address(balanceSheet), "BalanceSheet");
        vm.label(address(gateway), "Gateway");
        vm.label(address(messageProcessor), "MessageProcessor");
        vm.label(address(messageDispatcher), "MessageDispatcher");
        vm.label(address(adapter1), "MockAdapter1");
        vm.label(address(adapter2), "MockAdapter2");
        vm.label(address(adapter3), "MockAdapter3");
        vm.label(address(erc20), "ERC20");
        vm.label(address(erc6909), "ERC6909");
        vm.label(address(centrifugeChain), "CentrifugeChain");
        vm.label(address(vaultRouter), "VaultRouter");
        vm.label(address(gasService), "GasService");
        vm.label(address(routerEscrow), "RouterEscrow");
        vm.label(address(guardian), "Guardian");
        vm.label(address(spoke.tokenFactory()), "TokenFactory");
        vm.label(address(asyncVaultFactory), "AsyncVaultFactory");
        vm.label(address(syncDepositVaultFactory), "SyncDepositVaultFactory");
        vm.label(address(poolEscrowFactory), "PoolEscrowFactory");

        // Exclude predeployed contracts from invariant tests by default
        excludeContract(address(root));
        excludeContract(address(asyncRequestManager));
        excludeContract(address(syncRequestManager));
        excludeContract(address(balanceSheet));
        excludeContract(address(spoke));
        excludeContract(address(gateway));
        excludeContract(address(erc20));
        excludeContract(address(erc6909));
        excludeContract(address(centrifugeChain));
        excludeContract(address(vaultRouter));
        excludeContract(address(adapter1));
        excludeContract(address(adapter2));
        excludeContract(address(adapter3));
        excludeContract(address(routerEscrow));
        excludeContract(address(guardian));
        excludeContract(address(spoke.tokenFactory()));
        excludeContract(address(asyncVaultFactory));
        excludeContract(address(syncDepositVaultFactory));
        excludeContract(address(poolEscrowFactory));
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

        bytes32 vaultFactory = _vaultKindToVaultFactory(vaultKind);

        // Trigger new vault deployment via UpdateContract
        spoke.update(
            POOL_A,
            ShareClassId.wrap(scId),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: vaultFactory,
                assetId: assetId,
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
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
        return
            deployVault(vaultKind, decimals, fullRestrictionsHook, scId, address(erc20), erc20TokenId, OTHER_CHAIN_ID);
    }

    function deploySimpleVault(VaultKind vaultKind)
        public
        returns (uint64 poolId, address vaultAddress, uint128 assetId)
    {
        return deployVault(
            vaultKind, 6, fullRestrictionsHook, bytes16(bytes("1")), address(erc20), erc20TokenId, OTHER_CHAIN_ID
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

    function _vaultKindToVaultFactory(VaultKind vaultKind) internal view returns (bytes32 vaultFactoryBytes) {
        IVaultFactory vaultFactory;

        if (vaultKind == VaultKind.Async) {
            vaultFactory = asyncVaultFactory;
        } else if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            vaultFactory = syncDepositVaultFactory;
        } else {
            revert("BaseTest/unsupported-vault-kind");
        }

        return bytes32(bytes20(address(vaultFactory)));
    }

    // assumptions
    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }
}
