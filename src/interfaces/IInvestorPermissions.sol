// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IInvestorPermissions {
    // Events
    event Added(bytes16 shareClassId, address target);
    event Removed(bytes16 shareClassId, address target);
    event Frozen(bytes16 shareClassId, address target);
    event Unfrozen(bytes16 shareClassId, address target);

    // Errors
    error Missing();
    error AlreadyFrozen();
    error NotFrozen();

    /// @notice Grant permissions to the target.
    ///
    /// @param shareClassId Share class for which permissions are granted
    /// @param target User which is granted permissions
    function add(bytes16 shareClassId, address target) external;

    /// @notice Remove permissions of the target.
    ///
    /// @param shareClassId Share class for which permissions are revoked
    /// @param target User whose permissions are revoked
    function remove(bytes16 shareClassId, address target) external;

    /// @notice Temporarily revoke permissions of the target by freezing them.
    ///
    /// @param shareClassId Share class for which permissions are frozen
    /// @param target User whose permissions are frozen
    function freeze(bytes16 shareClassId, address target) external;

    /// @notice Revert a previous freeze of the target.
    ///
    /// @param shareClassId Share class for which permissions are unfrozen
    /// @param target User whose permissions are unfrozen
    function unfreeze(bytes16 shareClassId, address target) external;

    /// @notice Check whether the target has permissions and is frozen.
    ///
    /// @param shareClassId Share class for which we perform the permissions check
    /// @param target User whose permissions are checked
    function isFrozenInvestor(bytes16 shareClassId, address target) external view returns (bool);

    /// @notice Check whether the target has permissions and is not frozen.
    ///
    /// @param shareClassId Share class for which we perform the permissions check
    /// @param target User whose permissions are checked
    function isUnfrozenInvestor(bytes16 shareClassId, address target) external view returns (bool);
}
