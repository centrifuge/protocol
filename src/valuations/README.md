# Valuations

The valuations module provides price feed implementations for valuing pool holdings in the Hub. Valuation contracts implement `IValuation` and are used by `Holdings` to convert asset amounts to pool-denominated values for NAV calculations and accounting.

### `IdentityValuation`

`IdentityValuation` provides a 1:1 valuation implementation that always returns a price of 1.0, performing only decimal conversion between assets and pool currency without any price adjustments. This valuation is suitable for stablecoins, wrapped tokens, or other pegged assets where the exchange rate is assumed to be constant.

### `OracleValuation`

`OracleValuation` provides asset valuation via trusted price feeders who can update prices on-chain. Prices are denominated in the pool currency and stored per pool, share class, and asset. The contract uses a quorum of 1 (no price aggregation) and allows pool managers to authorize feeders who can set prices.