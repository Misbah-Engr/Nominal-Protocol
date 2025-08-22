# Nominal Protocol - NEAR Implementation

This is the NEAR blockchain implementation of the Nominal Protocol, providing a universal name registry for cross-chain address resolution.

## Overview

The Nominal Protocol allows users to have a human-readable name across different blockchains. This implementation follows the same core principles as the EVM and SUI versions:

- Single, minimal contract per chain
- Pay-once model for name registration
- Support for primary name bidirectional resolution
- Secure ownership and transfer mechanisms
- Support for various payment methods

## Build Commands

Build the contract:
```
cargo build --target wasm32-unknown-unknown --release
```

Run tests:
```
cargo test
```

Deploy to testnet:
```
near dev-deploy target/wasm32-unknown-unknown/release/nominal_protocol.wasm
```

## Quick Start

1. Initialize the contract:
```
near call <contract_id> new '{"owner": "<your_account_id>", "treasury": "<treasury_account_id>", "registration_fee": "1000000000000000000000000", "referrer_bps": 300}' --accountId <your_account_id>
```

2. Register a name:
```
near call <contract_id> register '{"name": "yourname"}' --accountId <your_account_id> --deposit 1
```

3. View a name record:
```
near view <contract_id> get_record '{"name": "yourname"}'
```

4. Look up an account's primary name:
```
near view <contract_id> name_of '{"account": "<account_id>"}'
```

## Features

- Register names with NEAR token payment
- Set and update primary names
- Resolve addresses
- Transfer name ownership
- Administrative functions for fee management

## Contract Interface

See the `src/lib.rs` file for the complete interface documentation.

## Implementation Notes

This implementation follows the same security patterns as the EVM and SUI versions:
- Checks-effects-interactions pattern
- Proper authorization checks
- Secure handling of primary names during transfers

For more detailed examples, see the `examples/interact.sh` script.
