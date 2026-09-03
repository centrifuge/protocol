// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Network: Pharos (Chain ID: 1672)
// Deployed Address: 0x11fe6D540a31267904Fc21756Dad824eae63541b
// Source Branch: internal/main
// CREATE3 Deterministic Deployment

import {PoolId} from "../../src/core/types/PoolId.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {Root} from "../../src/admin/Root.sol";
import {IAdapterWiring} from "../../src/admin/interfaces/IAdapterWiring.sol";

/// @title  AddChainlinkPharosEthSpell
/// @notice Adds Chainlink as a second adapter to the pharos<>ethereum MultiAdapter route,
///         upgrading from `[layerZero]` threshold 1 to `[layerZero, chainlink]` threshold 2.
/// @dev    Designed to execute on BOTH ethereum mainnet and pharos (one deployment per chain).
///         The spell branches on `block.chainid` to target the correct remote chain, and both
///         wires the ChainlinkAdapter to the remote and calls `multiAdapter.setAdapters()` under
///         one temporary Root-granted ward.
///
///         Scope is GLOBAL_POOL only (protocol-level traffic: upgrades, recovery, register,
///         set-pool-adapters dispatch). Per-pool routes (e.g. JAAA 281474976710663) must be
///         hardened separately by the pool manager via `hub.setAdapters`, which can only run
///         AFTER this spell casts on both chain.
contract AddChainlinkPharosEthSpell {
    bool public done;
    string public constant description =
        "Add Chainlink adapter to pharos<>ethereum MultiAdapter (layerZero+chainlink, threshold 2)";

    address public constant LAYER_ZERO_ADAPTER = 0xD517BC7ba17271a8D87BE7355B2523bF5c750295;
    address public constant CHAINLINK_ADAPTER = 0x39CF679Eb0Ac9075CFb5f94930A367Ba1557D955;
    address public constant MULTI_ADAPTER = 0x35C837F0A54B715a23D193E1476BFC9BC30073BE;
    address public constant ETH_ROOT = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address public constant PHAROS_ROOT = 0xdc9456e7e20f15029C8231Ec433a20F404b7235E;

    uint256 public constant ETH_CHAIN_ID = 1;
    uint256 public constant PHAROS_CHAIN_ID = 1672;

    uint16 public constant ETH_CENTRIFUGE_ID = 1;
    uint16 public constant PHAROS_CENTRIFUGE_ID = 12;

    /// @dev Chainlink CCIP chain selectors for each chain. Sourced from env/{ethereum,pharos}.json.
    uint64 public constant ETH_CCIP_SELECTOR = 5009297550715157269;
    uint64 public constant PHAROS_CCIP_SELECTOR = 7801139999541420232;

    /// @dev The adapter set on MultiAdapter applies to GLOBAL_POOL (PoolId(0)).
    uint64 internal constant GLOBAL_POOL_RAW = 0;

    /// @dev Target configuration for the new adapter set.
    ///      `recoveryIndex == quorum` means no recovery-only adapters: both LZ and Chainlink are
    ///      first-class. Matches the deployment-time convention in `ActionBatchers.sol` where
    ///      `recoveryIndex` is always set to `adapters.length`.
    uint8 internal constant NEW_THRESHOLD = 2;
    uint8 internal constant NEW_RECOVERY_INDEX = 2;

    error UnsupportedChain();
    error UnexpectedAdapterCount();
    error UnexpectedLayerZeroAdapter();
    error AlreadyExecuted();

    /// @notice Executes the upgrade on the current chain.
    function cast() external {
        if (done) revert AlreadyExecuted();
        done = true;

        (Root root, uint16 remoteCid, uint64 remoteCcipSelector) = _resolveLocal(block.chainid);
        IMultiAdapter multiAdapter = IMultiAdapter(MULTI_ADAPTER);
        IAdapter existingLz = _assertSingleAdapterPreState(multiAdapter, remoteCid);

        _grantTemporaryWards(root, multiAdapter);
        _wireChainlinkToRemote(remoteCid, remoteCcipSelector);
        _switchMultiAdapterRoute(multiAdapter, remoteCid, existingLz);
        _revokeTemporaryWards(root, multiAdapter);

        root.deny(address(this));
    }

    /// @dev Map the local `block.chainid` to the local Root + remote centrifugeId + remote CCIP selector.
    function _resolveLocal(uint256 localChainId)
        internal
        pure
        returns (Root root, uint16 remoteCid, uint64 remoteCcipSelector)
    {
        if (localChainId == ETH_CHAIN_ID) {
            return (Root(ETH_ROOT), PHAROS_CENTRIFUGE_ID, PHAROS_CCIP_SELECTOR);
        }
        if (localChainId == PHAROS_CHAIN_ID) {
            return (Root(PHAROS_ROOT), ETH_CENTRIFUGE_ID, ETH_CCIP_SELECTOR);
        }
        revert UnsupportedChain();
    }

    function _assertSingleAdapterPreState(IMultiAdapter multiAdapter, uint16 remoteCid)
        private
        view
        returns (IAdapter existingLz)
    {
        PoolId globalPool = PoolId.wrap(GLOBAL_POOL_RAW);
        if (multiAdapter.quorum(remoteCid, globalPool) != 1) revert UnexpectedAdapterCount();
        existingLz = multiAdapter.adapters(remoteCid, globalPool, 0);
        if (address(existingLz) != LAYER_ZERO_ADAPTER) revert UnexpectedLayerZeroAdapter();
    }

    function _grantTemporaryWards(Root root, IMultiAdapter multiAdapter) private {
        root.relyContract(CHAINLINK_ADAPTER, address(this));
        root.relyContract(address(multiAdapter), address(this));
    }

    function _wireChainlinkToRemote(uint16 remoteCid, uint64 remoteCcipSelector) private {
        IAdapterWiring(CHAINLINK_ADAPTER).wire(remoteCid, abi.encode(remoteCcipSelector, CHAINLINK_ADAPTER));
    }

    function _switchMultiAdapterRoute(IMultiAdapter multiAdapter, uint16 remoteCid, IAdapter existingLz) private {
        PoolId globalPool = PoolId.wrap(GLOBAL_POOL_RAW);
        IAdapter[] memory newAdapters = new IAdapter[](2);
        newAdapters[0] = existingLz;
        newAdapters[1] = IAdapter(CHAINLINK_ADAPTER);
        multiAdapter.setAdapters(remoteCid, globalPool, newAdapters, NEW_THRESHOLD, NEW_RECOVERY_INDEX);
    }

    function _revokeTemporaryWards(Root root, IMultiAdapter multiAdapter) private {
        root.denyContract(CHAINLINK_ADAPTER, address(this));
        root.denyContract(address(multiAdapter), address(this));
    }
}
