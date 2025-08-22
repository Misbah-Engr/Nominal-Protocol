# Nominal Registry Solana - Complete Implementation Plan

## Overview

This is the complete implementation plan for the Nominal Protocol on Solana. The protocol is a simple, single-purpose name registry that allows users to register human-readable names and resolve them to Solana addresses. The contract is minimal and secure, with all complex cross-chain logic handled by the client-side SDK.

## Core Principles

1. **Single-purpose registry** - Each chain has its own independent contract
2. **Pay-once ownership** - No renewal fees, perpetual ownership
3. **Wallet revenue sharing** - Referrer fees for wallet providers via meta-transactions
4. **Multiple payment methods** - SOL and allowlisted SPL tokens
5. **Minimal on-chain footprint** - Complex logic handled by SDK
6. **Security first** - Non-upgradeable, strict validation, comprehensive testing

## Project Structure

```
nominal-registry-solana/
├── Anchor.toml
├── Cargo.toml
├── programs/
│   └── nominal-registry/
│       ├── Cargo.toml
│       └── src/
│           └── lib.rs (single file implementation)
├── tests/
│   ├── nominal-registry.ts
│   └── utils/
│       ├── setup.ts
│       └── helpers.ts
└── target/ (generated)
```

## Data Structures

### Registry Configuration
```rust
#[account]
pub struct RegistryConfig {
    pub admin: Pubkey,                    // 32 bytes - current admin
    pub pending_admin: Option<Pubkey>,    // 33 bytes - pending admin for 2-step transfer
    pub treasury: Pubkey,                 // 32 bytes - where fees go
    pub registration_fee: u64,            // 8 bytes - SOL fee in lamports
    pub referrer_bps: u16,                // 2 bytes - referrer basis points (0-10000)
    pub require_allowlisted_relayer: bool, // 1 byte - enforce relayer allowlist
    pub bump: u8,                         // 1 byte - PDA bump
}
```

### Name Record
```rust
#[account]
pub struct NameRecord {
    pub name: String,              // Variable - the registered name
    pub owner: Pubkey,             // 32 bytes - current owner
    pub resolved: Pubkey,          // 32 bytes - address this name resolves to
    pub updated_at: i64,           // 8 bytes - timestamp of last update
    pub bump: u8,                  // 1 byte - PDA bump
}
```

### Token Fee Configuration
```rust
#[account]
pub struct TokenFeeConfig {
    pub mint: Pubkey,              // 32 bytes - SPL token mint
    pub amount: u64,               // 8 bytes - required token amount
    pub enabled: bool,             // 1 byte - whether token is enabled
    pub bump: u8,                  // 1 byte - PDA bump
}
```

### Primary Name Registry
```rust
#[account]
pub struct PrimaryNameRegistry {
    pub owner: Pubkey,             // 32 bytes - address that owns the primary name
    pub name: String,              // Variable - the primary name
    pub bump: u8,                  // 1 byte - PDA bump
}
```

### Relayer Registry
```rust
#[account]
pub struct RelayerRegistry {
    pub relayers: Vec<Pubkey>,     // Variable - list of allowed relayers
    pub bump: u8,                  // 1 byte - PDA bump
}
```

## Program Instructions

### Administrative Instructions

#### 1. Initialize Registry
```rust
pub fn initialize(
    ctx: Context<Initialize>,
    registration_fee: u64,
    referrer_bps: u16,
) -> Result<()>
```
- Creates registry configuration PDA
- Sets initial admin, treasury, fees
- Initializes relayer registry
- Validates referrer_bps <= 10000

#### 2. Set Registration Fee
```rust
pub fn set_registration_fee(
    ctx: Context<SetRegistrationFee>,
    new_fee: u64,
) -> Result<()>
```
- Updates SOL registration fee
- Only admin can call
- Emits log for indexing

#### 3. Set Token Fee
```rust
pub fn set_token_fee(
    ctx: Context<SetTokenFee>,
    mint: Pubkey,
    amount: u64,
    enabled: bool,
) -> Result<()>
```
- Sets/updates fee for specific SPL token
- Creates or updates TokenFeeConfig PDA
- Only admin can call

#### 4. Set Treasury
```rust
pub fn set_treasury(
    ctx: Context<SetTreasury>,
    new_treasury: Pubkey,
) -> Result<()>
```
- Updates treasury address
- Only admin can call
- Validates new_treasury != Pubkey::default()

#### 5. Set Referrer BPS
```rust
pub fn set_referrer_bps(
    ctx: Context<SetReferrerBps>,
    bps: u16,
) -> Result<()>
```
- Updates referrer basis points
- Only admin can call
- Validates bps <= 10000

#### 6. Transfer Admin (Two-step)
```rust
pub fn transfer_admin(
    ctx: Context<TransferAdmin>,
    new_admin: Pubkey,
) -> Result<()>

pub fn accept_admin(
    ctx: Context<AcceptAdmin>,
) -> Result<()>
```
- Two-step admin transfer for safety
- Current admin initiates, new admin accepts

#### 7. Manage Relayers
```rust
pub fn add_relayer(
    ctx: Context<AddRelayer>,
    relayer: Pubkey,
) -> Result<()>

pub fn remove_relayer(
    ctx: Context<RemoveRelayer>,
    relayer: Pubkey,
) -> Result<()>

pub fn set_require_allowlisted_relayer(
    ctx: Context<SetRequireAllowlistedRelayer>,
    required: bool,
) -> Result<()>
```

### User Instructions

#### 1. Register Name (SOL Payment)
```rust
pub fn register_name(
    ctx: Context<RegisterName>,
    name: String,
) -> Result<()>
```
- Validates name format and availability
- Transfers SOL from user to treasury
- Creates NameRecord PDA
- Sets owner and resolved to caller
- Emits registration log

#### 2. Register Name (SPL Token Payment)
```rust
pub fn register_name_with_token(
    ctx: Context<RegisterNameWithToken>,
    name: String,
) -> Result<()>
```
- Validates name format and availability
- Checks token is enabled and user has enough balance
- Transfers tokens from user to treasury
- Creates NameRecord PDA
- Sets owner and resolved to caller

#### 3. Register Name with Signature (Meta-transaction)
```rust
pub fn register_name_with_signature(
    ctx: Context<RegisterNameWithSignature>,
    params: RegisterWithSigParams,
    signature: Vec<u8>,
) -> Result<()>
```
- Validates signature from intended owner
- Checks nonce, deadline, and relayer authorization
- Handles SOL or SPL token payment
- Splits fee between treasury and relayer
- Creates NameRecord PDA

```rust
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RegisterWithSigParams {
    pub name: String,
    pub owner: Pubkey,
    pub relayer: Pubkey,
    pub currency: Option<Pubkey>, // None = SOL, Some = SPL token mint
    pub amount: u64,
    pub deadline: i64,
    pub nonce: u64,
}
```

#### 4. Transfer Name Ownership
```rust
pub fn transfer_name(
    ctx: Context<TransferName>,
    name: String,
    new_owner: Pubkey,
) -> Result<()>
```
- Only current owner can transfer
- Updates name record owner
- Updates timestamp
- Updates primary name registry if necessary

#### 5. Set Resolved Address
```rust
pub fn set_resolved_address(
    ctx: Context<SetResolvedAddress>,
    name: String,
    new_resolved: Pubkey,
) -> Result<()>
```
- Only owner can update
- Updates resolved address field
- Updates timestamp
- Emits log

#### 6. Set Primary Name
```rust
pub fn set_primary_name(
    ctx: Context<SetPrimaryName>,
    name: String,
) -> Result<()>
```
- Only owner can set
- Creates or updates PrimaryNameRegistry PDA
- Enables reverse resolution (address -> name)

### Query Instructions (View Functions)

#### 1. Resolve Name
```rust
pub fn resolve_name(
    ctx: Context<ResolveQuery>,
    name: String,
) -> Result<ResolveResult>
```

```rust
#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ResolveResult {
    pub owner: Pubkey,
    pub resolved: Pubkey,
    pub updated_at: i64,
}
```

#### 2. Reverse Resolve
```rust
pub fn reverse_resolve(
    ctx: Context<ReverseResolveQuery>,
    address: Pubkey,
) -> Result<String>
```

## Name Validation

All names must pass strict validation:

```rust
fn validate_name(name: &str) -> Result<()> {
    // Length: 3-63 characters
    require!(name.len() >= 3 && name.len() <= 63, ErrorCode::InvalidNameLength);
    
    // Characters: a-z, 0-9, hyphen only
    for (i, c) in name.chars().enumerate() {
        let valid = c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-';
        require!(valid, ErrorCode::InvalidCharacter);
        
        // No leading/trailing hyphens
        if c == '-' {
            require!(i != 0 && i != name.len() - 1, ErrorCode::InvalidHyphenPlacement);
        }
    }
    
    // No consecutive hyphens
    require!(!name.contains("--"), ErrorCode::ConsecutiveHyphens);
    
    Ok(())
}
```

## PDA Derivation Seeds

- **Registry Config**: `["config"]`
- **Name Record**: `["name", name.as_bytes()]`
- **Token Fee Config**: `["token_fee", mint.as_ref()]`
- **Primary Name Registry**: `["primary", owner.as_ref()]`
- **Relayer Registry**: `["relayers"]`

## Error Codes

```rust
#[error_code]
pub enum ErrorCode {
    #[msg("Invalid name length (3-63 characters required)")]
    InvalidNameLength,
    #[msg("Invalid character in name (a-z, 0-9, - only)")]
    InvalidCharacter,
    #[msg("Invalid hyphen placement (no leading/trailing hyphens)")]
    InvalidHyphenPlacement,
    #[msg("Consecutive hyphens not allowed")]
    ConsecutiveHyphens,
    #[msg("Name already exists")]
    NameAlreadyExists,
    #[msg("Name not found")]
    NameNotFound,
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Invalid referrer basis points (max 10000)")]
    InvalidReferrerBps,
    #[msg("Invalid signature")]
    InvalidSignature,
    #[msg("Deadline expired")]
    DeadlineExpired,
    #[msg("Invalid nonce")]
    InvalidNonce,
    #[msg("Token not enabled")]
    TokenNotEnabled,
    #[msg("Insufficient token balance")]
    InsufficientTokenBalance,
    #[msg("Relayer not allowed")]
    RelayerNotAllowed,
    #[msg("Invalid treasury address")]
    InvalidTreasuryAddress,
}
```

## Security Considerations

### 1. PDA Validation
- Always verify bump seeds and derivation paths
- Use canonical bump seeds to prevent PDA grinding attacks

### 2. Signature Verification
- Use Ed25519 signatures for meta-transactions
- Include nonce to prevent replay attacks
- Validate deadline to prevent stale signatures
- Bind relayer to prevent signature theft

### 3. Token Safety
- Validate token accounts belong to expected mint
- Check balances before and after transfers
- Use proper SPL token program instructions
- Handle token account creation and funding

### 4. Access Control
- Strict owner/admin checks on all instructions
- Two-step admin transfer to prevent accidents
- Relayer allowlist enforcement when enabled

### 5. Arithmetic Safety
- Use checked arithmetic for fee calculations
- Validate all numeric inputs for overflow/underflow
- Proper basis points calculations (max 10000)

## Fee Structure

### Registration Fees
- **SOL**: Base fee set by admin (in lamports)
- **SPL Tokens**: Per-token amounts set by admin

### Payment Flows
1. **Direct Registration**: 100% to treasury
2. **Meta-transaction Registration**: Split based on referrer_bps
   - Treasury gets: `amount * (10000 - referrer_bps) / 10000`
   - Relayer gets: `amount * referrer_bps / 10000`

### Supported Tokens
- Initially: USDC, USDT (mainnet mints)
- Admin can enable any SPL token

## Testing Strategy

### Unit Tests
- Name validation edge cases
- PDA derivation correctness
- Fee calculation accuracy
- Access control enforcement

### Integration Tests
- Complete registration flows (SOL and SPL)
- Meta-transaction scenarios
- Transfer and update operations
- Admin function testing

### Security Tests
- Unauthorized access attempts
- Invalid signature testing
- Replay attack prevention
- Overflow/underflow scenarios

### Test Coverage Requirements
- 100% line coverage
- All error conditions tested
- Edge case validation
- Stress testing with maximum inputs

## Deployment Strategy

### Development Environment
1. Deploy to Solana devnet
2. Run full test suite
3. Manual testing of all functions
4. Gas optimization testing

### Production Deployment
1. Final security audit
2. Deploy to mainnet
3. Verify deployment
4. Initialize with production parameters
5. Set program as non-upgradeable

### Configuration Parameters
- **Registration Fee**: TBD (e.g., 0.001 SOL)
- **Referrer BPS**: 300 (3% for wallet providers)
- **Supported Tokens**: USDC, USDT initially
- **Treasury**: Nominal Protocol multisig

## Event Emission

Since Solana doesn't have native events, use program logs:

```rust
msg!("NameRegistered: name={}, owner={}, resolved={}", name, owner, resolved);
msg!("FeePaid: name={}, payer={}, amount={}, currency={}, referrer={}", 
     name, payer, amount, currency, referrer);
msg!("NameTransferred: name={}, old_owner={}, new_owner={}", 
     name, old_owner, new_owner);
msg!("ResolvedUpdated: name={}, owner={}, new_resolved={}", 
     name, owner, new_resolved);
```

## SDK Integration Points

The contract provides these endpoints for the client SDK:

1. **Name Resolution**: Query name records and primary names
2. **Registration**: Support for direct and meta-transaction registration
3. **Management**: Transfer, update resolved address, set primary
4. **Fee Information**: Query current fees for SOL and tokens
5. **Event Monitoring**: Track logs for indexing and notifications

## Cross-Chain Compatibility

This Solana implementation maintains compatibility with other chain implementations:

1. **Name Validation**: Identical rules across all chains
2. **Fee Structure**: Same referrer model and payment flows
3. **Meta-transactions**: Compatible signature and nonce patterns
4. **Event Structure**: Similar logging for consistent indexing

## Implementation Timeline

### Phase 1: Core Implementation (Week 1)
- Set up Anchor project structure
- Implement core data structures
- Implement basic instructions (register, transfer, set_resolved)
- Basic name validation

### Phase 2: Advanced Features (Week 2)
- Meta-transaction support with signature verification
- SPL token payment integration
- Admin functions and access control
- Primary name registry (reverse resolution)

### Phase 3: Testing & Security (Week 3)
- Comprehensive test suite
- Security testing and validation
- Gas optimization
- Integration testing

### Phase 4: Deployment & Documentation (Week 4)
- Deploy to devnet and test
- Final security review
- Deploy to mainnet
- SDK integration documentation

## Success Criteria

1. **Functionality**: All specified instructions work correctly
2. **Security**: Pass comprehensive security testing
3. **Performance**: Gas-efficient operations
4. **Compatibility**: Works with existing wallet integrations
5. **Testing**: 100% test coverage with all edge cases
6. **Documentation**: Complete integration guides

This plan provides a complete roadmap for implementing the Nominal Protocol on Solana with no gaps, following the proven patterns from the EVM, SUI, and Aptos implementations while adapting to Solana's unique architecture.
