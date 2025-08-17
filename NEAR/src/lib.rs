use near_sdk::borsh::{self, BorshDeserialize, BorshSerialize};
use near_sdk::collections::{LookupMap, UnorderedMap};
use near_sdk::json_types::U128;
use near_sdk::serde::{Deserialize, Serialize};
use near_sdk::{
    env, near_bindgen, AccountId, Balance, Gas, PanicOnDefault, Promise, PromiseOrValue,
};
use near_sdk::ext_contract;
use near_sdk::BorshStorageKey;

// Gas constant for cross-contract FT transfers (10 Tgas)
const GAS_FOR_FT_TRANSFER: Gas = near_sdk::Gas(10_000_000_000_000);

// External interface for NEP-141 tokens we call into
#[ext_contract(ext_ft)]
pub trait ExtFungibleToken {
    fn ft_transfer(&mut self, receiver_id: AccountId, amount: U128, memo: Option<String>);
}

/// Record struct that stores information about a registered name
#[derive(BorshDeserialize, BorshSerialize, Serialize, Deserialize, Clone)]
#[serde(crate = "near_sdk::serde")]
pub struct Record {
    pub owner: AccountId,
    pub resolved: Option<AccountId>,
    pub updated_at: u64,
}

/// Storage keys for collections
#[derive(BorshSerialize, BorshStorageKey)]
enum StorageKey {
    Names,
    Nonces,
    CoinFees,
    PrimaryNames,
    Relayers,
}

/// Main contract for the Nominal Protocol on NEAR
#[near_bindgen]
#[derive(BorshDeserialize, BorshSerialize, PanicOnDefault)]
pub struct NominalRegistry {
    /// Contract owner
    owner: AccountId,
    
    /// Treasury account where fees are sent
    treasury: AccountId,
    
    /// Base registration fee in yoctoNEAR
    registration_fee: Balance,
    
    /// Referrer basis points (e.g., 300 = 3%)
    referrer_bps: u16,
    
    /// Maps name hash to Record
    names: LookupMap<u64, Record>,
    
    /// Maps name hash to nonce for replay protection
    nonces: LookupMap<u64, u64>,
    
    /// Maps token contract ID to fee amount
    coin_fees: UnorderedMap<AccountId, Balance>,
    
    /// Maps account ID to primary name
    primary_names: LookupMap<AccountId, String>,

    /// Allowlisted relayers and gate flag
    relayers: UnorderedMap<AccountId, bool>,
    require_allowlisted_relayer: bool,
}

#[near_bindgen]
impl NominalRegistry {
    #[init]
    pub fn new(
        owner: AccountId,
        treasury: AccountId,
        registration_fee: U128,
        referrer_bps: u16,
    ) -> Self {
        assert!(!env::state_exists(), "Already initialized");
        assert!(referrer_bps <= 10000, "BPS must be <= 10000");
        
        Self {
            owner,
            treasury,
            registration_fee: registration_fee.0,
            referrer_bps,
            names: LookupMap::new(StorageKey::Names),
            nonces: LookupMap::new(StorageKey::Nonces),
            coin_fees: UnorderedMap::new(StorageKey::CoinFees),
            primary_names: LookupMap::new(StorageKey::PrimaryNames),
            relayers: UnorderedMap::new(StorageKey::Relayers),
            require_allowlisted_relayer: false,
        }
    }
    
    /// Register a name with NEAR payment
    #[payable]
    pub fn register(&mut self, name: String) -> PromiseOrValue<()> {
        let sender = env::predecessor_account_id();
        let deposit = env::attached_deposit();
        let timestamp = env::block_timestamp();
        
        self.register_internal(
            &sender,
            name,
            &sender,
            deposit,
            timestamp,
            false,
            None,
            0,
            0,
            None,
        )
    }
    
    /// NEP-141 FT transfer hook for registering via FT payments
    /// msg JSON: {"action":"register","name":"<name>","owner":"<optional>","relayer":"<optional>","deadline":0,"nonce":0}
    /// Semantics:
    /// - Only the configured fee amount for this token is taken.
    /// - If `relayer` is present, a referrer split is paid out of the required fee.
    /// - Any overpayment (amount - required_fee) is returned by the FT contract using the returned U128 value.
    pub fn ft_on_transfer(&mut self, sender_id: AccountId, amount: U128, msg: String) -> PromiseOrValue<U128> {
        let token_account = env::predecessor_account_id();
        let now = env::block_timestamp();

        #[derive(Serialize, Deserialize)]
        #[serde(crate = "near_sdk::serde")]
        struct FtMsg { action: String, name: String, owner: Option<AccountId>, relayer: Option<AccountId>, deadline: Option<u64>, nonce: Option<u64> }

        let parsed: FtMsg = near_sdk::serde_json::from_str(&msg).expect("Invalid FT msg");
        assert!(parsed.action == "register", "Unsupported FT action");

    let required = self.coin_fees.get(&token_account).expect("Token not allowed");
    assert!(amount.0 >= required, "Insufficient FT amount");

        // Validate name and availability
        self.assert_valid_name(&parsed.name);
        let key = Self::name_key(&parsed.name);
        assert!(self.names.get(&key).is_none(), "Name is already taken");

        let owner = parsed.owner.clone().unwrap_or_else(|| sender_id.clone());
        // If relayer is provided and gating is enabled, enforce allowlist
        if self.require_allowlisted_relayer {
            if let Some(r) = &parsed.relayer {
                assert!(self.relayers.get(r).unwrap_or(false), "Relayer not allowlisted");
            }
        }
        if let Some(n) = parsed.nonce {
            let current = self.nonces.get(&key).unwrap_or(0);
            assert!(current == n, "Invalid nonce");
            self.nonces.insert(&key, &(current + 1));
        }

        // Effects: create record and primary
        self.register_record_and_primary(&parsed.name, &owner, now);

        // Interactions: forward tokens for the required fee only (referrer split if relayer present)
        let ref_cut = parsed
            .relayer
            .as_ref()
            .map(|_| required * (self.referrer_bps as u128) / 10_000u128)
            .unwrap_or(0);
        let to_treasury = required - ref_cut;
        if ref_cut > 0 {
            ext_ft::ext(token_account.clone())
                .with_attached_deposit(1)
                .with_static_gas(GAS_FOR_FT_TRANSFER)
                .ft_transfer(parsed.relayer.clone().unwrap(), U128(ref_cut), None);
        }
        if to_treasury > 0 {
            ext_ft::ext(token_account.clone())
                .with_attached_deposit(1)
                .with_static_gas(GAS_FOR_FT_TRANSFER)
                .ft_transfer(self.treasury.clone(), U128(to_treasury), Some(format!("Nominal fee for {}", parsed.name)));
        }

        // Event: log the required amount taken
        self.emit_registered(&parsed.name, &owner, &sender_id, required);
        // Log fee split details for FT payment
        env::log_str(&format!(
            "FeePaid: name={}, payer={}, currency={}, total={}, referrer={}, ref_amt={}, treasury_amt={}",
            parsed.name,
            sender_id,
            token_account,
            required,
            parsed.relayer.clone().map(|a| a.to_string()).unwrap_or_else(|| "null".to_string()),
            ref_cut,
            to_treasury
        ));

        // Return unused to trigger refund by FT contract
        let unused = amount.0 - required;
        PromiseOrValue::Value(U128(unused))
    }
    
    /// Register a name using a meta transaction with signature
    #[payable]
    pub fn register_with_sig(
        &mut self,
        name: String,
        owner: AccountId,
        relayer: AccountId,
        amount: U128,
        deadline: u64,
        nonce: u64,
    _signature: Vec<u8>,
    ) -> PromiseOrValue<()> {
        let sender = env::predecessor_account_id();
        let deposit = env::attached_deposit();
        let timestamp = env::block_timestamp();
        
        // Verify the signature (in a real implementation, this would validate the signature)
        // For security, we require the sender to be either the owner or the specified relayer
        assert!(
            sender == owner || sender == relayer,
            "Unauthorized: sender must be owner or relayer"
        );
        if self.require_allowlisted_relayer {
            assert!(self.relayers.get(&relayer).unwrap_or(false), "Relayer not allowlisted");
        }
        
        self.register_internal(
            &sender,
            name,
            &owner,
            deposit,
            timestamp,
            true,
            Some(relayer),
            amount.0,
            deadline,
            Some(nonce),
        )
    }
    
    /// Set the resolved account for a name
    pub fn set_resolved(&mut self, name: String, resolved: Option<AccountId>) {
        self.assert_valid_name(&name);
        let name_key = Self::name_key(&name);
        let record = self.assert_name_exists_and_owned(&name_key);
        
        let mut updated_record = record.clone();
        updated_record.resolved = resolved;
        updated_record.updated_at = env::block_timestamp();
        
        self.names.insert(&name_key, &updated_record);
        
        self.emit_resolved_updated(&name, &updated_record.owner, &updated_record.resolved);
    }
    
    /// Transfer name ownership to a new account
    pub fn transfer_name(&mut self, name: String, new_owner: AccountId) {
        self.assert_valid_name(&name);
        let name_key = Self::name_key(&name);
        let record = self.assert_name_exists_and_owned(&name_key);
        
        let old_owner = record.owner.clone();
        
        let mut updated_record = record.clone();
        updated_record.owner = new_owner.clone();
        updated_record.updated_at = env::block_timestamp();
        
        self.names.insert(&name_key, &updated_record);
        
        // Handle primary name transfers
        // If this was the old owner's primary name, clear it
        if let Some(primary_name) = self.primary_names.get(&old_owner) {
            if primary_name == name {
                self.primary_names.remove(&old_owner);
            }
        }
        
        // If the new owner doesn't have a primary name, set this as their primary
        // We do not override existing primary names during transfers
        if self.primary_names.get(&new_owner).is_none() {
            self.primary_names.insert(&new_owner, &name);
            self.emit_primary_name_set(&new_owner, &name);
        }
        
        self.emit_ownership_transferred(&name, &old_owner, &new_owner);
    }
    
    /// Set a name as the primary name for the caller
    pub fn set_primary_name(&mut self, name: String) {
        self.assert_valid_name(&name);
        let name_key = Self::name_key(&name);
        let record = self.assert_name_exists_and_owned(&name_key);
        
        let owner = record.owner.clone();
        self.primary_names.insert(&owner, &name);
        
        self.emit_primary_name_set(&owner, &name);
    }
    
    /// Get the primary name for an account
    pub fn name_of(&self, account: AccountId) -> Option<String> {
        self.primary_names.get(&account)
    }
    
    /// Get record details for a name
    pub fn get_record(&self, name: String) -> Option<Record> {
        self.assert_valid_name(&name);
        let name_key = Self::name_key(&name);
        self.names.get(&name_key)
    }
    
    /// Admin: set registration fee
    pub fn set_registration_fee(&mut self, amount: U128) {
        self.assert_owner();
        self.registration_fee = amount.0;
        // Log event
        env::log_str(&format!("RegistrationFeeChanged: {}", amount.0));
    }
    
    /// Admin: set coin fee for a fungible token
    pub fn set_coin_fee(&mut self, token: AccountId, amount: U128, enabled: bool) {
        self.assert_owner();
        
        if enabled {
            self.coin_fees.insert(&token, &amount.0);
        } else if self.coin_fees.get(&token).is_some() {
            self.coin_fees.remove(&token);
        }
        
        // Log event
        env::log_str(&format!(
            "CoinFeeSet: token={}, amount={}, enabled={}",
            token, amount.0, enabled
        ));
    }
    
    /// Admin: set treasury account
    pub fn set_treasury(&mut self, treasury: AccountId) {
        self.assert_owner();
        self.treasury = treasury.clone();
        // Log event
        env::log_str(&format!("TreasuryChanged: {}", treasury));
    }
    
    /// Admin: set referrer basis points
    pub fn set_referrer_bps(&mut self, bps: u16) {
        self.assert_owner();
        assert!(bps <= 10000, "BPS must be <= 10000");
        self.referrer_bps = bps;
        // Log event
        env::log_str(&format!("ReferrerBpsChanged: {}", bps));
    }

    /// Admin: add a relayer to the allowlist
    pub fn add_relayer(&mut self, relayer: AccountId) {
        self.assert_owner();
        self.relayers.insert(&relayer, &true);
        env::log_str(&format!("RelayerAdded: {}", relayer));
    }

    /// Admin: remove a relayer from the allowlist
    pub fn remove_relayer(&mut self, relayer: AccountId) {
        self.assert_owner();
        if self.relayers.get(&relayer).is_some() {
            self.relayers.remove(&relayer);
        }
        env::log_str(&format!("RelayerRemoved: {}", relayer));
    }

    /// Admin: toggle enforcement of the relayer allowlist
    pub fn set_require_allowlisted_relayer(&mut self, enabled: bool) {
        self.assert_owner();
        self.require_allowlisted_relayer = enabled;
        env::log_str(&format!("RequireAllowlistedRelayerChanged: {}", enabled));
    }
    
    /// Admin: transfer contract ownership
    pub fn transfer_ownership(&mut self, new_owner: AccountId) {
        self.assert_owner();
        let old_owner = self.owner.clone();
        self.owner = new_owner.clone();
        // Log event
        env::log_str(&format!(
            "OwnershipTransferred: old_owner={}, new_owner={}",
            old_owner, new_owner
        ));
    }
    
    // Internal methods
    
    /// Internal registration logic used by all registration methods
    fn register_internal(
        &mut self,
        actor: &AccountId,
        name: String,
        owner: &AccountId,
        deposit: Balance,
        timestamp: u64,
        meta: bool,
        relayer: Option<AccountId>,
        amount_expected: Balance,
        deadline: u64,
        nonce: Option<u64>,
    ) -> PromiseOrValue<()> {
        // Validate the name
        self.assert_valid_name(&name);
        let name_key = Self::name_key(&name);
        
        // Check if name is available
        assert!(
            self.names.get(&name_key).is_none(),
            "Name is already taken"
        );
        
        // Validate meta transaction parameters
        if meta {
            if let Some(relayer_id) = &relayer {
                assert!(
                    relayer_id == actor,
                    "Wrong relayer: sender must match relayer"
                );
            }
            
            assert!(timestamp <= deadline, "Deadline exceeded");
            
            if let Some(n) = nonce {
                let current_nonce = self.nonces.get(&name_key).unwrap_or(0);
                assert!(current_nonce == n, "Invalid nonce");
                self.nonces.insert(&name_key, &(current_nonce + 1));
            }
            
            assert!(deposit >= amount_expected, "Insufficient deposit");
        }
        
        // Validate fee
        assert!(deposit >= self.registration_fee, "Insufficient fee");
        
        // Create the record (effects)
        self.register_record_and_primary(&name, owner, timestamp);
        
        // Process payment (interactions)
        self.process_payment(actor, &name, deposit, meta, relayer)
    }

    /// Internal helper: create record and set primary if missing
    fn register_record_and_primary(&mut self, name: &str, owner: &AccountId, timestamp: u64) {
        let name_key = Self::name_key(name);
        let record = Record { owner: owner.clone(), resolved: Some(owner.clone()), updated_at: timestamp };
        self.names.insert(&name_key, &record);
        if self.primary_names.get(owner).is_none() {
            self.primary_names.insert(owner, &name.to_string());
            self.emit_primary_name_set(owner, name);
        }
    }
    
    /// Process payment and handle fee distribution
    fn process_payment(&self, actor: &AccountId, name: &str, deposit: Balance, meta: bool, relayer: Option<AccountId>) -> PromiseOrValue<()> {
        if deposit > 0 {
            if meta {
                let ref_cut = relayer
                    .as_ref()
                    .map(|_| deposit * (self.referrer_bps as u128) / 10_000u128)
                    .unwrap_or(0);
                let to_treasury = deposit - ref_cut;
                if ref_cut > 0 { Promise::new(relayer.clone().unwrap()).transfer(ref_cut); }
                if to_treasury > 0 { Promise::new(self.treasury.clone()).transfer(to_treasury); }
                // Log fee split for native meta payment
                env::log_str(&format!(
                    "FeePaid: name={}, payer={}, currency=native, total={}, referrer={}, ref_amt={}, treasury_amt={}",
                    name,
                    actor,
                    deposit,
                    relayer.clone().map(|a| a.to_string()).unwrap_or_else(|| "null".to_string()),
                    ref_cut,
                    to_treasury
                ));
            } else {
                Promise::new(self.treasury.clone()).transfer(deposit);
                // Log fee for native direct payment
                env::log_str(&format!(
                    "FeePaid: name={}, payer={}, currency=native, total={}, referrer={}, ref_amt={}, treasury_amt={}",
                    name,
                    actor,
                    deposit,
                    "null",
                    0u128,
                    deposit
                ));
            }
        }
        self.emit_registered(name, &env::predecessor_account_id(), actor, deposit);
        PromiseOrValue::Value(())
    }
    
    /// Emit registered event
    fn emit_registered(
        &self,
        name: &str,
        owner: &AccountId,
        payer: &AccountId,
        amount: Balance,
    ) {
        env::log_str(&format!(
            "Registered: name={}, owner={}, payer={}, amount={}",
            name, owner, payer, amount
        ));
    }
    
    /// Emit resolved updated event
    fn emit_resolved_updated(
        &self,
        name: &str,
        owner: &AccountId,
        resolved: &Option<AccountId>,
    ) {
        let resolved_str = resolved
            .as_ref()
            .map_or("null".to_string(), |a| a.to_string());
        
        env::log_str(&format!(
            "ResolvedUpdated: name={}, owner={}, resolved={}",
            name, owner, resolved_str
        ));
    }
    
    /// Emit ownership transferred event
    fn emit_ownership_transferred(
        &self,
        name: &str,
        old_owner: &AccountId,
        new_owner: &AccountId,
    ) {
        env::log_str(&format!(
            "OwnershipTransferred: name={}, old_owner={}, new_owner={}",
            name, old_owner, new_owner
        ));
    }
    
    /// Emit primary name set event
    fn emit_primary_name_set(&self, owner: &AccountId, name: &str) {
        env::log_str(&format!(
            "PrimaryNameSet: owner={}, name={}",
            owner, name
        ));
    }
    
    /// Assert that the caller is the contract owner
    fn assert_owner(&self) {
        assert_eq!(
            env::predecessor_account_id(),
            self.owner,
            "Only the owner can call this method"
        );
    }
    
    /// Assert that a name is valid
    fn assert_valid_name(&self, name: &str) {
        assert!(is_valid_name(name), "Invalid name format");
    }
    
    /// Assert that a name exists and is owned by the caller
    fn assert_name_exists_and_owned(&self, name_key: &u64) -> Record {
        let record = self
            .names
            .get(name_key)
            .expect("Name does not exist");
        
        assert_eq!(
            record.owner,
            env::predecessor_account_id(),
            "Only the owner can manage this name"
        );
        
        record
    }
    
    // name validation helper moved out of impl to avoid JSON ABI exposure
    
    /// Generate a 64-bit key from a name
    fn name_key(name: &str) -> u64 {
        // This is a simple hash function for the example
        // In production, use a cryptographic hash and take the first 8 bytes
        let mut hash: u64 = 5381;
        for byte in name.bytes() {
            hash = ((hash << 5) + hash) + byte as u64;
        }
        hash
    }
}

/// Check if a name is valid (3-63 chars, lowercase a-z, 0-9, hyphen)
fn is_valid_name(name: &str) -> bool {
    if name.len() < 3 || name.len() > 63 {
        return false;
    }

    let bytes = name.as_bytes();
    let mut prev_hyphen = false;

    for (i, &c) in bytes.iter().enumerate() {
        let is_lower = c >= b'a' && c <= b'z';
        let is_digit = c >= b'0' && c <= b'9';
        let is_hyphen = c == b'-';

        if !(is_lower || is_digit || is_hyphen) {
            return false;
        }

        // No leading or trailing hyphens
        if is_hyphen && (i == 0 || i == bytes.len() - 1) {
            return false;
        }

        // No double hyphens
        if is_hyphen && prev_hyphen {
            return false;
        }

        prev_hyphen = is_hyphen;
    }

    true
}

// Add unit tests at the end of the file
#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::{accounts, VMContextBuilder};
    use near_sdk::testing_env;
    use near_sdk::serde_json::json;
    use near_sdk::test_utils::get_logs;
    
    // Helper function to create a context
    fn get_context(predecessor: AccountId) -> VMContextBuilder {
        let mut builder = VMContextBuilder::new();
        builder
            .current_account_id(accounts(0))
            .signer_account_id(predecessor.clone())
            .predecessor_account_id(predecessor);
        builder
    }
    
    #[test]
    fn test_name_validation() {
        // Valid names
    assert!(is_valid_name("abc"));
    assert!(is_valid_name("a1b-2c"));
    assert!(is_valid_name("nominal-protocol1"));
        
        // Invalid names
    assert!(!is_valid_name("ab"));  // Too short
    assert!(!is_valid_name("ABC"));  // Uppercase
    assert!(!is_valid_name("hello world"));  // Space
    assert!(!is_valid_name("-bad"));  // Leading hyphen
    assert!(!is_valid_name("bad-"));  // Trailing hyphen
    assert!(!is_valid_name("bad--bad"));  // Double hyphen
    }
    
    #[test]
    fn test_new() {
        let context = get_context(accounts(1));
        testing_env!(context.build());
        
        let contract = NominalRegistry::new(
            accounts(1),
            accounts(2),
            U128(1_000_000_000_000_000_000_000_000),  // 1 NEAR
            300,  // 3%
        );
        
        assert_eq!(contract.owner, accounts(1));
        assert_eq!(contract.treasury, accounts(2));
        assert_eq!(contract.registration_fee, 1_000_000_000_000_000_000_000_000);
        assert_eq!(contract.referrer_bps, 300);
    }

    fn init_contract() -> NominalRegistry {
        let context = get_context(accounts(1));
        testing_env!(context.build());
        NominalRegistry::new(
            accounts(1),
            accounts(2),
            U128(1_000_000_000_000_000_000_000_000),
            300,
        )
    }

    #[test]
    fn test_register_sets_record_and_primary_and_pays_fee() {
        let mut contract = init_contract();
        let mut context = get_context(accounts(3));
        context.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(context.build());

        let res = contract.register("alice-name".to_string());
        match res { PromiseOrValue::Value(()) => {}, _ => panic!("unexpected promise path") }

        // record exists
        let rec = contract.get_record("alice-name".to_string()).expect("record");
        assert_eq!(rec.owner, accounts(3));
        assert_eq!(rec.resolved, Some(accounts(3)));
        // primary set
        assert_eq!(contract.name_of(accounts(3)), Some("alice-name".to_string()));
    }

    #[test]
    #[should_panic(expected = "Insufficient fee")]
    fn test_register_requires_fee() {
        let mut contract = init_contract();
        let mut context = get_context(accounts(3));
        context.attached_deposit(1);
        testing_env!(context.build());
        let _ = contract.register("bob".to_string());
    }

    #[test]
    #[should_panic(expected = "Name is already taken")]
    fn test_register_duplicate_disallowed() {
        let mut contract = init_contract();
        // first
        let mut context = get_context(accounts(3));
        context.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(context.build());
        let _ = contract.register("taken-name".to_string());
        // second
        let mut context2 = get_context(accounts(4));
        context2.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(context2.build());
        let _ = contract.register("taken-name".to_string());
    }

    #[test]
    fn test_register_with_sig_meta_checks_and_referrer_split() {
        let mut contract = init_contract();
        // set context: relayer calls with sufficient deposit
    let mut ctx = get_context(accounts(4)); // relayer
        ctx.attached_deposit(2_000_000_000_000_000_000_000_000);
        ctx.block_timestamp(1000);
        testing_env!(ctx.build());
        let out = contract.register_with_sig(
            "charlie".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            2000,
            0,
            vec![],
        );
        match out { PromiseOrValue::Value(()) => {}, _ => panic!("unexpected") }

        let rec = contract.get_record("charlie".to_string()).expect("rec");
        assert_eq!(rec.owner, accounts(5));
        // primary set for owner (not relayer)
        assert_eq!(contract.name_of(accounts(5)), Some("charlie".to_string()));

        // nonce increments
        let key = NominalRegistry::name_key("charlie");
        assert_eq!(contract.nonces.get(&key).unwrap_or(0), 1);
    }

    #[test]
    #[should_panic(expected = "Unauthorized: sender must be owner or relayer")]
    fn test_register_with_sig_requires_owner_or_relayer() {
        let mut contract = init_contract();
    let mut ctx = get_context(accounts(3)); // not owner or relayer
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register_with_sig(
            "delta".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            1_000_000,
            0,
            vec![],
        );
    }

    #[test]
    #[should_panic(expected = "Deadline exceeded")]
    fn test_register_with_sig_deadline_enforced() {
        let mut contract = init_contract();
    let mut ctx = get_context(accounts(4)); // relayer
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        ctx.block_timestamp(2_000);
        testing_env!(ctx.build());
        let _ = contract.register_with_sig(
            "echo".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            1_500, // past
            0,
            vec![],
        );
    }

    #[test]
    #[should_panic(expected = "Invalid nonce")]
    fn test_register_with_sig_nonce_must_match() {
        let mut contract = init_contract();
        // Pre-bump nonce by inserting non-default
        let key = NominalRegistry::name_key("foxtrot");
        contract.nonces.insert(&key, &1);

    let mut ctx = get_context(accounts(4));
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register_with_sig(
            "foxtrot".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            10_000,
            0, // wrong
            vec![]
        );
    }

    #[test]
    fn test_set_resolved_only_owner_and_updates() {
        let mut contract = init_contract();
        // register
        let mut ctx = get_context(accounts(3));
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register("gamma".to_string());

        // owner updates resolved
        let ctx2 = get_context(accounts(3));
        testing_env!(ctx2.build());
        contract.set_resolved("gamma".to_string(), Some(accounts(4)));
        let rec = contract.get_record("gamma".to_string()).unwrap();
        assert_eq!(rec.resolved, Some(accounts(4)));
    }

    #[test]
    #[should_panic(expected = "Only the owner can manage this name")]
    fn test_set_resolved_restricted() {
        let mut contract = init_contract();
        // register by acc3
        let mut ctx = get_context(accounts(3));
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register("hotel".to_string());
        // attempt by acc4
        let ctx2 = get_context(accounts(4));
        testing_env!(ctx2.build());
        contract.set_resolved("hotel".to_string(), Some(accounts(4)));
    }

    #[test]
    fn test_transfer_name_updates_owners_and_primary_logic() {
        let mut contract = init_contract();
        // acc3 registers name1
        let mut ctx = get_context(accounts(3));
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register("india".to_string());
        assert_eq!(contract.name_of(accounts(3)), Some("india".to_string()));

        // acc4 registers its own primary first so transfer won't override
        let mut ctx4 = get_context(accounts(4));
        ctx4.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx4.build());
        let _ = contract.register("juliet".to_string());
        assert_eq!(contract.name_of(accounts(4)), Some("juliet".to_string()));

        // now acc3 transfers india to acc4
        let ctx3 = get_context(accounts(3));
        testing_env!(ctx3.build());
        contract.transfer_name("india".to_string(), accounts(4));

        // ownership moved
        let rec = contract.get_record("india".to_string()).unwrap();
        assert_eq!(rec.owner, accounts(4));

        // old owner's primary cleared if it matched
        assert_eq!(contract.name_of(accounts(3)), None);

        // new owner's primary remains juliet
        assert_eq!(contract.name_of(accounts(4)), Some("juliet".to_string()));
    }

    #[test]
    fn test_set_primary_name() {
        let mut contract = init_contract();
        let mut ctx = get_context(accounts(3));
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx.build());
        let _ = contract.register("kilo".to_string());
        // change primary to another owned name
    let mut ctx2 = get_context(accounts(3));
        ctx2.attached_deposit(1_000_000_000_000_000_000_000_000);
        testing_env!(ctx2.build());
        let _ = contract.register("lima".to_string());
        // set primary explicitly
    let ctx3 = get_context(accounts(3));
        testing_env!(ctx3.build());
        contract.set_primary_name("lima".to_string());
        assert_eq!(contract.name_of(accounts(3)), Some("lima".to_string()));
    }

    #[test]
    #[should_panic(expected = "Only the owner can call this method")]
    fn test_admin_setters_require_owner() {
        let mut contract = init_contract();
    let ctx = get_context(accounts(3));
        testing_env!(ctx.build());
        contract.set_registration_fee(U128(1));
    }

    #[test]
    fn test_admin_setters_work() {
        let mut contract = init_contract();
    let ctx = get_context(accounts(1)); // owner
        testing_env!(ctx.build());
        contract.set_registration_fee(U128(123));
        contract.set_referrer_bps(250);
    contract.set_treasury(accounts(3));
    let token = accounts(4);
    contract.set_coin_fee(token.clone(), U128(555), true);
    // relayer allowlist controls
    contract.add_relayer(accounts(5));
    contract.set_require_allowlisted_relayer(true);
        // sanity
        assert_eq!(contract.registration_fee, 123);
        assert_eq!(contract.referrer_bps, 250);
    assert_eq!(contract.treasury, accounts(3));
    assert_eq!(contract.coin_fees.get(&token), Some(555));
    assert!(contract.relayers.get(&accounts(5)).unwrap_or(false));
    assert!(contract.require_allowlisted_relayer);
        // disable
    contract.set_coin_fee(token.clone(), U128(0), false);
    assert!(contract.coin_fees.get(&token).is_none());
    }

    #[test]
    fn test_transfer_ownership() {
        let mut contract = init_contract();
    let ctx = get_context(accounts(1));
        testing_env!(ctx.build());
    contract.transfer_ownership(accounts(2));
    assert_eq!(contract.owner, accounts(2));
    }

    #[test]
    #[should_panic(expected = "Relayer not allowlisted")]
    fn test_relayer_allowlist_enforced_meta() {
        let mut contract = init_contract();
        // owner enables gating but does not add the relayer
        let owner_ctx = get_context(accounts(1));
        testing_env!(owner_ctx.build());
        contract.set_require_allowlisted_relayer(true);

        // relayer attempts meta register
    let mut ctx = get_context(accounts(4)); // relayer not allowlisted
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        ctx.block_timestamp(1000);
        testing_env!(ctx.build());
        let _ = contract.register_with_sig(
            "allowlist-test".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            2000,
            0,
            vec![],
        );
    }

    #[test]
    fn test_ft_on_transfer_registers_and_splits() {
    let mut contract = init_contract();
    // enable token fee
    let owner_ctx = get_context(accounts(1));
        testing_env!(owner_ctx.build());
    let token = accounts(5);
    contract.set_coin_fee(token.clone(), U128(1_000), true);

        // call ft_on_transfer from token as predecessor
    let mut ctx = get_context(token.clone());
    ctx.predecessor_account_id(token.clone());
        testing_env!(ctx.build());

        let msg = json!({
            "action": "register",
            "name": "mike",
            "owner": accounts(4),
            "relayer": accounts(5),
            "deadline": 0,
            "nonce": 0
        }).to_string();

    let res = contract.ft_on_transfer(accounts(4), U128(2_000), msg);
    // required fee is 1_000, so refund should be 1_000
    match res { PromiseOrValue::Value(U128(x)) => assert_eq!(x, 1_000), _ => panic!("unexpected") }
        // verify record
        let rec = contract.get_record("mike".to_string()).expect("rec");
        assert_eq!(rec.owner, accounts(4));
        assert_eq!(contract.name_of(accounts(4)), Some("mike".to_string()));

        // nonce for mike increments from 0 -> 1
        let key = NominalRegistry::name_key("mike");
        assert_eq!(contract.nonces.get(&key).unwrap_or(0), 1);

        // Assert FeePaid log contains expected split: total=1000, referrer=accounts(5), ref_amt=30, treasury_amt=970
        let logs = get_logs();
        let found = logs.iter().any(|l| l.contains("FeePaid:") && l.contains("currency=") && l.contains("total=1000") && l.contains(&format!("referrer={}", accounts(5))) && l.contains("ref_amt=30") && l.contains("treasury_amt=970"));
        assert!(found, "Expected FeePaid log with correct FT split not found. Logs: {:?}", logs);
    }

    #[test]
    fn test_native_meta_fee_split_logged() {
        let mut contract = init_contract();
        // Relayer calls meta register with 1_000_000... deposit; with 3% bps for referrer
        let mut ctx = get_context(accounts(4)); // relayer
        ctx.attached_deposit(1_000_000_000_000_000_000_000_000);
        ctx.block_timestamp(1000);
        testing_env!(ctx.build());

        let _ = contract.register_with_sig(
            "zulu".to_string(),
            accounts(5),
            accounts(4),
            U128(1_000_000_000_000_000_000_000_000),
            2000,
            0,
            vec![],
        );

        // With referrer_bps=300, ref_amt is 3% of total deposit
        let logs = get_logs();
        let found = logs.iter().any(|l| l.contains("FeePaid:") && l.contains("currency=native") && l.contains(&format!("payer={}", accounts(4))) && l.contains("total=1000000000000000000000000") && l.contains(&format!("referrer={}", accounts(4))) );
        assert!(found, "Expected FeePaid log for native meta not found. Logs: {:?}", logs);
    }

    #[test]
    #[should_panic(expected = "Token not allowed")]
    fn test_ft_on_transfer_token_must_be_allowed() {
    let mut contract = init_contract();
    let token = accounts(4);
        // predecessor set as token but not enabled
    let mut ctx = get_context(token.clone());
    ctx.predecessor_account_id(token.clone());
        testing_env!(ctx.build());
        let msg = json!({"action": "register", "name": "november"}).to_string();
        let _ = contract.ft_on_transfer(accounts(5), U128(1000), msg);
    }

    #[test]
    #[should_panic(expected = "Insufficient FT amount")]
    fn test_ft_on_transfer_insufficient_amount() {
    let mut contract = init_contract();
    let owner_ctx = get_context(accounts(1));
        testing_env!(owner_ctx.build());
    let token = accounts(5);
    contract.set_coin_fee(token.clone(), U128(1_000), true);

    let mut ctx = get_context(token.clone());
    ctx.predecessor_account_id(token.clone());
        testing_env!(ctx.build());
        let msg = json!({"action": "register", "name": "oscar"}).to_string();
        let _ = contract.ft_on_transfer(accounts(5), U128(999), msg);
    }

    #[test]
    #[should_panic]
    fn test_get_record_invalid_name_panics() {
        let contract = init_contract();
        let _ = contract.get_record("Abc".to_string());
    }
}
