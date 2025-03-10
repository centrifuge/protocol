// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import "src/misc/interfaces/IERC20.sol";
import {ERC20} from "src/misc/ERC20.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {Root} from "src/common/Root.sol";

// core contracts
import {InvestmentManager} from "src/vaults/InvestmentManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {Tranche} from "src/vaults/token/Tranche.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {Gateway} from "src/vaults/gateway/Gateway.sol";
import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {Deployer} from "script/vaults/Deployer.sol";
import {MockSafe} from "test/vaults/mocks/MockSafe.sol";

// mocks
import {MockCentrifugeChain} from "test/vaults/mocks/MockCentrifugeChain.sol";
import {MockGasService} from "test/vaults/mocks/MockGasService.sol";
import {MockAdapter} from "test/vaults/mocks/MockAdapter.sol";

// test env
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract BaseTest is Deployer, GasSnapshot, Test {
    MockCentrifugeChain centrifugeChain;
    MockGasService mockedGasService;
    MockAdapter adapter1;
    MockAdapter adapter2;
    MockAdapter adapter3;
    address[] testAdapters;
    ERC20 public erc20;

    address self = address(this);
    address investor = makeAddr("investor");
    address nonMember = makeAddr("nonMember");
    address randomUser = makeAddr("randomUser");

    uint128 constant MAX_UINT128 = type(uint128).max;
    uint256 constant GATEWAY_INITIAL_BALACE = 10 ether;

    // default values
    uint128 public defaultAssetId = 1;
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;

    function setUp() public virtual {
        vm.chainId(1);

        // make yourself owner of the adminSafe
        address[] memory pausers = new address[](1);
        pausers[0] = self;
        adminSafe = new MockSafe(pausers, 1);

        // deploy core contracts
        deploy(address(this));

        // deploy mock adapters

        adapter1 = new MockAdapter(address(gateway));
        adapter2 = new MockAdapter(address(gateway));
        adapter3 = new MockAdapter(address(gateway));

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(address(adapter1));
        testAdapters.push(address(adapter2));
        testAdapters.push(address(adapter3));

        // wire contracts
        wire(address(adapter1));
        // remove deployer access
        // removeDeployerAccess(address(adapter)); // need auth permissions in tests

        centrifugeChain = new MockCentrifugeChain(testAdapters);
        mockedGasService = new MockGasService();
        erc20 = _newErc20("X's Dollar", "USDX", 6);

        gateway.file("adapters", testAdapters);
        gateway.file("gasService", address(mockedGasService));
        vm.deal(address(gateway), GATEWAY_INITIAL_BALACE);

        mockedGasService.setReturn("estimate", uint256(0.5 gwei));
        mockedGasService.setReturn("shouldRefuel", true);

        // Label contracts
        vm.label(address(root), "Root");
        vm.label(address(investmentManager), "InvestmentManager");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(gateway), "Gateway");
        vm.label(address(adapter1), "MockAdapter1");
        vm.label(address(adapter2), "MockAdapter2");
        vm.label(address(adapter3), "MockAdapter3");
        vm.label(address(erc20), "ERC20");
        vm.label(address(centrifugeChain), "CentrifugeChain");
        vm.label(address(router), "CentrifugeRouter");
        vm.label(address(gasService), "GasService");
        vm.label(address(mockedGasService), "MockGasService");
        vm.label(address(escrow), "Escrow");
        vm.label(address(routerEscrow), "RouterEscrow");
        vm.label(address(guardian), "Guardian");
        vm.label(address(poolManager.trancheFactory()), "TrancheFactory");
        vm.label(address(poolManager.vaultFactory()), "ERC7540VaultFactory");

        // Exclude predeployed contracts from invariant tests by default
        excludeContract(address(root));
        excludeContract(address(investmentManager));
        excludeContract(address(poolManager));
        excludeContract(address(gateway));
        excludeContract(address(erc20));
        excludeContract(address(centrifugeChain));
        excludeContract(address(router));
        excludeContract(address(adapter1));
        excludeContract(address(adapter2));
        excludeContract(address(adapter3));
        excludeContract(address(escrow));
        excludeContract(address(routerEscrow));
        excludeContract(address(guardian));
        excludeContract(address(poolManager.trancheFactory()));
        excludeContract(address(poolManager.vaultFactory()));
    }

    // helpers
    function deployVault(
        uint64 poolId,
        uint8 trancheDecimals,
        address hook,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 assetId,
        address asset
    ) public returns (address) {
        if (poolManager.idToAsset(assetId) == address(0)) {
            centrifugeChain.addAsset(assetId, asset);
        }

        if (poolManager.getTranche(poolId, trancheId) == address(0)) {
            centrifugeChain.batchAddPoolAllowAsset(poolId, assetId);
            centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, trancheDecimals, hook);

            poolManager.deployTranche(poolId, trancheId);
        }

        if (!poolManager.isAllowedAsset(poolId, asset)) {
            centrifugeChain.allowAsset(poolId, assetId);
        }

        poolManager.updateTranchePrice(poolId, trancheId, assetId, uint128(10 ** 18), uint64(block.timestamp));

        address vaultAddress = poolManager.deployVault(poolId, trancheId, asset);

        return vaultAddress;
    }

    function deployVault(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 asset
    ) public returns (address) {
        return
            deployVault(poolId, decimals, restrictionManager, tokenName, tokenSymbol, trancheId, asset, address(erc20));
    }

    function deploySimpleVault() public returns (address) {
        return
            deployVault(5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(erc20));
    }

    function deposit(address _vault, address _investor, uint256 amount) public {
        deposit(_vault, _investor, amount, true);
    }

    function deposit(address _vault, address _investor, uint256 amount, bool claimDeposit) public {
        ERC7540Vault vault = ERC7540Vault(_vault);
        erc20.mint(_investor, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), _investor, type(uint64).max); // add user as
            // member
        vm.startPrank(_investor);
        erc20.approve(_vault, amount); // add allowance
        vault.requestDeposit(amount, _investor, _investor);
        // trigger executed collectInvest
        uint128 assetId = poolManager.assetToId(address(erc20)); // retrieve assetId
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(_investor)), assetId, uint128(amount), uint128(amount)
        );

        if (claimDeposit) {
            vault.deposit(amount, _investor); // claim the tranches
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

    // assumptions
    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }

    function addressAssumption(address user) public view returns (bool) {
        return (user != address(0) && user != address(erc20) && user.code.length == 0);
    }
}
