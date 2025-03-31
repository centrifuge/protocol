// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {console2} from "forge-std/console2.sol";

import {Escrow} from "src/vaults/Escrow.sol";
import {InvestmentManager} from "src/vaults/InvestmentManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {Root} from "src/common/Root.sol";

import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";

import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {Tranche} from "src/vaults/token/Tranche.sol";

// Mocks
import {IRoot} from "src/common/interfaces/IRoot.sol";

// Storage
import {SharedStorage} from "./SharedStorage.sol";
abstract contract Setup is BaseSetup, SharedStorage, ActorManager, AssetManager {
    // Dependencies
    ERC7540VaultFactory vaultFactory;
    TrancheFactory trancheFactory;

    // Handled //
    Escrow public escrow; // NOTE: Restriction Manager will query it
    InvestmentManager investmentManager;
    PoolManager poolManager;

    // TODO: CYCLE / Make it work for variable values
    ERC7540Vault vault;
    ERC20 token;
    Tranche trancheToken;
    RestrictionManager restrictionManager;

    bytes16 trancheId;
    uint64 poolId;
    uint128 currencyId;
    uint256 totalSupplyAtFork;
    uint256 tokenBalanceOfEscrowAtFork;
    uint256 trancheTokenBalanceOfEscrowAtFork;
    address gateway;
    bool forked;
    // MOCKS
    address centrifugeChain;
    IRoot root;

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

    modifier trancheTokenIsSet() {
        require(address(trancheToken) != address(0));
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
        TARGET.call{gas: GAS, value: VALUE}(DATA);
    }

    // MOCK++
    fallback() external payable {
        // Basically we will receive `root.rely, etc..`
    }

    function setup() internal virtual override {
        // Put self so we can perform settings
        centrifugeChain = address(this);


        // Dependencies
        trancheFactory = new TrancheFactory(address(this), address(this));
        escrow = new Escrow(address(address(this)));
        root = new Root(48 hours, address(this));
        restrictionManager = new RestrictionManager(address(root), address(this));


        root.endorse(address(escrow));


        investmentManager = new InvestmentManager(address(root), address(escrow));
        vaultFactory = new ERC7540VaultFactory(address(this), address(investmentManager));


        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);


        poolManager = new PoolManager(address(escrow), address(trancheFactory), vaultFactories);
        poolManager.file("gateway", address(this));


        investmentManager.file("gateway", address(this));
        investmentManager.file("poolManager", address(poolManager));
        investmentManager.rely(address(poolManager));
        investmentManager.rely(address(vaultFactory));


        restrictionManager.rely(address(poolManager));


        // Setup Escrow Permissions
        escrow.rely(address(investmentManager));
        escrow.rely(address(poolManager));


        // Permissions on factories
        vaultFactory.rely(address(poolManager));
        trancheFactory.rely(address(poolManager));


        // TODO: Cycling of:
        // Actors and ERC7540 Vaults
    }

    // NOTE: this overrides contracts deployed in setup() above with forked contracts
    function setupFork() internal {  
        // These will be dynamically replaced by Gov Fuzzing
        vm.roll(20770509);
        vm.warp(1726578263);

        forked = true;

        // Forked contracts from here: https://github.com/centrifuge/liquidity-pools/blob/main/deployments/mainnet/ethereum-mainnet.json
        escrow = Escrow(address(0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD));
        restrictionManager = RestrictionManager(address(0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0));
        investmentManager = InvestmentManager(address(0xE79f06573d6aF1B66166A926483ba00924285d20));
        poolManager = PoolManager(address(0x91808B5E2F6d7483D41A681034D7c9DbB64B9E29));
        root = Root(address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC));

        // Pool specific contracts
        vault = ERC7540Vault(address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970));
        trancheToken = Tranche(address(0x8c213ee79581Ff4984583C6a801e5263418C4b86));
        token = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        // Pool specific values
        poolId = 4139607887;
        trancheId = 0x97aa65f23e7be09fcd62d0554d2e9273;
        currencyId = poolManager.assetToId(address(token));

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
        uint256 whaleBalance = token.balanceOf(whale); // TODO: replace with whale address
        uint256 initialActorBalance = whaleBalance / actors.length;
        
        for (uint256 i = 0; i < actors.length; i++) { 
            vm.prank(whale);
            token.transfer(actors[i], initialActorBalance);
        }

        // NOTE: used for invariants that depend on comparing ghost variables to state values
        // state values are taken from the forked contracts so won't initially be in sync with the ghost variables, this allows us to sync them
        totalSupplyAtFork = trancheToken.totalSupply();
        tokenBalanceOfEscrowAtFork = token.balanceOf(address(escrow));
        trancheTokenBalanceOfEscrowAtFork = trancheToken.balanceOf(address(escrow));
    }

    /// @dev Returns a random actor from the list of actors
    /// @dev This is useful for cases where we want to have caller and recipient be different actors
    /// @param entropy The determines which actor is chosen from the array
    function _getRandomActor(uint256 entropy) internal view returns (address randomActor) {
        address[] memory actorsArray = _getActors();
        randomActor = actorsArray[entropy % actorsArray.length];
    }
}
