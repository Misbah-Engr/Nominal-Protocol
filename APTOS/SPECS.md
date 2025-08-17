# Nominal Protocol on Aptos (MoveVM)

Specification for the Nominal name registry on Aptos, matching EVM/Sui/NEAR behavior while following Aptos Move conventions.

## Goals
- Pay-once, own-forever registration for lowercase [a-z0-9-] names, 3–63 chars, no leading/trailing/double '-'.
- Primary name support (address -> name) with safe transfer semantics.
- Payment paths:
  - Native APT coin.
  - Allowlisted fungible coins (by type).
  - Meta registration: relayer pays based on owner’s signed intent; relayer earns referrer split.
- Treasury and referrer split via basis points (bps out of 10_000).
- Strict validation, replay protection, minimal surface area.

## Core Types
- Registry resource (key):
  - owner: address (admin)
  - pending_owner: option<address>
  - treasury: address
  - registration_fee: u64 (APT, Octas)
  - referrer_bps: u16 (<= 10_000)
  - names: Table<u64, Record>
  - nonces: Table<u64, u64> (per-name)
  - coin_fees: Table<u64, u64> (type key -> required fee)
  - primary_names: Table<address, vector<u8>> (addr -> name bytes)
  - relayer_allowlist: Table<address, bool>
  - require_allowlisted_relayer: bool
- Record struct:
  - owner: address
  - resolved: option<address>
  - updated_at: u64 (timestamp::now_microseconds())

## API Surface
- Admin:
  - set_registration_fee(amount: u64)
  - set_coin_fee<CoinType>(amount: u64, allowed: bool)
  - set_treasury(addr: address)
  - set_referrer_bps(bps: u16)
  - add_relayer(addr: address)
  - remove_relayer(addr: address)
  - set_require_allowlisted_relayer(flag: bool)
  - transfer_ownership(new_owner: address)  // sets pending_owner
  - accept_ownership()                      // only pending_owner
- User:
  - register_apt(name: string, fee: Coin<APT>)
  - register_coin<CoinType>(name: string, fee: Coin<CoinType>)
  - register_with_sig_apt(name: string, owner: address, relayer: address, amount: u64, deadline: u64, nonce: u64, fee: Coin<APT>)
  - register_with_sig_coin<CoinType>(name: string, owner: address, relayer: address, amount: u64, deadline: u64, nonce: u64, fee: Coin<CoinType>)
  - set_resolved(name: string, resolved: option<address>)
  - transfer_name(name: string, new_owner: address)
  - set_primary_name(name: string)
  - name_of(addr: address): option<string>
  - get_record(name: string): option<Record>

## Meta/signature semantics
- Signed message (owner signs):
  - Register { name_hash: vector<u8>, owner: address, relayer: address, coin_key: u64, amount: u64, deadline: u64, nonce: u64 }
- Hashing:
  - digest = sha3_256( bcs::to_bytes((domain_tag, Register struct)) )
  - domain_tag = b"NominalRegistryV1:Aptos" || module_addr (to avoid cross-protocol replay)
- Signature:
  - ed25519 signature over digest; verify with aptos_std::ed25519::verify.
  - Authentication: compute owner’s authentication key and ensure it matches account::get_authentication_key(owner).
- Deadline/time:
  - Compare deadline against timestamp::now_microseconds(). Units documented as microseconds.
- Nonces:
  - Per-name nonces keyed by name_key(name). Require exact match, then increment on success.
- Relayer binding:
  - msg sender is relayer; require provided relayer == sender. If require_allowlisted_relayer is true, relayer must be allowlisted.

## Behavior
- Validation:
  - Names: length 3–63; chars a-z, 0-9, '-'; no leading/trailing or double '-'.
  - Availability: name must be unused.
  - Coin fees: register_coin requires coin_type allowlisted via set_coin_fee; fee is required per type.
- Payments and splits:
  - Direct (APT/coin): require at least required fee, split exact required fee to treasury; return change to payer.
  - Meta (APT/coin): payer is relayer; require at least expected amount and at least required fee; split required fee into treasury/referrer (relayer) using referrer_bps; return any change to relayer.
  - If referrer_bps == 0 no referrer transfer.
- Primary name:
  - Auto-set to the first registered name; later registrations do not override. On transfer, clear old owner’s primary if it matches; do not override new owner’s existing primary; if new owner has none, set transferred name.
- Effects ordering:
  - checks -> effects (create record, update primary) -> interactions (coin splits/transfers) -> change refund.
- updated_at uses timestamp::now_microseconds().

## Hashing & keys
- name_key(name: string): u64
  - h = sha3_256(utf8(name)); return fold64(h) (e.g., first 8 bytes little-endian).
- coin_type_key<CoinType>(): u64
  - h = sha3_256(bcs::to_bytes(type_name<CoinType>())); return fold64(h).
- Rationale: compact, stable keys for Tables; collision risk negligible for our domain.

## Events
- Registered { name: string, owner: address, payer: address, coin: vector<u8>, amount: u64 }
- FeePaid { name: string, payer: address, coin: vector<u8>, total: u64, referrer: option<address>, ref_amt: u64, treasury_amt: u64 }
- RegistrationFeeChanged { amount: u64 }
- TreasuryChanged { treasury: address }
- ReferrerBpsChanged { bps: u16 }
- CoinFeeSet { coin: vector<u8>, amount: u64, allowed: bool }
- PrimaryNameSet { owner: address, name: string }
- OwnershipAdminTransferInitiated { new_owner: address }
- OwnershipAdminAccepted { new_owner: address }
- RelayerAdded { relayer: address }
- RelayerRemoved { relayer: address }
- RequireAllowlistedRelayerChanged { enabled: bool }

## Errors
- E_INVALID_NAME, E_NAME_TAKEN, E_NAME_NOT_FOUND, E_NOT_OWNER, E_UNAUTHORIZED,
  E_WRONG_RELAYER, E_DEADLINE, E_BAD_SIG, E_WRONG_FEE, E_COIN_NOT_ALLOWED,
  E_INVALID_BPS, E_RELAYER_NOT_ALLOWED.

## Security considerations
- Admin-only setters; non-zero treasury; bps <= 10_000.
- Enforce relayer allowlist when enabled for both APT and generic-coin meta paths.
- Strong domain separation in signed payload to prevent cross-chain/repo replay.
- Bounded name sizes; avoid unbounded loops/copies.

## Testing strategy
- Admin access control and bounds (fee, bps, treasury non-zero).
- Name validation edge cases.
- Direct and meta registrations (APT and generic coins), referrer splits, and change refunds.
- Primary name auto-set, explicit set, and transfer semantics.
- Nonce increments, wrong relayer, expired deadline, bad signature.
- Coin fee allowlist gates.
- Relayer allowlist: add/remove/toggle; negative/positive meta paths.
- Event emission counts/types for all admin and payment paths.

## Gas/performance
- Linear validation over bounded names; minimize string copies.
- Split only when needed (avoid intermediate splits when bps=0).

## Upgrades & governance
- Non-upgradable module by default. For upgrades, publish new module and provide migration.
- Two-step ownership transfer via pending_owner + accept_ownership for safety.

## Parity notes
- Mirrors Sui closely (type-keyed fees, change refund, meta split).
- Aligns with EVM/NEAR (relayer allowlist, referrer split on meta, strict name checks).
- Aptos multi-agent could replace meta pattern in future work.
