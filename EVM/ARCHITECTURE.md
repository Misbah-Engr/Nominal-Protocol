# Nominal EVM Architecture (v1)

A minimal, security-first name registry for EVM chains that matches the litepaper: single-purpose on-chain registry, client-side SDK does the heavy lifting, no bridges, pay-once, wallet rev-share, stablecoin payments. Simple to reason about, hard to break.

## Scope and goals

- Single contract per chain; no proxies; no external trust.
- Store: owner, resolved EVM address, last update time per name.
- Names are normalized off-chain and referenced on-chain directly as `string` keys.
- Client SDK handles normalization, cross-chain propagation, authority score, and UX.
- Pay-once registration; optional wallet-provider revenue share; accept ETH and selected ERC-20 stablecoins.

## Contract surface: NameRegistryV1

- Deterministic deploy with CREATE2 (salt: `NOMINAL_REGISTRY_V1`) for predictable addresses across EVM chains.
- Non-upgradeable; changes ship as V2 with a new address. Safety > upgrade complexity.

### Storage layout

- `mapping(string => Record) records`
  - `Record { address owner; address resolved; uint64 updatedAt; }`
- `mapping(string => uint256) nonces` — per-name EIP-712 replay protection.
- `uint256 registrationFee` — in wei; base price for ETH path.
- `struct ERC20Fee { address token; uint256 amount; bool enabled; }` — allowlisted stablecoins.
- `uint16 referrerBps` — protocol-wide referrer share (e.g., 300 = 3%).
- `address treasury` — protocol fee sink.
- Two-step admin (`owner`, `pendingOwner`). Admin powers are bounded to: fee values, token allowlist, referrerBps, treasury; admin cannot seize names.

### Events

- `event Registered(string indexed name, address indexed owner)`
- `event ResolvedUpdated(string indexed name, address indexed resolved)`
- `event OwnershipTransferred(string indexed name, address indexed oldOwner, address indexed newOwner)`
- `event FeePaid(string indexed name, address indexed payer, address currency, uint256 amount, address referrer)`
- `event ERC20FeeSet(address token, uint256 amount, bool enabled)`
- `event RegistrationFeeSet(uint256 amountWei)`
- `event TreasurySet(address treasury)`
- `event ReferrerBpsSet(uint16 bps)`

### External interface (concise)

- `function record(string calldata name) external view returns (address owner, address resolved, uint64 updatedAt)`
- `function register(string calldata name) external payable` — ETH path; no referrer.
- `function registerERC20(string calldata name, address token) external` — ERC-20 path; no referrer.
- `function registerWithSig(RegisterWithSig calldata p, bytes calldata sig) external` — EIP-712 meta path; referrer is enforced as `msg.sender` and currency (ETH vs ERC-20) is selected in `p` and enforced; relayer-binding requires `msg.sender == p.relayer`.
- `function setResolved(string calldata name, address newResolved) external` — only owner.
- `function transferName(string calldata name, address newOwner) external` — only owner.
- Admin: `setRegistrationFee`, `setERC20Fee(token, amount, enabled)`, `setTreasury`, `setReferrerBps`, two-step `transferOwnership/acceptOwnership`.

Notes:
- Name strings are first-class keys. The contract validates normalization and allowed charset; the SDK also normalizes strictly to reduce user error.
- Referrer revenue share is ONLY available via `registerWithSig`, and the referrer is hard-set to `msg.sender` (wallet/relayer). Direct `register` and `registerERC20` do not accept a referrer and pay 0% to referrers.

## Name normalization (SDK responsibility)

- Lowercase ASCII; allowed chars: `a-z`, `0-9`, `-`; 3–32 chars; no leading/trailing `-`; single hyphen grouping.
- On-chain validation: `isValidName(string)` enforces the same rules; the contract REJECTS non-normalized names (no implicit lowercasing on-chain to keep behavior explicit).
- SDK ensures consistent normalization across chains.

## Flows

### Register

- Pre-checks: `records[name].owner == address(0)`.
- Pay once (two direct paths):
  - ETH: `register(name)` requires `msg.value == registrationFee`.
  - ERC-20: `registerERC20(name, token)` requires `token` is enabled; contract pulls the configured amount via `transferFrom(msg.sender, address(this), ERC20Fee[token].amount)`.
- Effects: `owner = msg.sender`, `resolved = msg.sender` (sane default), `updatedAt = block.timestamp`.
- Payout: 100% of fee to `treasury`; no referrer on this path. Pull-style transfers for ERC-20 to avoid reentrancy; ETH via call after effects.
- Emit `Registered` and `FeePaid` with the indexed `name`.
  - For `FeePaid`, set `currency = address(0)` for ETH, or the ERC-20 token address; `referrer = address(0)` on direct paths.

### Register with signature (optional meta)

- EIP-712 typed data `Register`:
  - `name (string)`, `owner (address)`, `relayer (address)`, `currency (address)`, `amount (uint256)`, `deadline (uint256)`, `nonce (uint256)`.
  - `currency == address(0)` denotes ETH; otherwise it must be an allowlisted ERC-20 token.
- Anyone can call `registerWithSig` and pay gas; signature must match `owner`. Nonce consumed; deadline enforced.
 - Payment enforcement:
  - If ETH: require `msg.value == registrationFee` and ignore `amount`.
  - If ERC-20: check token is enabled and `amount == configuredAmount`, then `transferFrom(msg.sender, address(this), amount)`.
- Relayer-binding: require `msg.sender == relayer` to prevent signature theft and copycats.
- Referrer is determined as `msg.sender` (i.e., the relayer); fee split pays `referrerBps` to `msg.sender`, remainder to `treasury`.
- Useful when a wallet/provider wants to pay gas or route via a relayer and receive rev-share.

### Update resolved address

- Only `record.owner` can call `setResolved(name, newResolved)`.
- Effects: update `resolved`, bump `updatedAt`.
- No cooldown in v1; wallets should prompt confirmations. Cross-chain last-write-wins is handled by the SDK using `updatedAt`.

### Transfer ownership

- Only `owner` can call `transferName(name, newOwner)`; updates `owner` and `updatedAt`.

## Security choices (minimal but tight)

- Strings are used as keys; mitigations:
  - Strict length (3–32) and charset bounds keep hashing cost predictable.
  - No loops over names; O(1) access only.
  - Events index the name; storage struct does not redundantly store the string.
- Checks-Effects-Interactions; ETH transfers after state updates; ERC-20 via safe transfer helpers.
- ReentrancyGuard on payable paths; no external callbacks except token transfers and ETH payouts to known addresses.
- Replay-safe EIP-712 meta path with per-name nonces and deadlines.
- Admin is constrained; cannot modify or seize user state. Admin changes are two-step.
- Deterministic deployment with CREATE2; bytecode and salt are audited and published; SDK verifies address against expected salt and init code hash.
- Gas griefing: storage is O(1) per name; no unbounded loops.

Front-running: v1 relies on fast registration and SDK UX (pre-commit locally, broadcast immediately). If needed, v1.1 adds commit-reveal:
- `commit = keccak256(bytes(name), owner, secret)` -> `commit(commit)` then a separate `reveal(name, owner, secret)` after a min delay. This would be introduced in v1.1 with dedicated endpoints; v1 keeps the ABI minimal.

No commit–reveal, simple anti-sniping (recommended):
- Private transactions: SDK submits `registerWithSig` via private RPC (e.g., Flashbots Protect / MEV-Share / provider private mempool) when available.
- Relayer-bound signatures: include `relayer` in the EIP-712 payload and enforce `msg.sender == relayer` on-chain.
- Short deadlines: keep `deadline` tight (e.g., ≤ 2 minutes) to reduce signature shelf-life.
- Per-name nonces: replay-safe and monotonic per `name`.
- Prefer meta path for hot names; leave direct register for low-risk UX.

## Economics

- One-time registration fee:
  - ETH path: `registrationFee` (in wei).
  - ERC-20 path: fixed per-token amounts (`USDC`, `USDT`, …) via allowlist.
- Referrer share: Applies only on `registerWithSig`; `referrer = msg.sender`.
- No renewals. Transfers and updates are free (gas-only).

## SDK responsibilities (per litepaper)

- Normalize names; ensure deterministic lowercase canonical form.
- Wallet UX: signatures, confirmations, and “user-as-relayer”. Use private transaction submission where possible.
- Cross-chain propagation: sign-and-push updates on other VMs; apply last-write-wins by `updatedAt`.
- Authority score computation off-chain; render as trust badge.
- Sanity checks: warn on near-simultaneous updates (timestamp deltas) and name collisions. Prefer `registerWithSig` for wallet-led flows that earn rev-share. Bind signatures to the relayer and set short deadlines.

## Minimal ABI (for integration)

Only the essentials wallets need:
- `record(name) -> (owner, resolved, updatedAt)`
- `register(name)` payable
- `registerERC20(name, token)`
- `registerWithSig(p, sig)`
- `setResolved(name, newResolved)`
- `transferName(name, newOwner)`

## Differences vs old plan

- Uses on-chain `string` as the primary key with strict validation.
- Removes rename flow from on-chain logic (register new name instead); simpler and safer.
- No mandatory cooldowns; keeps UX snappy; SDK handles safety prompts.
- Adds ERC-20 stablecoin fee path and deterministic deployment.
- Referrer split applies only on `registerWithSig` and is paid to `msg.sender` (wallet/relayer); direct register paths carry no referrer.

## Test checklist (green before done)

- Register (ETH, USDC) happy paths; duplicate name rejected.
- Update resolved; transfer ownership; timestamps increase.
- Referrer payouts (ETH and ERC-20) correct to the wei.
- Admin changes bounded; cannot affect user records.
- EIP-712 `registerWithSig` correct domain separator, nonce, deadline; rejects when `msg.sender != relayer`.

## Next steps

- Implement `NameRegistryV1.sol` per this spec.
- Publish ABI and TypeChain types; ship SDK adapters (normalize, validation, typed-data helpers).
- Add v1.1 commit-reveal if frontrunning observed in practice.
