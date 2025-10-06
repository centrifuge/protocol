# Managers

The Centrifuge protocol supports three balance sheet managers:

* **Gnosis Safe** or **Fireblocks wallet**: For direct control by the manager of the pool.
* [**On/Off Ramp Manager**](./OnOfframpManager.sol): Restricts asset flows to a set of predefined whitelisted addresses.
* [**Merkle Proof Manager**](./MerkleProofManager.sol): Enables integration with third-party protocols.
