// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface IDeployGate {
    event UpdateExecutor(address indexed who, bool canDeploy);
    event Deploy(bytes32 indexed salt, address indexed target);
    event Validate(bytes32 indexed salt, bytes32 indexed initCodeHash);

    error NotExecutor();
    error NoGovernance();
    error LengthMismatch();
    error InvalidSalt(bytes32 salt);
    error NotValidated(bytes32 salt);
    error DuplicateSalt(bytes32 salt);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Grants or revokes the right to deploy. Independent of the commitment, so a compromised key is
    ///         dropped without touching what is pending.
    function updateExecutor(address who, bool canDeploy) external;

    /// @notice Commits what each salt may deploy, and in what order. Committing again starts a new nonce that
    ///         replaces the previous set whole, so whatever it does not mention becomes undeployable, and
    ///         committing nothing revokes everything.
    /// @param  salts CreateX salt of each contract, in deployment order
    /// @param  initCodeHashes Hash of the creation code, including constructor arguments, of each contract
    function validate(bytes32[] calldata salts, bytes32[] calldata initCodeHashes) external;

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @notice Deploys the next contract of the live commitment, and consumes it.
    /// @param  salt CreateX salt of the contract
    /// @param  initCode Creation code, including constructor arguments, of the contract
    /// @return target Address of the deployed contract
    function deploy(bytes32 salt, bytes calldata initCode) external returns (address target);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Commitment currently in force, which a new one replaces whole
    function nonce() external view returns (uint256);

    /// @notice How many contracts of the live commitment have been deployed, and so which comes next
    function deployed() external view returns (uint256);

    /// @notice Whether `who` may deploy what has been committed
    function isExecutor(address who) external view returns (bool);

    /// @notice What `salt` carries under the live commitment, or zero when it carries nothing
    function validated(bytes32 salt) external view returns (bytes32);

    /// @notice What a salt carries once committed, which a caller reproduces to deploy it
    function commitment(bytes32 initCodeHash, uint256 index) external pure returns (bytes32);
}
