# Nominal Protocol — Sui Specs (v1)

This document describes a minimal, security-first name registry for Sui. It mirrors the EVM design where practical, while adopting Sui-native primitives and patterns. The goal is to enable an independent Sui team to implement and audit the system without additional context.

## Goals
- Simple, explicit, and auditable.
- String-based names stored on-chain.
- ETH-equivalent: support payments in Sui Coin (SUI) and allowlisted fungible coins (Treasury-managed).
- Meta/sponsored tx: support relayer-bound signatures and short deadlines.
- No commit–reveal; use private tx + relayer binding + short deadlines for anti-sniping.
- Admin cannot seize names or mutate user data beyond fee/economics parameters.

## High-level model
- A single shared Registry object stores all names as dynamic fields keyed by ASCII-lowercase strings. Per-name nonces protect meta registration from replay.
- Each name maps to a Record struct: { owner: address, resolved: address | None, updated_at: u64 }.
- Payments: fixed registration fee in SUI; per-coin fixed fees for allowlisted `Coin<T>` types.
- Meta registration: off-chain signature by the future owner; on-chain validation binds signature to a specific relayer and deadline; relayer receives a referrer revenue share.

## Move package layout (suggested)
- `sources/registry.move`: core module implementing the registry.
- `sources/errors.move`: central error codes.
- `sources/structs.move`: type definitions (Record, ERC20Fee analogue, etc.).
- `sources/fixtures.move` (optional): test and demo helpers.
- `tests/*`: Move unit tests.

## Types and storage

- module address: `0x<published>`; module name: `nominal_registry`.

- Structs:
  - `struct Registry has key { id: UID, owner: address, treasury: address, registration_fee: u64, referrer_bps: u16, coin_fees: Table<type, u64>, names: Table<String, Record>, nonces: Table<String, u64> }`
    - `owner`: admin address (two-step transfer is optional in v1; can add later).
    - `treasury`: Sui address receiving treasury share.
    - `registration_fee`: price in SUI (microlamports) for `register_sui`.
    - `referrer_bps`: 0..=10000; paid to relayer on meta path.
    - `coin_fees`: map from coin type to fixed fee amount (in minimal units of that coin).
    - `names`: dynamic field map from lowercase string -> `Record`.
    - `nonces`: per-name nonce for meta registration.
  - `struct Record { owner: address, resolved: option::Option<address>, updated_at: u64 }`

- Event types:
  - `struct Registered { name: String, owner: address, payer: address, coin: vector<u8>, amount: u64 }`
  - `struct ResolvedUpdated { name: String, owner: address, resolved: option::Option<address> }`
  - `struct OwnershipTransferStarted { from: address, to: address }` (optional v1)
  - `struct OwnershipTransferred { from: address, to: address }`
  - `struct RegistrationFeeSet { amount: u64 }`
  - `struct CoinFeeSet { coin: vector<u8>, amount: u64, allowed: bool }`
  - `struct TreasurySet { treasury: address }`
  - `struct ReferrerBpsSet { bps: u16 }`

Notes:
- Represent `coin` in events as type name bytes via `type_name<T>()` or a canonical encoding.
- Use `0x0` address for None where display-friendly; internally use `option::Option`.

## Name rules
- Allowed: `a-z`, `0-9`, `-`.
- Must start with a letter or number; cannot start or end with `-`; no consecutive `-`.
- Length: 3..=63 bytes.
- Enforce ASCII only; reject mixed-case or unicode.

Implement `fn is_valid_name(name: &String): bool` that checks these constraints.

## Public API (entry functions)

- init and admin
  - `public entry fun init(owner: address, treasury: address, registration_fee: u64, referrer_bps: u16, ctx: &mut TxContext): Registry` — called once at publish or via an explicit initializer script; returns the created shared object to be shared immediately.
  - `public entry fun share(reg: Registry, ctx: &mut TxContext)` — converts to shared object (if not shared in `init`).
  - `public entry fun set_registration_fee(reg: &mut Registry, caller: &signer, amount: u64)` — only admin.
  - `public entry fun set_coin_fee<T>(reg: &mut Registry, caller: &signer, amount: u64, allowed: bool)` — only admin. If `allowed=false`, remove mapping.
  - `public entry fun set_treasury(reg: &mut Registry, caller: &signer, t: address)` — only admin; non-zero check.
  - `public entry fun set_referrer_bps(reg: &mut Registry, caller: &signer, bps: u16)` — only admin; bps <= 10000.
  - Ownership transfer (v1 simple):
    - `public entry fun transfer_ownership(reg: &mut Registry, caller: &signer, new_owner: address)` — only admin.

- direct registration (payer is owner)
  - `public entry fun register_sui(reg: &mut Registry, payer: &signer, name: String, fee: Coin<SUI>, clock: &Clock)`
    - Checks name validity, uniqueness.
    - Verifies `fee` amount equals `registration_fee` exactly; splits to treasury (100% in direct path; no referrer reward).
    - Mints/updates record with owner = `address_of(payer)`.
  - `public entry fun register_coin<T>(reg: &mut Registry, payer: &signer, name: String, fee: Coin<T>, clock: &Clock)`
    - Requires `T` is allowlisted and `fee.value == coin_fees[T]`.

- meta registration (sponsored)
  - Off-chain payload signed by future owner:
    - `struct RegisterWithSig { name: String, owner: address, relayer: address, coin: vector<u8>, amount: u64, deadline: u64, nonce: u64 }`
  - `public entry fun register_with_sig_sui(reg: &mut Registry, relayer: &signer, p: RegisterWithSig, fee: Coin<SUI>, clock: &Clock)`
    - Validates signature from `p.owner` over domain-separated digest (see Signatures).
    - Verifies `p.relayer == address_of(relayer)`; `p.coin == b"SUI"` and `p.amount == registration_fee`.
    - Verifies `clock.now() <= p.deadline` and `nonces[name] == p.nonce`; increments nonce.
    - Creates record with `owner = p.owner`.
    - Splits SUI fee: treasury gets `fee * (10000 - referrer_bps) / 10000`; relayer gets `fee * referrer_bps / 10000`.
  - `public entry fun register_with_sig_coin<T>(reg: &mut Registry, relayer: &signer, p: RegisterWithSig, fee: Coin<T>, clock: &Clock)`
    - Same validation; `p.coin` encodes `type_name<T>()`; amount equals `coin_fees[T]`.

- owner ops
  - `public entry fun set_resolved(reg: &mut Registry, caller: &signer, name: String, resolved: option::Option<address>)` — only current owner of name.
  - `public entry fun transfer_name(reg: &mut Registry, caller: &signer, name: String, new_owner: address)` — only current owner; `new_owner != 0x0`.

## Signatures
- Sui doesn’t have a chain-wide EIP-712; implement simple domain separation:
  - Domain = `hash( b"NominalRegistryV1", module_address, object_id(reg), chain_id )`.
  - Struct hash = `hash( name, owner, relayer, coin, amount, deadline, nonce )`.
  - Digest = `hash( 0x1901 || domain || struct_hash )`.
  - Accept ed25519 or secp256k1 signatures via `signature::verify` with `PublicKey` derived from `owner` address:
    - For Sui, `address` is derived from pubkey and scheme; verification can use `std::signature` helpers matching scheme encoded in `address`.
- All meta functions must:
  - Validate signature against digest and `owner`.
  - Enforce `relayer` binding to the signer of the transaction (sponsor).
  - Enforce strict deadline and per-name nonce equality, then increment storage nonce.

## Errors (codes)
- E_INVALID_NAME
- E_NAME_TAKEN
- E_WRONG_FEE
- E_COIN_NOT_ALLOWED
- E_UNAUTHORIZED
- E_ZERO_TREASURY
- E_BAD_BPS
- E_DEADLINE
- E_BAD_SIG
- E_WRONG_RELAYER

## Payments and splitting
- For SUI:
  - Use exact-amount `Coin<SUI>` argument. If larger sum is provided, the caller must split before calling; reject over/under payment.
  - Use safe coin operations to transfer to treasury and relayer.
- For other coins:
  - Maintain allowlist `coin_fees: Table<type, u64>`; require exact amount in minimal units.
  - Apply the same split logic on meta path; direct path sends 100% to treasury.
- Fee-on-transfer tokens are not supported; require exact transfer effects. If a coin has hooks that burn/skim, calls should fail.

## Anti-sniping
- No commit–reveal.
- Encourage private transactions for direct registration.
- For meta path, require short deadlines (e.g., seconds to minutes) and per-name nonces.
- Bind signature to a specific relayer address to prevent public mempool sniping.

## Security notes
- No reentrancy concern on Sui due to Move semantics, but still follow CEI pattern where appropriate.
- Validate name rules strictly; reject anything non-ASCII or mixed-case.
- Admin cannot mutate or seize per-user records; only economics and treasury params.
- All arithmetic uses u64 and u16 with bounds; bps <= 10_000.
- Avoid panics: return errors with codes above.

## Minimal ABI (function list)
- init/share
  - init(owner, treasury, registration_fee, referrer_bps)
  - share(reg)
- admin
  - set_registration_fee(reg, caller, amount)
  - set_coin_fee<T>(reg, caller, amount, allowed)
  - set_treasury(reg, caller, t)
  - set_referrer_bps(reg, caller, bps)
  - transfer_ownership(reg, caller, new_owner)
- direct
  - register_sui(reg, payer, name, fee, clock)
  - register_coin<T>(reg, payer, name, fee, clock)
- meta
  - register_with_sig_sui(reg, relayer, p, fee, clock)
  - register_with_sig_coin<T>(reg, relayer, p, fee, clock)
- owner ops
  - set_resolved(reg, caller, name, resolved)
  - transfer_name(reg, caller, name, new_owner)

## Test plan (high level)
- Happy paths: direct and meta registration for SUI and one allowlisted coin.
- Invalid names, duplicates.
- Wrong fee amounts (under/over) for both SUI and coin.
- Admin permissions and bounds (zero treasury, bps > 10000).
- Meta: wrong relayer, expired deadline, bad signature, replay (nonce), different coin/type.
- Owner ops access control.
- Coin with fee-on-transfer should fail (register_coin & meta path).

## Deployment and initialization
- Publish the package.
- Call `init(...)` from the admin address to create `Registry` object.
- Share the `Registry` (either from `init` or via `share`).
- Optionally, pre-configure coin fees via `set_coin_fee<T>`.

## Notes for SDKs
- Offer helpers to:
  - Validate names client-side.
  - Build and sign `RegisterWithSig` payloads with deadlines and nonces fetched from chain state.
  - Submit sponsored transactions for meta path with the relayer as sponsor and pay the split.
  - Detect and retry on `E_NAME_TAKEN` conflicts.
