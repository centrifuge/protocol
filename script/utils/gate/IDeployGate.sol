// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4;

interface IDeployGate {
    event SetDelegate(address indexed validator, address indexed delegatee, bool isValid);
    event Deploy(address indexed validator, bytes32 indexed id, uint256 nonce, bytes32 salt, address indexed target);
    event Validate(
        address indexed validator,
        bytes32 indexed id,
        uint256 indexed nonce,
        bytes32[] salts,
        bytes32[] initCodeHashes,
        address[] executors
    );

    error NotValidator();
    error NotExecutor();
    error LengthMismatch();
    error NotValidated(bytes32 salt);
    error DuplicateSalt(bytes32 salt);

    //----------------------------------------------------------------------------------------------
    // Validation
    //----------------------------------------------------------------------------------------------

    /// @notice Lets `delegatee` commit in the caller's namespace, or stops it. Always the caller's own: a
    ///         delegate cannot name further delegates, and cannot take the namespace from the account it is
    ///         named after, which is the one thing addresses derive from.
    function setDelegate(address delegatee, bool isValid) external;

    /// @notice Commits what each salt may deploy, in what order, and who may deploy it. Committing under an
    ///         id that already holds one replaces it whole, so whatever it does not mention becomes
    ///         undeployable and committing nothing revokes it; committing under a fresh id leaves every
    ///         other commitment alone, which is how a validator keeps several of them in flight at once.
    /// @param  validator Namespace to commit in, which is what the addresses derive from alongside the salt.
    ///         The caller has to be it, or one of its delegates
    /// @param  id Which of the validator's commitments this is. Any 32 bytes, chosen by the caller. It scopes
    ///         permission only: two commitments naming the same salt still point at the same address, and
    ///         whichever deploys first takes it
    /// @param  salts Salt of each contract, in deployment order. Any 32 bytes: the CreateX salt is derived
    /// @param  initCodeHashes Hash of the creation code, including constructor arguments, of each contract
    /// @param  executors Accounts allowed to deploy this commitment, and nothing else. None of them has to be
    ///         the validator, and none gains any privilege beyond deploying exactly what is committed here
    function validate(
        address validator,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) external;

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @notice Deploys the next contract of a commitment, and consumes it.
    /// @param  validator Namespace the contract was committed in, which is what its address derives from
    /// @param  id Commitment the contract was committed under, which is what holds its position
    /// @param  salt Salt of the contract, as committed
    /// @param  initCode Creation code, including constructor arguments, of the contract
    /// @return target Address of the deployed contract
    function deploy(address validator, bytes32 id, bytes32 salt, bytes calldata initCode)
        external
        returns (address target);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Generation of a commitment, which committing under the same id again replaces whole
    function nonce(address validator, bytes32 id) external view returns (uint256);

    /// @notice How many contracts of a commitment have been deployed, and so which comes next. One cursor per
    ///         commitment, which is what lets several of them be in flight without interleaving
    function deployed(address validator, bytes32 id) external view returns (uint256);

    /// @notice Whether `who` may commit in `validator`'s namespace on its behalf
    function isDelegate(address validator, address who) external view returns (bool);

    /// @notice Whether `who` may deploy what a commitment holds, under its live generation
    function isExecutor(address validator, bytes32 id, address who) external view returns (bool);

    /// @notice What `salt` carries under a commitment's live generation, or zero when it carries nothing
    function validated(address validator, bytes32 id, bytes32 salt) external view returns (bytes32);

    /// @notice What a salt carries once committed, which a caller reproduces to deploy it
    function commitment(bytes32 initCodeHash, uint256 index) external pure returns (bytes32);

    /// @notice CreateX salt that `validator` deploys `salt` under. Names the gate as its guardian, which is
    ///         what makes CreateX scope the address to it, and holds the 21st byte at zero, which is what
    ///         keeps the chain id out of it. That leaves 11 bytes to tell the validators apart, which is what
    ///         the addresses of two of them are separated by. The commitment id is not in it: where a
    ///         contract lands does not depend on which commitment authorised it.
    function createXSalt(address validator, bytes32 salt) external view returns (bytes32);

    /// @notice Address `salt` deploys to in `validator`'s namespace, whether or not it has been deployed yet
    function addressOf(address validator, bytes32 salt) external view returns (address);
}
