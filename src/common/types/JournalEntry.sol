// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

struct JournalEntry {
    uint128 amount;
    uint32 accountId;
}

library JournalEntryLib {
    /**
     * @dev Packs an array of JournalEntry into a tight bytes array of length (entries.length * 20).
     *      Each entry = 20 bytes:
     *         - amount (uint128) is stored in 16 bytes (big-endian)
     *         - accountId (uint32) in 4 bytes (big-endian)
     */
    function encodePacked(JournalEntry[] memory entries) internal pure returns (bytes memory) {
        // Each entry = 20 bytes
        bytes memory packed = new bytes(entries.length * 20);

        for (uint256 i = 0; i < entries.length; i++) {
            uint256 offset = i * 20;

            // Store `amount` as 16 bytes (big-endian)
            uint128 amount = entries[i].amount;
            for (uint256 j = 0; j < 16; j++) {
                // shift right by 8*(15-j) to get the correct byte
                packed[offset + j] = bytes1(uint8(amount >> (8 * (15 - j))));
            }

            // Store `accountId` as 4 bytes (big-endian)
            uint32 accountId = entries[i].accountId;
            for (uint256 j = 0; j < 4; j++) {
                packed[offset + 16 + j] = bytes1(uint8(accountId >> (8 * (3 - j))));
            }
        }

        return packed;
    }

    /**
     * @dev Decodes a big-endian, tight-encoded bytes array back into an array of JournalEntry.
     *      The array length must be a multiple of 20 bytes.
     */
    function toJournalEntries(bytes memory _bytes, uint256 _start, uint16 _length)
        internal
        pure
        returns (JournalEntry[] memory)
    {
        require(_bytes.length >= _start + _length, "decodeJournalEntries_outOfBounds");
        uint256 count = _length / 20;

        JournalEntry[] memory entries = new JournalEntry[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 offset = _start + i * 20;

            // 1) Decode amount (uint128) from 16 bytes big-endian
            uint128 amount;
            for (uint256 j = 0; j < 16; j++) {
                amount = (amount << 8) | uint128(uint8(_bytes[offset + j]));
            }

            // 2) Decode accountId (uint32) from 4 bytes big-endian
            uint32 accountId;
            for (uint256 j = 0; j < 4; j++) {
                accountId = (accountId << 8) | uint32(uint8(_bytes[offset + 16 + j]));
            }

            entries[i] = JournalEntry({amount: amount, accountId: accountId});
        }

        return entries;
    }
}
