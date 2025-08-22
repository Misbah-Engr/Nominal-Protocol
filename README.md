# Nominal Protocol

A comprehensive cross-chain naming service protocol supporting human-readable addresses across multiple blockchain networks including Solana, EVM chains, Aptos, SUI, and NEAR.

## Architecture Overview

The Nominal Protocol is a multi-chain naming registry that enables users to register and resolve human-readable names across different blockchain ecosystems. This repository contains the implementation for all supported chains:

- **SOLANA**: Anchor-based program for Solana blockchain
- **EVM**: Solidity smart contracts for Ethereum and EVM-compatible chains  
- **APTOS**: Move language implementation for Aptos blockchain
- **SUI**: Move implementation for SUI blockchain
- **NEAR**: Rust smart contracts for NEAR Protocol

## Chain-Specific Implementations

### Solana Implementation

The Solana implementation uses the Anchor framework and provides:
- Human‑readable name to address mapping
- Primary name management per user
- Token-based registration fees
- Signature-based registration with relayer support
- Multi-token fee configuration

## Contents
1. Quick Start
2. Environment Setup
3. Build & Test Workflow
4. Program Architecture
5. Accounts & PDAs
6. Instructions (APIs)
7. Relayer / Signature Flow
8. Token Fee Configuration
9. Referrer / Revenue Split Model
10. Development Conventions
11. Troubleshooting
12. Next Steps & Research Links

---
## 1. Quick Start

```bash
git clone https://github.com/Misbah-Engr/Nominal-Registry-Solana.git
cd Nominal-Registry-Solana
anchor build        # compile the on-chain program
anchor test         # run mocha/TypeScript integration tests
```

The test suite covers:
- Admin configuration (fees, treasury, referrer BPS, admin transfer)
- SOL name registration & validation (length, charset, hyphen rules)
- Primary name management
- Token fee config + SPL token registration path
- Signature registration (SOL) with relayer referrer share
- (Extend soon) Signature registration with SPL tokens + referrer distribution
- Relayer allowlist add / remove (if `require_allowlisted_relayer` enabled)

## 2. Environment Setup

Prerequisites:
- Rust (stable) + cargo
- Anchor CLI (>= 0.31.x)
- Solana CLI (>= 1.18.x)
- Node.js 18+ & yarn (tests use ts-mocha)

Install Anchor & Solana (example):
```bash
sh -c "$(curl -sSfL https://release.solana.com/stable/install)"   # Solana
cargo install --git https://github.com/coral-xyz/anchor avm --locked
avm install latest
avm use latest
anchor --version
solana --version
```

Set local cluster (optional for manual tx):
```bash
solana-test-validator --reset
```

Configure keypair (if you manually interact):
```bash
solana-keygen new --outfile ~/.config/solana/id.json
```

## 3. Build & Test Workflow

```bash
anchor build                # compile BPF
anchor test                 # builds + runs TS integration tests
anchor test --skip-build    # rerun tests without rebuilding
```

Generated artifacts:
- `target/idl/nominal_registry.json` – IDL
- `target/types/nominal_registry.ts` – TypeScript types consumed by tests / SDK

Common fast iteration loop:
1. Edit program in `programs/nominal-registry/src/lib.rs`
2. `anchor build`
3. (Optional) copy updated IDL to external consumer
4. `anchor test --skip-local-validator` (already configured in package script) for faster runs

## 4. Program Architecture

Design goals (see litepaper): minimal on‑chain surface, deterministic PDAs, no dynamic resize paths except controlled `init_if_needed`, and explicit fee channels. The program stores:
- Global `RegistryConfig` (admin, treasury, registration fee, referrer_bps, feature flag for relayer allowlist)
- Individual `NameRecord` PDAs (`["name", name_bytes]`)
- `PrimaryNameRegistry` per user (`["primary", user_pubkey]`), preallocated to max name length to avoid `ConstraintSpace` mismatches
- `TokenFeeConfig` per mint (`["token_fee", mint]`) for SPL token pricing
- Relayer allowlist entries (if implemented) (`["relayer", relayer_pubkey]`)

All economic logic related to cross‑chain proof aggregation is intentionally excluded here.

## 5. Accounts & PDAs

| Account | Seed Schema | Purpose |
|---------|-------------|---------|
| RegistryConfig | `b"config"` | Global admin & pricing config |
| NameRecord | `b"name" + name_bytes` | Name metadata: owner, resolved, updated_at |
| PrimaryNameRegistry | `b"primary" + user_pubkey` | User’s chosen primary handle |
| TokenFeeConfig | `b"token_fee" + mint_pubkey` | Token fee amount + enabled flag |
| (RelayerEntry) | `b"relayer" + relayer_pubkey` | Allowlisted relayer wallet (referrer recipient) |

Sizing notes:
- Primary name space: `8 + 37 + 63 (max name)` bytes preallocated.
- Name record alloc uses `8 + 77 + name.len()` (conservative buffer for string + fields).

## 6. Instructions (High Level)

Administrative:
- `initialize(registration_fee, referrer_bps)`
- `set_registration_fee(new_fee)`
- `set_treasury(new_treasury)`
- `set_referrer_bps(bps)`
- `set_token_fee(mint, amount, enabled)`
- `transfer_admin(new_admin)` / `accept_admin()`
- (Planned) `add_relayer(relayer)` / `remove_relayer(relayer)`
- (Planned) `set_require_allowlisted_relayer(flag)`

User / Relayer:
- `register_name(name)` (SOL)
- `register_name_with_token(name)` (SPL token)
- `register_name_with_signature(params, signature)` (SOL, relayer flow)
- (Planned) `register_name_with_signature_token(params, signature)` (SPL token via relayer)
- `transfer_name(name, new_owner)`
- `set_resolved_address(name, new_resolved)`
- `set_primary_name(name)`

Validation rules: 3–63 chars, lowercase a–z, digits, single hyphens, no leading/trailing/consecutive hyphens.

## 7. Relayer / Signature Flow

The signature path allows a wallet (relayer) to pay fees on behalf of the user / owner and receive a referrer share (currently computed; referrer portion implicitly retained by relayer). Planned enhancement: explicit token signature path and on-chain relayer allowlist enforcement when `require_allowlisted_relayer` is true.

Signature params structure:
```rust
pub struct RegisterWithSigParams { name, owner, relayer, currency: Option<Pubkey>, amount, deadline, nonce }
```
Current implementation only processes the SOL branch (`currency == None`). Token branch & signature verification primitives (ed25519) can be extended later.

## 8. Token Fee Configuration

`set_token_fee` (admin): stores (mint, amount, enabled) in `TokenFeeConfig`. When `register_name_with_token` is called:
1. Checks `enabled`
2. CPI transfer from user ATA to treasury ATA
3. Emits fee event log line

Future: per-mint referrer overrides, stablecoin basket, dynamic pricing.

## 9. Referrer / Revenue Split

`referrer_bps` (0–10_000) applied to registration fee. In current code path for SOL signature registration:
- `referrer_amount = fee * referrer_bps / 10_000`
- `treasury_amount = fee - referrer_amount`
- Treasury receives only `treasury_amount`; relayer retains (or can forward) referrer portion.

Tests assert treasury delta equals `fee - referrer_amount` for signature path.

## 10. Development Conventions

Coding:
- Use PDAs with explicit seeds & stored bump
- Avoid implicit realloc; preallocate for max-length where growth possible
- Keep error codes descriptive & stable

Testing patterns (`tests/nominal-registry.ts`):
- Deterministic PDA derivation helpers inline
- Airdrop & randomization for parallel name tests
- Token tests use @solana/spl-token to mint and measure balances

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `AccountDidNotSerialize` on primary name | Insufficient space | Use max preallocation (already implemented) |
| `ConstraintSpace` Left/Right mismatch | Resized string growth | Preallocate max or re-init with larger space |
| Unexpected cfg warnings | Anchor macros referencing internal features | Features added in Cargo.toml |
| Deprecated realloc warning | Anchor internal macro (0.31.x) | Safe to ignore until Anchor upgrades |

## 12. Next Steps & Research

From the litepaper (see `litepaper.txt`):
- Add relayer allowlist & governance toggle
- Implement SPL token signature registration
- Off-chain SDK authority scoring (Temporal, Volume, Connectivity factors)
- Potential ZK privacy layer for private resolution

## 13. License

TBD (add a license file to clarify usage and contributions).

---
### Contribution
PRs and issues welcome. Please include:
- Rationale & scope
- Tests covering new logic
- IDL impact notes (if instruction changed)

---
### Minimal Command Reference
```bash
anchor build
anchor test
solana address   # show local key
```

---
For conceptual background read the full litepaper: `litepaper.txt`.
=======
# Nominal Protocol

Nominal Resolution Protocol is a cross-chain name resolution framework that abstracts cryptographic wallet addresses into a single, human-readable namespace across separate and non-compatible blockchain networks, including EVM (Ethereum), MoveVM (Aptos, Sui), NEAR, and other execution environments.

## Features

- **Cross-chain name resolution**: Resolve human-readable names to addresses across different blockchains
- **Bidirectional resolution**: Resolve from names to addresses AND from addresses to names
- **Pay once, own forever**: No recurring fees or annual renewals
- **Wallet revenue sharing**: Integration partners can earn a percentage of registration fees
- **Multi-token payment support**: Register names using native tokens or popular stablecoins
- **Security-first design**: Non-upgradeable contracts with minimal trust assumptions
- **Primary name system**: Set a primary name for reverse resolution

## Project Structure

- **EVM/**: Ethereum implementation
  - Solidity contracts for name registry
  - Bidirectional name resolution (name→address, address→name)
  - Test suite and deployment scripts using Foundry
  
- **APTOS/**: Move implementation for Aptos blockchain
  - Move modules for name registry and resolution
  - Test framework using the Aptos Move test harness
  - Docker-based test environment
  
- **SUI/**: Move implementation for Sui blockchain
  - Move modules for name registry and primary name system
  - Comprehensive test suite
  
- **NEAR/**: NEAR Protocol implementation
  - Rust contracts for the Nominal registry
  - Test suite and deployment scripts

## Documentation

For detailed technical information, see:
- [EVM Architecture](EVM/ARCHITECTURE.md)
- [Primary Name System](EVM/PRIMARYNAME.md)
- [Litepaper](EVM/litepaper.txt)
- [Sui Specifications](SUI/SPECS.md)
- [Aptos Specifications](APTOS/SPECS.md)

## Development & Testing

### EVM (Ethereum)
```bash
cd EVM
forge test
```

### Aptos
```bash
cd APTOS
./run_tests.sh
```

### Sui
```bash
cd SUI
sui move test
```

### NEAR
```bash
cd NEAR
./build_and_test.sh
```

## Cross-chain FT Fees and Referrer Payouts

Overview of how fungible token fees are configured and how referrer splits work across VMs:

### EVM
- **Fees**: `setRegistrationFee(wei)` for ETH; `setERC20Fee(token, amount, enabled)` per token.
- **Register (direct)**: ETH/ERC20 → 100% to treasury.
- **Register with signature**: ETH/ERC20 → referrer split to relayer (based on `referrerBps`), remainder to treasury.
- **Relayers**: Admin can `setRelayer(addr, allowed)` and toggle enforcement via `setRequireRelayerAllowlist(bool)`; when enabled, only allowlisted relayers can perform meta registrations.

### Aptos
- **Fees**: `set_registration_fee(amount)` for native; `set_coin_fee<C>(amount, allowed)` per coin type.
- **Register (direct)**: Coins → 100% to treasury.
- **Register with signature**: Coins → referrer split to relayer; remainder to treasury.
- **Relayers**: Admin can `add_relayer/remove_relayer` and `set_require_allowlisted_relayer(bool)`; enforced in meta registration flows when enabled.

### NEAR
- **Fees**: `set_registration_fee(amount)` for native; `set_coin_fee(token_account_id, amount, enabled)` per NEP-141.
- **Register (native)**: 100% to treasury.
- **Register with signature (native)**: referrer split to relayer; remainder to treasury.
- **FT path via `ft_on_transfer`**: takes only the required fee; optional referrer split if `relayer` provided in msg; refunds overpayment via return value; remainder to treasury.
- **Relayers**: Admin can `add_relayer/remove_relayer` and `set_require_allowlisted_relayer(bool)`; enforced in meta native and FT flows when enabled.

### SUI
- **Fees**: `set_registration_fee(amount)` for SUI; `set_coin_fee<T>(amount, allowed)` per coin type.
- **Register (SUI/coin)**: sends required fee to treasury; returns change to payer.
- **Register with signature (SUI/coin)**: referrer split to relayer; remainder to treasury; returns change to payer.
- **Relayers**: Admin can `add_relayer/remove_relayer` and `set_require_allowlisted_relayer(bool)`; enforced in register_with_sig_sui and register_with_sig_coin.

### BPS Configuration
- All chains use `referrer_bps` out of 10,000 to compute the referrer share from the required fee.

### Refund Semantics
- EVM/NEAR native and ERC20 exact amounts are enforced in meta and direct flows (no change), except NEAR FT returns unused via `ft_on_transfer` return.
- SUI and Aptos return any overpayment (change) in both direct and meta flows.

## Name Validation

All implementations enforce consistent validation rules for names:
- Minimum length: 3 characters
- Maximum length: 63 characters
- Allowed characters: lowercase letters (a-z), digits (0-9), and hyphens (-)
- Cannot start or end with a hyphen
- Cannot contain consecutive hyphens

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

For questions or feedback, please open an issue on GitHub.
>>>>>>> protocol/main
