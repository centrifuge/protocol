// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {Escrow} from "src/vaults/Escrow.sol";
import {AsyncRequests} from "src/vaults/AsyncRequests.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {Root} from "src/common/Root.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";

import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";

import {Root} from "src/common/Root.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";

// Storage
import {SharedStorage} from "./helpers/SharedStorage.sol";
import {MockMessageProcessor} from "./mocks/MockMessageProcessor.sol";
import {MockMessageDispatcher} from "./mocks/MockMessageDispatcher.sol";
import {MockGateway} from "./mocks/MockGateway.sol";

abstract contract Setup is BaseSetup, SharedStorage, ActorManager, AssetManager {
    // Dependencies
    AsyncVaultFactory vaultFactory;
    TokenFactory tokenFactory;

    Escrow public escrow; // NOTE: Restriction Manager will query it
    AsyncRequests asyncRequests;
    SyncRequests syncRequests;
    PoolManager poolManager;
    AsyncVault vault;
    CentrifugeToken token;
    RestrictedTransfers restrictedTransfers;
    IRoot root;
    BalanceSheet balanceSheet;

    MockMessageDispatcher messageDispatcher;
    MockGateway gateway;

    bytes16 scId;
    uint64 poolId;
    uint128 assetId;
    uint128 currencyId;

    // Fork testing
    uint256 totalSupplyAtFork;
    uint256 tokenBalanceOfEscrowAtFork;
    uint256 trancheTokenBalanceOfEscrowAtFork;
    bool forked;

    // MOCKS
    address centrifugeChain;
    uint16 CENTIFUGE_CHAIN_ID = 1;

    // LP request ID is always 0
    uint256 REQUEST_ID = 0;
    bytes32 EVM_ADDRESS = bytes32(uint256(0x1234) << 224);

    // === GOV FUZZING  === //
    bool GOV_FUZZING = bool(false); 
    address constant TARGET = address(0x0);
    uint256 constant GAS = uint256(0);
    uint256 constant VALUE = uint256(0);
    bytes constant DATA = bytes(hex"");


    modifier asAdmin {
        vm.prank(address(this));
        _;
    }

    modifier asActor {
        vm.prank(address(_getActor()));
        _;
    }

    modifier tokenIsSet() {
        require(address(token) != address(0));
        _;
    }

    modifier assetIsSet() {
        require(_getAsset() != address(0));
        _;
    }

    modifier statelessTest() {
        _;
        revert("statelessTest");
    }

    modifier notForked() {
        require(!forked);
        _;
    }

    // === GOV FUZZING SETUP === //
    modifier onlyGovFuzzing() {
        require(GOV_FUZZING);
        _;
    }

    // We can perform these only when not gov fuzzing
    modifier notGovFuzzing() {
        require(!GOV_FUZZING);
        _;
    }

    // NOTE: All of this will get dynamically replaced by Gov Fuzzing
    function doGovFuzzing() public onlyGovFuzzing {
        (bool success, ) = TARGET.call{gas: GAS, value: VALUE}(DATA);
        require(success, "Call failed");
    }

    // MOCK++
    fallback() external payable {
        // Basically we will receive `root.rely, etc..`
    }

    receive() external payable {}

    function setup() internal virtual override {
        // Put self so we can perform settings
        centrifugeChain = address(this);

        // Dependencies
        escrow = new Escrow(address(this));
        root = new Root(48 hours, address(this));
        restrictedTransfers = new RestrictedTransfers(address(root), address(this));

        root.endorse(address(escrow));

        balanceSheet = new BalanceSheet(address(escrow), address(this));
        asyncRequests = new AsyncRequests(address(root), address(escrow), address(this));
        syncRequests = new SyncRequests(address(root), address(escrow), address(this));
        vaultFactory = new AsyncVaultFactory(address(this), address(asyncRequests), address(this));
        tokenFactory = new TokenFactory(address(this), address(this));

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);
        poolManager = new PoolManager(address(escrow), address(tokenFactory), vaultFactories, address(this));
        messageDispatcher = new MockMessageDispatcher(poolManager, asyncRequests, root, CENTIFUGE_CHAIN_ID); 
        gateway = new MockGateway();

        // set dependencies
        asyncRequests.file("sender", address(messageDispatcher));
        asyncRequests.file("poolManager", address(poolManager));
        asyncRequests.file("balanceSheet", address(balanceSheet));    
        asyncRequests.file("sharePriceProvider", address(syncRequests));
        syncRequests.file("poolManager", address(poolManager));
        syncRequests.file("balanceSheet", address(balanceSheet));
        poolManager.file("sender", address(messageDispatcher));
        poolManager.file("tokenFactory", address(tokenFactory));
        poolManager.file("gateway", address(gateway));
        poolManager.file("balanceSheet", address(balanceSheet));
        balanceSheet.file("gateway", address(gateway));
        balanceSheet.file("poolManager", address(poolManager));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("sharePriceProvider", address(syncRequests));
        // authorize contracts
        asyncRequests.rely(address(poolManager));
        asyncRequests.rely(address(vaultFactory));
        asyncRequests.rely(address(messageDispatcher));
        poolManager.rely(address(messageDispatcher));

        restrictedTransfers.rely(address(poolManager));

        // Setup Escrow Permissions
        escrow.rely(address(asyncRequests));
        escrow.rely(address(poolManager));
        escrow.rely(address(balanceSheet));

        // Permissions on factories
        vaultFactory.rely(address(poolManager));
        tokenFactory.rely(address(poolManager));

        balanceSheet.rely(address(asyncRequests));
        balanceSheet.rely(address(syncRequests));
    }

    // NOTE: this overrides contracts deployed in setup() above with forked contracts
    function setupFork() internal {  
        // These will be dynamically replaced by Gov Fuzzing
        vm.roll(20770509);
        vm.warp(1726578263);

        forked = true;

        // Forked contracts from here: https://github.com/centrifuge/liquidity-pools/blob/main/deployments/mainnet/ethereum-mainnet.json
        escrow = Escrow(address(0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD));
        restrictedTransfers = RestrictedTransfers(address(0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0));
        asyncRequests = AsyncRequests(address(0xE79f06573d6aF1B66166A926483ba00924285d20));
        poolManager = PoolManager(address(0x91808B5E2F6d7483D41A681034D7c9DbB64B9E29));
        root = Root(address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC));

        // Pool specific contracts
        vault = AsyncVault(address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970));
        token = CentrifugeToken(address(0x8c213ee79581Ff4984583C6a801e5263418C4b86));
        // TODO: replaced with getAsset(), need a better way to do this for forked setup
        // token = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        // Pool specific values
        poolId = 4139607887;
        scId = 0x97aa65f23e7be09fcd62d0554d2e9273;
        // TODO: need tokenId to pass in here
        // assetId = poolManager.assetToId(address(_getAsset()));

        // remove previously set actors
        _removeActor(address(this)); // remove default actor
        _removeActor(address(0x20000));
        _removeActor(address(0x30000));

        // Adds actors that have permissions to interact with the system, must be authorized by the InvestmentManager
        // NOTE: must ensure that 0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD (escrow) isn't added as an actor because it messes up property implementations
        // _setDefaultActor(address(0x7829E5ca4286Df66e9F58160544097dB517a3B8c)); // TODO: this needs to be the default actor for fuzz testing (find better way to resolve this)
        _addActor(address(0x6F94EB271cEB5a33aeab5Bb8B8edEA8ECf35Ee86));
        _addActor(address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC)); // authd but has transfer restrictions

        // Transfer underlying asset from whale to actors
        address[] memory actors = _getActors();
        address whale = address(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341); // USDC whale for testing
        uint256 whaleBalance = MockERC20(address(_getAsset())).balanceOf(whale); // TODO: replace with whale address
        uint256 initialActorBalance = whaleBalance / actors.length;
        
        for (uint256 i = 0; i < actors.length; i++) { 
            vm.prank(whale);
            MockERC20(address(_getAsset())).transfer(actors[i], initialActorBalance);
        }

        // NOTE: used for invariants that depend on comparing ghost variables to state values
        // state values are taken from the forked contracts so won't initially be in sync with the ghost variables, this allows us to sync them
        totalSupplyAtFork = token.totalSupply();
        tokenBalanceOfEscrowAtFork = MockERC20(address(_getAsset())).balanceOf(address(escrow));
        trancheTokenBalanceOfEscrowAtFork = token.balanceOf(address(escrow));
    }

    /// @dev Returns a random actor from the list of actors
    /// @dev This is useful for cases where we want to have caller and recipient be different actors
    /// @param entropy The determines which actor is chosen from the array
    function _getRandomActor(uint256 entropy) internal view returns (address randomActor) {
        address[] memory actorsArray = _getActors();
        randomActor = actorsArray[entropy % actorsArray.length];
    }
}
