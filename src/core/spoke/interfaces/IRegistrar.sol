// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  IRegistrar
/// @notice Standard-specific driver for a share token implementation. The core only interacts with share
///         tokens through a registrar: it creates tokens, issues and cancels shares, applies restriction
///         updates, and maintains metadata. One registrar is deployed per token standard per chain, and
///         each share class selects its registrar at creation (via the `NotifyShareClass` message).
/// @dev    Registrar implementations MUST restrict all state-changing methods to the core spoke contracts
///         (Spoke, SpokeHandler, SpokeRegistry). A registrar is chosen per share class, and holds that share
///         class's mint authority on its chain. Because share supply is fungible across chains, a hostile
///         registrar on one chain can mint into the same share class on another via a crosschain transfer.
/// @dev    The registrar abstracts only privileged operations; core still moves shares via the token's
///         ERC20 `transfer`/`transferFrom`/`approve` directly, so every registrar's token MUST be
///         ERC20-transfer-compatible.
/// @dev    Because the core no longer force-transfers, a registrar's token MUST permit plain ERC20
///         transfers into the root-endorsed core contract (Spoke): cross-chain transfers pull the
///         shares in with `transferFrom` and `revoke`/`burn` pulls them in before burning. A restriction
///         policy that blocks transfers to that endorsed address will brick those flows.
interface IRegistrar {
    /// @notice Deploys (or registers) a new share token for this standard.
    /// @dev    In order to have the same address on different EVMs, `salt` should be used
    ///         during the creation process.
    /// @param  name Name of the new token
    /// @param  symbol Symbol of the new token
    /// @param  decimals Decimals of the new token
    /// @param  salt Salt used for deterministic deployments
    /// @param  payload Opaque, registrar-defined creation data forwarded from the hub. The core does not
    ///         inspect or validate it in any way; interpreting it is entirely the registrar's
    ///         responsibility. Empty for registrars that need no extra configuration; such registrars
    ///         must ignore it.
    /// @return token The address of the new token
    function newToken(string memory name, string memory symbol, uint8 decimals, bytes32 salt, bytes memory payload)
        external
        returns (address token);

    /// @notice Returns the address `newToken` would deploy for the given parameters, without deploying.
    /// @dev    Enables same-address deployments across EVMs to be verified ahead of creation. Takes `payload`
    ///         because a registrar may derive the token's address from it.
    function previewTokenAddress(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes memory payload
    ) external view returns (address token);

    /// @notice Mints `amount` of `token` to `to`.
    function mint(address token, address to, uint256 amount) external;

    /// @notice Burns `amount` of `token` held by `from`.
    /// @dev    `from` is the calling core contract, which has pulled the shares to itself from the
    ///         consenting initiator. It grants the registrar an ERC20 allowance of `amount` beforehand
    ///         (the registrar re-pulls to the caller before burning, preserving the transfer-hook flow
    ///         shape); registrars whose token supports a privileged `authTransferFrom` need no allowance.
    function burn(address token, address from, uint256 amount) external;

    /// @notice Transfers `amount` of `token` from `from` to `to` without the owner's on-chain approval.
    /// @dev    OPTIONAL capability: implementations for standards without a privileged transfer
    ///         mechanism MUST revert.
    /// @param  sender The address initiating the transfer (forwarded to hooks/policies)
    function authTransferFrom(address token, address sender, address from, address to, uint256 amount) external;

    /// @notice Updates the name and symbol of `token`.
    /// @dev    MUST revert if neither name nor symbol changes.
    function updateMetadata(address token, string memory name, string memory symbol) external;

    /// @notice Points `token`'s ERC-7575 vault for `asset` at `vault` (or clears it with `address(0)`).
    /// @dev    Called by the registry to keep the pointer in lockstep with vault links; implementations
    ///         without an ERC-7575 vault pointer MAY no-op. `asset` is an ERC20 address (ERC-7575 pointers
    ///         are asset-address keyed).
    function updateVault(address token, address asset, address vault) external;

    /// @notice Applies a restriction update (e.g. freeze, membership) to `token`.
    /// @dev    The payload encoding is standard-specific; the default implementation forwards to the
    ///         token's transfer hook. Implementations without restriction support MUST revert.
    function updateRestriction(address token, bytes memory update) external;

    /// @notice Returns whether `from` may bridge `amount` of `token` to `centrifugeId`.
    /// @dev    The destination chain is encoded as a pseudo-address (`address(uint160(centrifugeId))`) for
    ///         the transfer-restriction check. Implementations without restriction support MUST return true.
    function canBridge(address token, address from, uint16 centrifugeId, uint256 amount) external view returns (bool);
}
