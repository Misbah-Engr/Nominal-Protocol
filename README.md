# Nominal Protocol
## Cross-Chain Name Resolution Infrastructure

**The first production-ready naming protocol that works natively across all major blockchain virtual machines.**

Nominal Protocol help users interact with decentralized applications using human-readable names that work seamlessly across Solana, EVM chains, Aptos, SUI, and NEAR. This repository contains the complete implementation, deployment tools, and SDK architecture for building cross-chain naming services.

---

## What This Solves

Traditional blockchain addresses are unusable for human interaction:
- `0x742d35Cc6634C0532925a3b8D4021d38e29e0c7e` (Ethereum)
- `EWnxMePYL4SJP2JMfHffwyCJFnsVqmvi4sNwukro7ZmE` (Solana)
- `0x435598fcdb806330ced52fefaaa9d140e9cd43e5f2936c9d4497ad9a7e5b867e` (Aptos)

Nominal Protocol enables this instead:
- Send tokens to **`alice`** across any supported chain
- One name resolves to different addresses on different chains
- Primary name system for reverse resolution (address → name)
- Pay once, own forever - no subscription fees

---

## Architecture Overview

### Multi-VM Implementation Strategy

This isn't just another naming service. We've implemented the same core logic across **5 different virtual machines** using their native languages and paradigms:

| Chain | Language | VM | Implementation |
|-------|----------|----|----|
| **Solana** | Rust (Anchor) | Sealevel VM | Account-based with PDAs |
| **Ethereum + L2s** | Solidity | EVM | Contract-based storage |
| **Aptos** | Move | MoveVM | Resource-based architecture |
| **SUI** | Move | SUI Move | Object-based design |
| **NEAR** | Rust | NEAR VM | Account model with state |

### Core Design Principles

1. **Security First**: Non-upgradeable contracts, minimal trust assumptions
2. **Pay Once Model**: No recurring fees or renewals like traditional DNS
3. **Native Integration**: Each implementation follows chain-specific best practices
4. **Cross-Chain Consistency**: Same validation rules and behavior everywhere
5. **Developer Friendly**: Complete SDKs and integration documentation

---

## Repository Structure

```
Nominal-Registry-Solana/
├── SOLANA/              # Anchor program implementation
│   ├── programs/        # On-chain Rust code
│   ├── tests/           # TypeScript integration tests
│   └── Anchor.toml      # Program configuration
├── EVM/                 # Solidity implementation
│   ├── src/             # Smart contracts
│   ├── test/            # Foundry test suite
│   └── script/          # Deployment scripts
├── APTOS/               # Move implementation
│   ├── sources/         # Move modules
│   ├── tests/           # Move test framework
│   └── Move.toml        # Package configuration
├── SUI/                 # SUI Move implementation
│   ├── sources/         # Move packages
│   ├── tests/           # SUI test framework
│   └── Move.toml        # Package configuration
├── NEAR/                # NEAR Protocol implementation
│   ├── src/             # Rust contracts
│   ├── tests/           # Integration tests
│   └── Cargo.toml       # Rust configuration
├── chain-addresses.json # All deployed contract addresses
├── ABI_DOCUMENTATION.md # Complete interface specifications
├── DEVELOPER_HANDOFF.md # SDK development guide
└── deployment scripts  # Automated deployment tools
```

---

## Core Features

### 1. Name Registration & Resolution

**Register a name once, use it everywhere:**

```typescript
// Register "alice" on Ethereum
await registry.register("alice", { value: ethers.parseEther("0.001") });

// Resolve "alice" on any chain
const aliceEth = await registry.resolveToAddress("alice"); // 0x123...
const aliceSui = await suiRegistry.resolveToAddress("alice"); // 0x456...
```

### 2. Primary Name System

**Reverse resolution for better UX:**

```typescript
// Set primary name
await registry.setPrimaryName("alice");

// Anyone can now resolve your address back to "alice"
const name = await registry.resolveToName("0x123..."); // returns "alice"
```

### 3. Multi-Token Fee Support

**Pay with native tokens or stablecoins:**

```solidity
// Pay with ETH
registry.register{value: 0.001 ether}("alice");

// Pay with USDC
usdc.approve(registry, 1000000); // 1 USDC
registry.registerERC20("alice", usdcAddress);
```

### 4. Referrer Revenue Sharing

**Wallets earn fees for integrating:**

```typescript
// Wallet registers user with signature and earns 10% fee
await registry.registerWithSignature(
  params,
  signature // Wallet keeps referrer portion automatically
);
```

### 5. Cross-Chain Name Validation

**Consistent rules everywhere:**

- Length: 3-63 characters
- Characters: `a-z`, `0-9`, `-` (hyphen)
- No leading/trailing hyphens
- No consecutive hyphens
- Case insensitive (stored lowercase)

---

## Quick Start

### Prerequisites

```bash
# Install required tools
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
npm install -g @solana/cli
npm install -g @project-serum/anchor-cli
```

### Clone & Test Everything

```bash
git clone https://github.com/Misbah-Engr/Nominal-Registry-Solana.git
cd Nominal-Registry-Solana

# Test Solana implementation
cd SOLANA && anchor test

# Test EVM implementation  
cd ../EVM && forge test

# Test Aptos implementation
cd ../APTOS && ./run_tests.sh

# Test SUI implementation
cd ../SUI && sui move test

# Test NEAR implementation
cd ../NEAR && ./build_and_test.sh
```

### Connect to Deployed Contracts

All contract addresses are in `chain-addresses.json`:

```json
{
  "ethereum_sepolia": {
    "registry_contract": "0xa3D1fC54925F57af34B0C86F5B12BD5fD309fFcA",
    "chain_id": 11155111
  },
  "solana": {
    "program_id": "6TVpb5Ga5c8mfgiFRddf8T1sGFJbgtzcj2WFQBB1gFMq",
    "network": "devnet"
  }
  // ... all other chains
}
```

---

## Advanced Features

### Signature-Based Registration (Gasless)

Users can register names without holding native tokens for gas:

```typescript
// User signs registration message
const message = {
  name: "alice",
  owner: userAddress,
  relayer: relayerAddress,
  currency: "0x0", // ETH
  amount: "1000000000000000", // 0.001 ETH
  deadline: Math.floor(Date.now() / 1000) + 3600,
  nonce: await registry.nonces("alice")
};

const signature = await user.signTypedData(domain, types, message);

// Relayer submits transaction and pays gas
await registry.registerWithSignature(message, signature);
```

### Token Fee Configuration

Admins can configure payment tokens per chain:

```solidity
// Enable USDC payments on Ethereum
registry.setERC20Fee(
  "0xA0b86a33E6441E6fE9C56d2D2e0C4C9D1f9D7c0D", // USDC
  1000000, // 1 USDC (6 decimals)
  true // enabled
);
```

### Relayer Management

Control who can submit signature-based registrations:

```solidity
// Add trusted relayer
registry.setRelayer(relayerAddress, true);

// Require relayer allowlist
registry.setRequireRelayerAllowlist(true);
```

---

## SDK Development

### Complete Interface Documentation

See `ABI_DOCUMENTATION.md` for detailed interfaces for all chains:

- **Solana**: Anchor IDL with instruction accounts
- **EVM**: Complete Solidity ABI with events
- **Aptos**: Move entry functions and view functions
- **SUI**: Move package functions with object types
- **NEAR**: Contract methods with parameters

### Recommended SDK Architecture

```typescript
interface NominalSDK {
  // Cross-chain resolution
  resolveToAddress(name: string, chain?: ChainId): Promise<string>;
  resolveToName(address: string, chain: ChainId): Promise<string>;
  
  // Registration
  register(name: string, chain: ChainId, options?: RegisterOptions): Promise<TxResult>;
  
  // Name management
  transferName(name: string, newOwner: string, chain: ChainId): Promise<TxResult>;
  setPrimaryName(name: string, chain: ChainId): Promise<TxResult>;
  
  // Utilities
  validateName(name: string): ValidationResult;
  checkAvailability(name: string, chains?: ChainId[]): Promise<AvailabilityMap>;
}
```

### Integration Examples

**MetaMask Integration:**
```typescript
const provider = new ethers.BrowserProvider(window.ethereum);
const registry = new ethers.Contract(REGISTRY_ADDRESS, ABI, provider);

// Replace address input with name resolution
const recipient = await registry.record(nameInput);
if (recipient.owner !== "0x0000000000000000000000000000000000000000") {
  // Use recipient.resolved for transaction
}
```

**Phantom Wallet Integration:**
```typescript
const connection = new Connection("https://api.devnet.solana.com");
const program = anchor.workspace.NominalRegistry;

// Derive name record PDA
const [nameRecord] = PublicKey.findProgramAddressSync(
  [Buffer.from("name"), Buffer.from("alice")],
  program.programId
);

const record = await program.account.nameRecord.fetch(nameRecord);
// Use record.resolved for transaction
```

---

## Security & Auditing

### Security Model

1. **Non-Upgradeable Contracts**: Once deployed, core logic cannot be changed
2. **Minimal Admin Functions**: Only fee configuration and treasury management
3. **Input Validation**: Strict name format enforcement
4. **Reentrancy Protection**: Guards against common attack vectors
5. **Time-Bound Signatures**: Prevent replay attacks with deadlines

### Audit Preparation

The codebase is structured for security auditing:

- **Comprehensive test coverage** across all chains
- **Standardized error handling** patterns
- **Clear separation** of admin and user functions
- **Documentation** of all invariants and assumptions
- **Integration test suites** covering cross-contract interactions

### Known Considerations

1. **Cross-Chain Consistency**: No on-chain verification that names resolve to same entity
2. **Name Squatting**: First-come-first-served model may enable speculation
3. **Admin Key Management**: Treasury and fee configuration require secure key management
4. **Network Congestion**: Registration costs may spike during high demand

## Deployment Guide

### Manual Deployment

Each chain directory contains specific deployment instructions:

- **Solana**: `anchor deploy` with program keypair
- **EVM**: `forge create` with constructor parameters
- **Aptos**: `aptos move publish` with Move package
- **SUI**: `sui client publish` with package build
- **NEAR**: `near deploy` with WASM compilation

## Roadmap & Future Development

### Phase 1: Core Infrastructure
- [x] Multi-chain registry implementation
- [x] Cross-chain name resolution
- [x] Primary name system
- [x] Referrer revenue sharing
- [x] Complete test suites

### Phase 2: Production SDK (In Progress)
- [ ] TypeScript SDK for all chains
- [ ] React hooks for easy integration
- [ ] Demo wallet implementations
- [ ] Documentation and examples

### Phase 3: Advanced Features (Planned)
- [ ] Subdomain support (`alice.bob`)
- [ ] Expiration and renewal system
- [ ] Governance and fee adjustment
- [ ] Cross-chain name verification
- [ ] Integration with ENS and other naming services

### Phase 4: Privacy & Scaling (Research)
- [ ] Zero-knowledge name resolution
- [ ] Layer 2 scaling solutions
- [ ] Private name ownership proofs
- [ ] Decentralized relayer networks

---

## Contributing

We welcome contributions from the crypto development community:

### Development Setup

1. **Fork** the repository
2. **Install** dependencies for your target chain
3. **Run** the test suite to ensure everything works
4. **Make** your changes with comprehensive tests
5. **Submit** a pull request with detailed description

### Coding Standards

- **Rust**: Follow standard `rustfmt` formatting
- **Solidity**: Use consistent naming and documentation
- **Move**: Follow Move best practices for resource safety
- **TypeScript**: Use strict typing and consistent patterns

### Testing Requirements

All contributions must include:
- **Unit tests** for new functionality
- **Integration tests** for cross-contract interactions
- **Gas optimization** analysis where applicable
- **Documentation** updates for user-facing changes

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

The protocol is designed to be:
- **Open Source**: Anyone can integrate, fork, or extend
- **Non-Restrictive**: No gatekeeping or permission required
- **Community Driven**: Governed by usage and adoption

---

## Support & Community

### Contact & Support

- **GitHub Issues**: Bug reports and feature requests
- **Discussions**: Technical questions and integration help
- **Email**: misbahu.abubakar@nominalid.com

### Integration Partners

We're actively working with wallet providers, dApp developers, and other infrastructure projects. If you're building in the multi-chain space, we'd love to collaborate.

---

*Nominal Protocol makes blockchain addresses human.*
