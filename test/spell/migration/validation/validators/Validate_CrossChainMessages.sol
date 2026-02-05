// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_CrossChainMessages
/// @notice Validates that no pending cross-chain messages exist
/// @dev
contract Validate_CrossChainMessages is BaseValidator {
    using stdJson for string;

    string constant QUERY =
        "crosschainMessages(limit: 1000, where: {status_not: Executed}) { items { id index poolId messageType status fromCentrifugeId toCentrifugeId } totalCount }";

    // Message IDs that haven't been processed that we don't care about
    bytes32[] WHITELISTED_MESSAGE_IDS = [
        bytes32(0x0042c1aceec1def783b816a27e05bf17c3a72a7003beaf3dc8eb647f2fd03823),
        bytes32(0x15fb259e5725ea74ad271bb5ef04348e214575a26228b97f5012f4ec2547d2da),
        bytes32(0x1aa9da92671a4b2bc374fa4f340707305a95f7491f5b42cba4b07b3127b79c23),
        bytes32(0x1d6773347db70d633a43c965b83f30d5d66c48430798ba5a38089240e3b64e61),
        bytes32(0x3c4253b633120ea0dd49e04a4323a6b72f145f6fceb0df6e8b10186855e2f2af),
        bytes32(0x46c368c3b3f5a1ab83f1eb4bcb987b135043b3522e056711eeaeef52a7e2e5c9),
        bytes32(0x57c094322f21c64d95c2987245851eda6397c2dec8071336b88537e850fccecb),
        bytes32(0x65130fdb006e59c073a5b952d027cdaa353b6da682107e3e0832e245655433d4),
        bytes32(0x66b1ed68120331d480b07d1be32709f9344c2f513f2bdf5a90932b3f074d57f9),
        bytes32(0x66b1ed68120331d480b07d1be32709f9344c2f513f2bdf5a90932b3f074d57f9),
        bytes32(0x6dc1371a0017ece1d23c7cf7429220f230e5018f2da7375325bbcb6d0ff22726),
        bytes32(0x6e52fc9105094ae3cd77226d07d7f65ce1cf0a29180f7720006d70e74a8d4aa3),
        bytes32(0x75b43323978baebf9f7ff600fd69e1b49d2f0f781cdc89050823d2163d97954d),
        bytes32(0x765d6fe327b3dc71cb5e86a9fd9da74d3e49440652cf81cc85fe7149fb48f49d),
        bytes32(0x7b9990b141ad719b2cc9455de775ba9bfcade0c2795f021ae455a738dbdec9fe),
        bytes32(0x81e08e07c6e63ef4268d192bad456c75388eda2ac412d04aa6763b026fdddeb5),
        bytes32(0x8b826da393a3a12c28ae2873fb1318a106ffeb11420528b7248488784e417734),
        bytes32(0x96a619c891d3f27cfb4da697edd2971262d3f3643db505b86c81bc08edd4ac80),
        bytes32(0x985617eaef64a50a70639039f178b7847909017161a11ca18a55a3fa1f34e53e),
        bytes32(0xece98c7d88b43a8a74a71e99b1eb939258a080cf57a4cd526a05318da64f6989)
    ];

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "CrossChainMessages";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(QUERY);

        uint256 totalCount = json.readUint(".data.crosschainMessages.totalCount");

        ValidationError[] memory errors = new ValidationError[](totalCount + 1);
        uint256 errorIdx = 0;

        // Detail each non-executed message
        string memory basePath = ".data.crosschainMessages.items";
        for (uint256 i = 0; i < totalCount; i++) {
            string memory status = json.readString(_buildJsonPath(basePath, i, "status"));
            if (_stringsEqual(status, "Executed")) {
                continue;
            }

            string memory id = json.readString(_buildJsonPath(basePath, i, "id"));

            // Skip unprocessed messages that we don't care about
            if (_isWhitelisted(id)) {
                continue;
            }

            string memory messageType = json.readString(_buildJsonPath(basePath, i, "messageType"));
            string memory poolId = json.readString(_buildJsonPath(basePath, i, "poolId"));

            errors[errorIdx++] = _buildError({
                field: "status",
                value: string.concat("Message ", id),
                expected: "Executed",
                actual: status,
                message: string.concat(
                    "Pool ", bytes(poolId).length > 0 ? poolId : "N/A", " - Type: ", messageType, " - Status: ", status
                )
            });
        }

        if (errorIdx == 0) {
            return
                ValidationResult({passed: true, validatorName: "CrossChainMessages", errors: new ValidationError[](0)});
        }

        return
            ValidationResult({
                passed: false, validatorName: "CrossChainMessages", errors: _trimErrors(errors, errorIdx)
            });
    }

    function _stringsEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _isWhitelisted(string memory id) internal view returns (bool) {
        bytes32 idHash = bytes32(vm.parseBytes32(id));
        for (uint256 i = 0; i < WHITELISTED_MESSAGE_IDS.length; i++) {
            if (idHash == WHITELISTED_MESSAGE_IDS[i]) {
                return true;
            }
        }
        return false;
    }
}
