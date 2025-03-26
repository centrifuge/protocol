import {MultiShareClass} from "src/pools/MultiShareClass.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";

/// @dev Wrapper so we can reset the epoch increment for testing
contract MultiShareClassWrapper is MultiShareClass {
    constructor(IPoolRegistry poolRegistry, address deployer) MultiShareClass(poolRegistry, deployer) {
        poolRegistry = poolRegistry;
    }

    /// @dev We need to reset the epoch increment for shortcut functions which make multiple calls to the share class in the same transaction
    /// since these calls don't reset the epoch increment as would normally be done with multiple transactions we need to manually reset it here
    function setEpochIncrement(uint32 epochIncrement) public {
        _epochIncrement = epochIncrement;
    }
}