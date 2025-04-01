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
import {newPoolId} from "src/common/types/PoolId.sol";

// core contracts
import {AsyncRequests} from "src/vaults/AsyncRequests.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {VaultKind} from "src/vaults/interfaces/IVaultManager.sol";

// scripts
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

// mocks
import {MockCentrifugeChain} from "test/vaults/mocks/MockCentrifugeChain.sol";
import {MockGasService} from "test/common/mocks/MockGasService.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {MockSafe} from "test/vaults/mocks/MockSafe.sol";

// test env
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract BaseTest is VaultsDeployer, GasSnapshot, Test {
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
    uint64 immutable POOL_A = newPoolId(OTHER_CHAIN_ID, 1).raw();
    uint256 public erc20TokenId = 0;
    uint256 public defaultErc6909TokenId = 16;
    uint128 public defaultAssetId = newAssetId(THIS_CHAIN_ID, 1).raw();
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;
    uint32 public defaultPoolId = 5;
    bytes16 public defaultShareClassId = bytes16(bytes("1"));

    function setUp() public virtual {
        // We should not use the block ChainID
        vm.chainId(BLOCK_CHAIN_ID);

        // make yourself owner of the adminSafe
        address[] memory pausers = new address[](1);
        pausers[0] = self;
        ISafe adminSafe = new MockSafe(pausers, 1);

        // deploy core contracts
        deployVaults(THIS_CHAIN_ID, adminSafe, address(this));

        // deploy mock adapters

        adapter1 = new MockAdapter(gateway);
        adapter2 = new MockAdapter(gateway);
        adapter3 = new MockAdapter(gateway);

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(adapter1);
        testAdapters.push(adapter2);
        testAdapters.push(adapter3);

        // wire contracts
        wire(adapter1, address(this));
        // remove deployer access
        // removeVaultsDeployerAccess(address(adapter)); // need auth permissions in tests

        centrifugeChain = new MockCentrifugeChain(testAdapters, poolManager);
        mockedGasService = new MockGasService();
        erc20 = _newErc20("X's Dollar", "USDX", 6);
        erc6909 = new MockERC6909();

        gateway.file("adapters", testAdapters);
        gateway.file("gasService", address(mockedGasService));

        mockedGasService.setReturn("estimate", uint256(0.5 gwei));
        mockedGasService.setReturn("shouldRefuel", true);

        // Label contracts
        vm.label(address(root), "Root");
        vm.label(address(asyncRequests), "AsyncRequests");
        vm.label(address(asyncRequests), "SyncRequests");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(balanceSheetManager), "BalanceSheetManager");
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
        vm.label(address(escrow), "Escrow");
        vm.label(address(routerEscrow), "RouterEscrow");
        vm.label(address(guardian), "Guardian");
        vm.label(address(poolManager.tokenFactory()), "TokenFactory");
        vm.label(address(asyncVaultFactory), "AsyncVaultFactory");
        vm.label(address(syncDepositVaultFactory), "SyncDepositVaultFactory");

        // Exclude predeployed contracts from invariant tests by default
        excludeContract(address(root));
        excludeContract(address(asyncRequests));
        excludeContract(address(syncRequests));
        excludeContract(address(balanceSheetManager));
        excludeContract(address(poolManager));
        excludeContract(address(gateway));
        excludeContract(address(erc20));
        excludeContract(address(erc6909));
        excludeContract(address(centrifugeChain));
        excludeContract(address(vaultRouter));
        excludeContract(address(adapter1));
        excludeContract(address(adapter2));
        excludeContract(address(adapter3));
        excludeContract(address(escrow));
        excludeContract(address(routerEscrow));
        excludeContract(address(guardian));
        excludeContract(address(poolManager.tokenFactory()));
        excludeContract(address(asyncVaultFactory));
        excludeContract(address(syncDepositVaultFactory));
    }

    // helpers
    function deployVault(
        VaultKind vaultKind,
        uint64 poolId,
        uint8 shareTokenDecimals,
        address hook,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 scId,
        address asset,
        uint256 assetTokenId,
        uint16 destinationChain
    ) public returns (address vaultAddress, uint128 assetId) {
        if (poolManager.assetToId(asset, assetTokenId) == 0) {
            assetId = poolManager.registerAsset(asset, assetTokenId, destinationChain);
        } else {
            assetId = poolManager.assetToId(asset, assetTokenId);
        }

        if (poolManager.token(poolId, scId) == address(0)) {
            centrifugeChain.addPool(poolId);
            centrifugeChain.addShareClass(poolId, scId, tokenName, tokenSymbol, shareTokenDecimals, hook);
        }

        poolManager.updateSharePrice(poolId, scId, assetId, uint128(10 ** 18), uint64(block.timestamp));

        // Trigger new vault deployment via UpdateContract
        bytes32 vaultFactory = _vaultKindToVaultFactory(vaultKind);
        bytes memory vaultUpdate = MessageLib.UpdateContractVaultUpdate({
            vaultOrFactory: vaultFactory,
            assetId: assetId,
            kind: uint8(VaultUpdateKind.DeployAndLink)
        }).serialize();
        poolManager.update(poolId, scId, vaultUpdate);
        vaultAddress = IShareToken(poolManager.token(poolId, scId)).vault(asset);
    }

    function deployVault(
        VaultKind vaultKind,
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 scId
    ) public returns (address vaultAddress, uint128 assetId) {
        return deployVault(
            vaultKind,
            poolId,
            decimals,
            restrictionManager,
            tokenName,
            tokenSymbol,
            scId,
            address(erc20),
            erc20TokenId,
            OTHER_CHAIN_ID
        );
    }

    function deploySimpleVault(VaultKind vaultKind) public returns (address vaultAddress, uint128 assetId) {
        return deployVault(
            vaultKind,
            POOL_A,
            6,
            restrictionManager,
            "name",
            "symbol",
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
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), _investor, type(uint64).max);
        vm.startPrank(_investor);
        erc20.approve(_vault, amount); // add allowance
        vault.requestDeposit(amount, _investor, _investor);
        // trigger executed collectInvest
        uint128 assetId = poolManager.assetToId(address(erc20), erc20TokenId);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(_investor)), assetId, uint128(amount), uint128(amount)
        );

        if (claimDeposit) {
            vault.deposit(amount, _investor);
        }
        vm.stopPrank();
    }

    // Helpers
    function _addressToBytes32(address x) internal pure returns (bytes32) {
        return bytes32(bytes20(x));
    }

    function _newErc20(string memory name, string memory symbol, uint8 decimals) internal returns (ERC20) {
        ERC20 asset = new ERC20(decimals);
        asset.file("name", name);
        asset.file("symbol", symbol);
        return asset;
    }

    function _bytes16ToString(bytes16 _bytes16) public pure returns (string memory) {
        uint8 i = 0;
        while (i < 16 && _bytes16[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 16 && _bytes16[i] != 0; i++) {
            bytesArray[i] = _bytes16[i];
        }
        return string(bytesArray);
    }

    function _uint256ToString(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function random(uint256 maxValue, uint256 nonce) internal view returns (uint256) {
        if (maxValue == 1) {
            return maxValue;
        }
        uint256 randomnumber = uint256(keccak256(abi.encodePacked(block.timestamp, self, nonce))) % (maxValue - 1);
        return randomnumber + 1;
    }

    function _vaultKindToVaultFactory(VaultKind vaultKind) internal view returns (bytes32 vaultFactoryBytes) {
        address vaultFactory;

        if (vaultKind == VaultKind.Async) {
            vaultFactory = asyncVaultFactory;
        } else if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            vaultFactory = syncDepositVaultFactory;
        } else {
            revert("BaseTest/unsupported-vault-kind");
        }

        return bytes32(bytes20(vaultFactory));
    }

    // assumptions
    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }

    function addressAssumption(address user) public view returns (bool) {
        return (user != address(0) && user != address(erc20) && user.code.length == 0);
    }
}
