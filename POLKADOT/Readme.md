## these smart contracts are under development...

we’re expanding the Name Registry to Polkadot parachains using ink!, the Rust-based smart contract framework for Substrate. This will let wallets resolve human-readable names across Polkadot-native chains in the same seamless multi-chain UX our SDK already supports.
This will showcase the beautiful features ink! language features in smart contract development, and open doors for better UX across all chains.

## Goals

1. **Multi-chain compatibility**: Deploy registry contracts on multiple parachains (e.g., Moonbeam, Astar, Shiden) with a uniform interface.
2. **Permissionless registration**: Anyone can claim a name on any supported parachain.
3. **Global validation via SDK**: Wallets can continue to enforce global uniqueness across chains without adding central bottlenecks.
4. **Event-driven indexing**: Emit events for wallet SDKs and off-chain indexers to detect registrations and releases.

## Development Phases

### Phase 1: Core Ink! Contract

* **Language**: Rust + Ink! 6.0+
* **Registry Contract Features**:

  * `register(name: String, owner: AccountId)`
  * `owner_of(name: String) -> Option<AccountId>`
  * `name_of(owner: AccountId) -> Option<String>`
  * `release(name: String)`
* **Events**:

  * `NameRegistered { owner: AccountId, name: String }`
  * `NameReleased { owner: AccountId, name: String }`
* **Testing**: Unit tests in `cargo test` for all critical flows, including duplicate registration attempts.

### Phase 2: Cross-Parachain SDK Integration

* The Ink! contract will emit standard events compatible with our **multi-chain SDK**.
* Wallets can read Ink! events to determine **local vs global status**.
* SDK handles:

  * Parallel registration checks
  * Global status computation
  * UX-friendly status badges

### Phase 3: Deployment & Testnet

* Deploy contracts on **Polkadot testnet parachains**.
* Integrate SDK with testnet wallets supporting Polkadot chains.
* Monitor registrations, validate event indexing, and test rollback/resolution logic.

### Phase 4: Auditing & Security

* Internal audits for:

  * Reentrancy attacks
  * Race conditions for simultaneous registrations
  * Proper owner verification before release
* Optional: Community security review (bug bounty) for early adopters.

### Phase 5: Mainnet Launch (Polkadot)

* Deploy audited contracts to selected mainnet parachains.
* Publish SDK npm package updates for Polkadot support.
* Onboard partner wallets for seamless global registration experience

---

## Key Principles

* **Permissionless**: Conracts remain open, no centralized gatekeeper.
* **Interoperable**: SDK enables multi-chain coordination across Polkadot + Solana, Near, Aptos, SUI, and EVM chains.
* **Minimal & Auditable**: Core contracts are small, easy to review, and emit all necessary events.
* **Wallet-driven UX**: Global registration is optional but deterministic for wallets enforcing the rules.

---

### Coming Soon

* Testnet deployments of Ink! registry contracts.
* SDK integration with partner Polkadot wallets.
* Early community testing and feedback for global multi-chain name resolution.

> Stay tuned: Polkadot support is coming fast, keeping Nominal Names **permissionless, decentralized, and multi-chain ready**.
