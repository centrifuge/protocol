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

// core contracts
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

// scripts
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

// mocks
import {MockCentrifugeChain} from "test/vaults/mocks/MockCentrifugeChain.sol";
import {MockGasService} from "test/common/mocks/MockGasService.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {MockSafe} from "test/vaults/mocks/MockSafe.sol";

// test env
import "forge-std/Test.sol";

contract BaseTest is VaultsDeployer, Test {
    using MessageLib for *;

    MockCentrifugeChain centrifugeChain;
    MockGasService mockedGasService;
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
    uint256 public defaultGas;
    uint256 public defaultSubsidy;
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
        deployVaults(THIS_CHAIN_ID, adminSafe, address(this), true);
        guardian.file("safe", address(adminSafe));

        // deploy mock adapters
        adapter1 = new MockAdapter(OTHER_CHAIN_ID, gateway);
        adapter2 = new MockAdapter(OTHER_CHAIN_ID, gateway);
        adapter3 = new MockAdapter(OTHER_CHAIN_ID, gateway);

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(adapter1);
        testAdapters.push(adapter2);
        testAdapters.push(adapter3);

        // wire contracts
        wire(OTHER_CHAIN_ID, adapter1, address(this));
        // remove deployer access
        // removeVaultsDeployerAccess(address(adapter)); // need auth permissions in tests

        centrifugeChain = new MockCentrifugeChain(testAdapters, poolManager, syncRequestManager);
        mockedGasService = new MockGasService();
        erc20 = _newErc20("X's Dollar", "USDX", 6);
        erc6909 = new MockERC6909();

        gateway.file("adapters", OTHER_CHAIN_ID, testAdapters);
        gateway.file("gasService", address(mockedGasService));

        mockedGasService.setReturn("estimate", uint256(0.5 gwei));

        defaultGas = gateway.estimate(OTHER_CHAIN_ID, MessageLib.NotifyPool(1).serialize());
        defaultSubsidy = defaultGas * 100;

        // Label contracts
        vm.label(address(root), "Root");
        vm.label(address(asyncRequestManager), "AsyncRequestManager");
        vm.label(address(syncRequestManager), "SyncRequestManager");
        vm.label(address(poolManager), "PoolManager");
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
        vm.label(address(mockedGasService), "MockGasService");
        vm.label(address(routerEscrow), "RouterEscrow");
        vm.label(address(guardian), "Guardian");
        vm.label(address(poolManager.tokenFactory()), "TokenFactory");
        vm.label(address(asyncVaultFactory), "AsyncVaultFactory");
        vm.label(address(syncDepositVaultFactory), "SyncDepositVaultFactory");
        vm.label(address(poolEscrowFactory), "PoolEscrowFactory");

        // Exclude predeployed contracts from invariant tests by default
        excludeContract(address(root));
        excludeContract(address(asyncRequestManager));
        excludeContract(address(syncRequestManager));
        excludeContract(address(balanceSheet));
        excludeContract(address(poolManager));
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
        excludeContract(address(poolManager.tokenFactory()));
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
        try poolManager.shareToken(POOL_A, ShareClassId.wrap(scId)) {}
        catch {
            if (poolManager.pools(POOL_A) == 0) {
                centrifugeChain.addPool(POOL_A.raw());
            }
            centrifugeChain.addShareClass(POOL_A.raw(), scId, "name", "symbol", shareTokenDecimals, hook);
            centrifugeChain.updatePricePoolPerShare(POOL_A.raw(), scId, uint128(10 ** 18), uint64(block.timestamp));
        }

        try poolManager.assetToId(asset, assetTokenId) {
            assetId = poolManager.assetToId(asset, assetTokenId).raw();
        } catch {
            assetId = poolManager.registerAsset{value: defaultGas}(OTHER_CHAIN_ID, asset, assetTokenId).raw();
            centrifugeChain.updatePricePoolPerAsset(
                POOL_A.raw(), scId, assetId, uint128(10 ** 18), uint64(block.timestamp)
            );
        }

        bytes32 vaultFactory = _vaultKindToVaultFactory(vaultKind);

        // Trigger new vault deployment via UpdateContract
        poolManager.update(
            POOL_A,
            ShareClassId.wrap(scId),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: vaultFactory,
                assetId: assetId,
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );
        vaultAddress = IShareToken(poolManager.shareToken(POOL_A, ShareClassId.wrap(scId))).vault(asset);
        poolId = POOL_A.raw();

        gateway.setRefundAddress(POOL_A, gateway);
        gateway.subsidizePool{value: defaultSubsidy}(POOL_A);
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
        uint128 assetId = poolManager.assetToId(address(erc20), erc20TokenId).raw();
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(_investor)),
            assetId,
            uint128(amount),
            uint128(amount)
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
