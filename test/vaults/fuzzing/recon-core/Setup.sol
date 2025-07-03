// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {Escrow} from "src/misc/Escrow.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {Root} from "src/common/Root.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {SyncManager} from "src/vaults/SyncManager.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";

import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";

import {Root} from "src/common/Root.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";

// Storage
import {SharedStorage} from "./helpers/SharedStorage.sol";
import {MockMessageProcessor} from "./mocks/MockMessageProcessor.sol";
import {MockMessageDispatcher} from "test/integration/recon-end-to-end/mocks/MockMessageDispatcher.sol";
import {MockGateway} from "test/integration/recon-end-to-end/mocks/MockGateway.sol";
import {MockHub} from "./mocks/MockHub.sol";
import {MockAsyncRequestManager} from "./mocks/MockAsyncRequestManager.sol";

abstract contract Setup is BaseSetup, SharedStorage, ActorManager, AssetManager {
    // Dependencies
    AsyncVaultFactory vaultFactory;
    SyncDepositVaultFactory syncVaultFactory;
    SyncManager syncManager;
    TokenFactory tokenFactory;
    PoolEscrowFactory poolEscrowFactory;

    Escrow public escrow; // NOTE: Restriction Manager will query it
    AsyncRequestManager asyncRequestManager;
    Spoke spoke;
    AsyncVault vault;
    ShareToken token;
    FullRestrictions fullRestrictions;
    IRoot root;
    BalanceSheet balanceSheet;

    MockMessageDispatcher messageDispatcher;
    MockGateway gateway;
    MockHub hub;
    MockAsyncRequestManager requestManager;

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

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
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
        (bool success,) = TARGET.call{gas: GAS, value: VALUE}(DATA);
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

        // Add actors for testing
        _addActor(address(0x20000));
        _addActor(address(0x30000));

        // Dependencies
        escrow = new Escrow(address(this));
        root = new Root(48 hours, address(this));
        fullRestrictions = new FullRestrictions(address(root), address(this));

        root.endorse(address(escrow));

        balanceSheet = new BalanceSheet(IRoot(address(root)), address(this));
        asyncRequestManager = new AsyncRequestManager(escrow, address(this));
        syncManager = new SyncManager(address(this));
        vaultFactory = new AsyncVaultFactory(address(this), asyncRequestManager, address(this));
        syncVaultFactory = new SyncDepositVaultFactory(address(root), syncManager, asyncRequestManager, address(this));
        tokenFactory = new TokenFactory(address(this), address(this));
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));
        spoke = new Spoke(tokenFactory, address(this));

        messageDispatcher = new MockMessageDispatcher();
        gateway = new MockGateway();
        hub = new MockHub();
        requestManager = new MockAsyncRequestManager();

        // set dependencies
        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        syncManager.file("spoke", address(spoke));
        syncManager.file("balanceSheet", address(balanceSheet));
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("tokenFactory", address(tokenFactory));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));
        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));
        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));
        messageDispatcher.file("hub", address(hub));
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));
        messageDispatcher.file("requestManager", address(requestManager));

        // authorize contracts
        asyncRequestManager.rely(address(spoke));
        asyncRequestManager.rely(address(vaultFactory));
        asyncRequestManager.rely(address(syncVaultFactory));
        asyncRequestManager.rely(address(messageDispatcher));
        asyncRequestManager.rely(address(syncManager));
        syncManager.rely(address(spoke));
        syncManager.rely(address(vaultFactory));
        syncManager.rely(address(syncVaultFactory));
        syncManager.rely(address(messageDispatcher));
        syncManager.rely(address(asyncRequestManager));
        spoke.rely(address(messageDispatcher));
        spoke.rely(address(asyncRequestManager));

        fullRestrictions.rely(address(spoke));

        // Setup Escrow Permissions
        escrow.rely(address(asyncRequestManager));
        escrow.rely(address(spoke));
        escrow.rely(address(balanceSheet));

        // Permissions on factories
        vaultFactory.rely(address(spoke));
        syncVaultFactory.rely(address(spoke));
        tokenFactory.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        balanceSheet.rely(address(asyncRequestManager));
        balanceSheet.rely(address(syncManager));

        // Configure TokenFactory to give permissions to Spoke on new tokens
        address[] memory tokenWards = new address[](1);
        tokenWards[0] = address(spoke);
        tokenFactory.file("wards", tokenWards);
    }

    // NOTE: this overrides contracts deployed in setup() above with forked contracts
    function setupFork() internal {
        // These will be dynamically replaced by Gov Fuzzing
        vm.roll(20770509);
        vm.warp(1726578263);

        forked = true;

        // Forked contracts from here:
        // https://github.com/centrifuge/liquidity-pools/blob/main/deployments/mainnet/ethereum-mainnet.json
        escrow = Escrow(address(0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD));
        fullRestrictions = FullRestrictions(address(0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0));
        asyncRequestManager = AsyncRequestManager(address(0xE79f06573d6aF1B66166A926483ba00924285d20));
        spoke = Spoke(address(0x91808B5E2F6d7483D41A681034D7c9DbB64B9E29));
        root = Root(address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC));

        // Pool specific contracts
        vault = AsyncVault(address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970));
        token = ShareToken(address(0x8c213ee79581Ff4984583C6a801e5263418C4b86));
        // TODO: replaced with getAsset(), need a better way to do this for forked setup
        // token = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        // Pool specific values
        poolId = 4139607887;
        scId = 0x97aa65f23e7be09fcd62d0554d2e9273;
        // Set up the forked asset (USDC)
        address usdcAddress = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

        // Check if we're actually on a fork by checking if USDC contract exists
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(usdcAddress)
        }

        if (codeSize > 0) {
            // We're on a proper fork, use real USDC
            _addAsset(usdcAddress);
        } else {
            // We're not on a fork, deploy a mock ERC20 for testing
            MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);
            _addAsset(address(mockUsdc));
        }
        _switchAsset(0); // This should set the current asset to the first (and only) asset
        // TODO: need tokenId to pass in here
        // assetId = spoke.assetToId(address(_getAsset()));

        // remove previously set actors
        // TODO(wischli): Cannot remove address(this) as it's the default actor
        //_removeActor(address(this)); // remove default actor
        _removeActor(address(0x20000));
        _removeActor(address(0x30000));

        // Adds actors that have permissions to interact with the system, must be authorized by the AsyncRequestManager
        // NOTE: must ensure that 0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD (escrow) isn't added as an actor because it
        // messes up property implementations
        // _setDefaultActor(address(0x7829E5ca4286Df66e9F58160544097dB517a3B8c)); // TODO: this needs to be the default
        // actor for fuzz testing (find better way to resolve this)
        _addActor(address(0x6F94EB271cEB5a33aeab5Bb8B8edEA8ECf35Ee86));
        _addActor(address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC)); // authd but has transfer restrictions

        // Transfer underlying asset from whale to actors
        address[] memory actors = _getActors();
        address whale = address(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341); // USDC whale for testing

        if (codeSize > 0) {
            // We're on a proper fork, transfer from whale
            uint256 whaleBalance = MockERC20(address(_getAsset())).balanceOf(whale);
            if (whaleBalance > 0) {
                uint256 initialActorBalance = whaleBalance / actors.length;
                for (uint256 i = 0; i < actors.length; i++) {
                    vm.prank(whale);
                    MockERC20(address(_getAsset())).transfer(actors[i], initialActorBalance);
                }
            }
        } else {
            // We're using mock USDC, mint tokens to actors
            MockERC20 mockUsdc = MockERC20(address(_getAsset()));
            uint256 initialActorBalance = 1000000 * 10 ** 6; // 1M USDC (6 decimals)
            for (uint256 i = 0; i < actors.length; i++) {
                vm.deal(actors[i], 1000 ether); // Give some ETH
                mockUsdc.mint(actors[i], initialActorBalance); // Mint USDC to actor
            }
        }

        // NOTE: used for invariants that depend on comparing ghost variables to state values
        // state values are taken from the forked contracts so won't initially be in sync with the ghost variables, this
        // allows us to sync them

        // Only sync fork values if we're actually on a fork
        if (codeSize > 0) {
            // We're on a proper fork, sync the values from forked contracts
            totalSupplyAtFork = token.totalSupply();
            tokenBalanceOfEscrowAtFork = MockERC20(address(_getAsset())).balanceOf(address(escrow));
            trancheTokenBalanceOfEscrowAtFork = token.balanceOf(address(escrow));
        } else {
            // We're not on a fork, initialize to zero
            totalSupplyAtFork = 0;
            tokenBalanceOfEscrowAtFork = 0;
            trancheTokenBalanceOfEscrowAtFork = 0;
        }
    }

    /// @dev Returns a random actor from the list of actors
    /// @dev This is useful for cases where we want to have caller and recipient be different actors
    /// @param entropy The determines which actor is chosen from the array
    function _getRandomActor(uint256 entropy) internal view returns (address randomActor) {
        address[] memory actorsArray = _getActors();
        randomActor = actorsArray[entropy % actorsArray.length];
    }
}
