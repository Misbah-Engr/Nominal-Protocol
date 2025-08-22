# Nominal Protocol — Sui Move Package

This package implements the Sui-side name registry per `SPECS.md`.

Status: v1 scaffold with full storage/flows; signature verification for meta registrations is left as a small, well-marked TODO (see notes below).

## Layout
- Move.toml — package manifest (pulls Sui Framework)
- sources/
  - errors.move — error codes
  - structs.move — `Record` struct utilities
  - registry.move — main module `nominal::registry`
- SPECS.md — design spec

## Public entry functions (module `nominal::registry`)
- init/share/admin:
  - init(owner, treasury, registration_fee, referrer_bps, ctx): Registry
  - share(reg, ctx)
  - set_registration_fee(reg, caller, amount)
  - set_coin_fee<T>(reg, caller, amount, allowed)
  - set_treasury(reg, caller, t)
  - set_referrer_bps(reg, caller, bps)
  - transfer_ownership(reg, caller, new_owner)
- direct registration:
  - register_sui(reg, payer, name, fee: Coin<SUI>, clock)
  - register_coin<T>(reg, payer, name, fee: Coin<T>, clock)
- meta registration (sponsored):
  - register_with_sig_sui(reg, relayer, p: RegisterWithSig, fee: Coin<SUI>, clock)
  - register_with_sig_coin<T>(reg, relayer, p: RegisterWithSig, fee: Coin<T>, clock)
- owner operations:
  - set_resolved(reg, caller, name, resolved: Option<address>, clock)
  - transfer_name(reg, caller, name, new_owner, clock)

See `SPECS.md` for parameter semantics and validation rules.

## Build and publish (localnet/devnet)
Requires Sui CLI and framework.

```bash
# In SUI/
sui move build

# (optional) start a local network, then publish
sui client publish --gas-budget 30000000
```

After `init`, share the returned `Registry` object once:
```bash
# assuming you captured the object id after init
sui client call \
  --package <package_id> \
  --module registry \
  --function share \
  --args <registry_object_id> \
  --gas-budget 2000000
```

## Meta registration signature note
Sui doesn’t use EIP-712. The module defines `RegisterWithSig` and enforces:
- deadline, per-name nonce, and relayer binding on-chain.
- TODO: add signature verification against `p.owner` using Sui’s crypto helpers.

Approach to implement verification:
- Extend `RegisterWithSig` to include `scheme: u8`, `pubkey: vector<u8>`, `sig: vector<u8>`.
- Build a digest from: domain(module addr, registry id, chain id) + struct(name, owner, relayer, coin, amount, deadline, nonce).
- Use the appropriate verifier based on `scheme` (e.g., `0x2::secp256k1::ecdsa_verify` or `0x2::ed25519::verify` once imported) and ensure the derived address from pubkey matches `p.owner` scheme/address.

Until that’s added, meta functions are wired and safe except they currently skip the crypto check (they still enforce relayer/deadline/nonce and exact-fee).

## Coins and fees
- SUI direct path requires exact `registration_fee` value.
- Allowlist other coins via `set_coin_fee<T>` (amount is in that coin’s minimal unit).
- Meta path splits fee to treasury and relayer using `referrer_bps`.

## Name validation
- `is_valid_name` enforces ASCII lowercase `a-z`, digits `0-9`, and `-` with 3..=63 length; cannot start/end with `-` or contain `--`.

## Events
- Registered, ResolvedUpdated, OwnershipTransferred, RegistrationFeeSet, CoinFeeSet, TreasurySet, ReferrerBpsSet.

## Next steps
- Implement signature verification as described.
- Add Move tests covering direct/meta flows, errors, and edge cases.
- Optionally implement two-step admin transfer.
