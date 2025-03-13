# Centrifuge Pools Invariant Suite

This repository contains the invariant suite for the Centrifuge Pools.

## Setup

### Target Functions
Because the `PoolManager` functions can only be called via the `PoolRouter`, which calls them via the `execute` function, the target functions in `PoolRouterTargets` use the abi encoding of the `PoolRouter` functions to queue calls in an array. They can then be executed in a single transaction in the `execute_clamped` function which makes all the queued calls and clears the queue.

This allows greater path exploration because the fuzzer would be unlikely to call the functions with the necessary bytes passed directly.  

### Differences From Actual Implementation
The `adapter` set on the `Gateway` is set to the address of a `MockAdapter` in the `Setup` contract. This is a simplification to allow the necessary logic but it shouldn't forward calls made to the `execute` function because these should be made directly via the `PoolRouterTargets` contract.

The current setup uses one instance of the 
`SingleShareClass` if the relationship between pools and Pools is one-to-many, more will need to be added.