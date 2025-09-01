use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::collections::{LookupMap, UnorderedMap, UnorderedSet};
use near_sdk::json_types::{U128, U64};
use near_sdk::serde::{Deserialize, Serialize};
use near_sdk::{
    env, near_bindgen, require, AccountId, PanicOnDefault, Promise,
    Gas, NearToken, BorshStorageKey, ext_contract, PublicKey, PromiseResult,
};
use std::str::FromStr;

const GAS_FOR_FT_TRANSFER: Gas = Gas::from_tgas(10);

#[ext_contract(ext_ft)]
trait FungibleTokenCore {
    fn ft_transfer_from(&mut self, sender_id: AccountId, receiver_id: AccountId, amount: U128, memo: Option<String>);
}

#[ext_contract(ext_self)]
trait SelfContract {
    fn ft_transfer_callback(
        &mut self,
        name: String,
        owner: AccountId,
        token: AccountId,
        token_fee: u128,
        timestamp: u64,
    ) -> bool;
}

#[derive(BorshSerialize, BorshStorageKey)]
enum StorageKey {
    Records,
    PrimaryNames,
    CoinFees,
    Relayers,
    Nonces,
    AuthorizedKeys,
}

#[derive(BorshDeserialize, BorshSerialize, Serialize, Deserialize)]
#[serde(crate = "near_sdk::serde")]
pub struct Record {
    pub owner: AccountId,
    pub resolved: AccountId,
    pub updated_at: U64,
}

#[derive(BorshDeserialize, BorshSerialize, Serialize, Deserialize)]
#[serde(crate = "near_sdk::serde")]
pub struct RegisterWithSigParams {
    pub name: String,
    pub owner: AccountId,
    pub relayer: AccountId,
    pub currency: Option<AccountId>,
    pub amount: U128,
    pub deadline: U64,
    pub nonce: U64,
}

#[near_bindgen]
#[derive(BorshDeserialize, BorshSerialize, PanicOnDefault)]
pub struct NameRegistry {
    pub owner: AccountId,
    pub treasury: AccountId,
    pub registration_fee: u128,
    pub referrer_bps: u16,
    pub require_relayer_allowlist: bool,
    
    pub records: UnorderedMap<String, Record>,
    pub primary_names: LookupMap<AccountId, String>,
    pub coin_fees: LookupMap<AccountId, u128>,
    pub relayers: UnorderedSet<AccountId>,
    pub nonces: LookupMap<String, u64>,
    pub authorized_keys: LookupMap<String, bool>,
}

#[near_bindgen]
impl NameRegistry {
    #[init]
    pub fn new(owner: AccountId, treasury: AccountId, registration_fee: U128) -> Self {
        Self {
            owner,
            treasury,
            registration_fee: registration_fee.0,
            referrer_bps: 500,
            require_relayer_allowlist: false,
            records: UnorderedMap::new(StorageKey::Records),
            primary_names: LookupMap::new(StorageKey::PrimaryNames),
            coin_fees: LookupMap::new(StorageKey::CoinFees),
            relayers: UnorderedSet::new(StorageKey::Relayers),
            nonces: LookupMap::new(StorageKey::Nonces),
            authorized_keys: LookupMap::new(StorageKey::AuthorizedKeys),
        }
    }

    #[payable]
    pub fn register(&mut self, name: String) {
        let owner = env::predecessor_account_id();
        let amount = env::attached_deposit();
        
        require!(self.is_valid_name(&name), "Invalid name");
        require!(!self.records.get(&name).is_some(), "Name already taken");
        require!(amount.as_yoctonear() == self.registration_fee, "Exact fee required");
        
        let timestamp = env::block_timestamp_ms();
        self.register_record_and_primary(&name, &owner, timestamp);
        
        Promise::new(self.treasury.clone()).transfer(NearToken::from_yoctonear(amount.as_yoctonear()));
        
        self.emit_registered(&name, &owner);
        self.emit_fee_paid(&name, &owner, None, amount.as_yoctonear(), None);
    }

    #[payable]
    pub fn register_with_ft(&mut self, name: String, token: AccountId) {
        require!(env::attached_deposit() == NearToken::from_near(0), "No NEAR tokens allowed");
        let owner = env::predecessor_account_id();
        
        require!(self.is_valid_name(&name), "Invalid name");
        require!(!self.records.get(&name).is_some(), "Name already taken");
        
        let token_fee = self.coin_fees.get(&token).expect("Token not enabled");
        let timestamp = env::block_timestamp_ms();
        
        // First attempt the token transfer with callback
        let promise = ext_ft::ext(token.clone())
            .with_attached_deposit(NearToken::from_yoctonear(1))
            .with_static_gas(GAS_FOR_FT_TRANSFER)
            .ft_transfer_from(owner.clone(), self.treasury.clone(), U128(token_fee), Some(format!("Nominal registration fee for {}", name)));
            
        // Only register if transfer succeeds
        promise.then(
            ext_self::ext(env::current_account_id())
                .with_static_gas(Gas::from_tgas(5))
                .ft_transfer_callback(name.clone(), owner.clone(), token.clone(), token_fee, timestamp)
        );
    }
    
    #[private]
    pub fn ft_transfer_callback(
        &mut self,
        name: String,
        owner: AccountId,
        token: AccountId,
        token_fee: u128,
        timestamp: u64,
    ) -> bool {
        let transfer_success = matches!(env::promise_result(0), PromiseResult::Successful(_));
        
        if transfer_success {
            // Only now register the name after successful payment
            self.register_record_and_primary(&name, &owner, timestamp);
            self.emit_registered(&name, &owner);
            self.emit_fee_paid(&name, &owner, Some(&token), token_fee, None);
            true
        } else {
            // Payment failed - emit error event
            env::panic_str("Token transfer failed - registration cancelled");
        }
    }

    #[payable]
    pub fn register_with_sig(&mut self, params: RegisterWithSigParams, signature: String) {
        let relayer = env::predecessor_account_id();
        let current_time = env::block_timestamp_ms();
        
        require!(current_time <= params.deadline.0, "Deadline expired");
        require!(relayer == params.relayer, "Invalid relayer");
        if self.require_relayer_allowlist {
            require!(self.relayers.contains(&params.relayer), "Relayer not allowed");
        }
        require!(self.is_valid_name(&params.name), "Invalid name");
        require!(!self.records.get(&params.name).is_some(), "Name already taken");
        require!(params.owner.to_string() != "", "Invalid owner");

        self.verify_signature(&params, &signature);
        
        let timestamp = env::block_timestamp_ms();
        
        if params.currency.is_none() {
            let amount = env::attached_deposit();
            require!(amount.as_yoctonear() == self.registration_fee, "Exact fee required");
            
            self.register_record_and_primary(&params.name, &params.owner, timestamp);
            
            let ref_share = (amount.as_yoctonear() * self.referrer_bps as u128) / 10_000;
            let treasury_share = amount.as_yoctonear() - ref_share;
            
            self.emit_registered(&params.name, &params.owner);
            self.emit_fee_paid(&params.name, &relayer, None, amount.as_yoctonear(), Some(&relayer));
            
            if treasury_share > 0 {
                Promise::new(self.treasury.clone()).transfer(NearToken::from_yoctonear(treasury_share));
            }
            if ref_share > 0 {
                Promise::new(relayer.clone()).transfer(NearToken::from_yoctonear(ref_share));
            }
            
        } else {
            require!(env::attached_deposit() == NearToken::from_near(0), "No NEAR tokens allowed");
            let token = params.currency.unwrap();
            let token_fee = self.coin_fees.get(&token).expect("Token not enabled");
            require!(params.amount.0 == token_fee, "Exact token fee required");
            
            self.register_record_and_primary(&params.name, &params.owner, timestamp);
            
            let ref_share = (token_fee * self.referrer_bps as u128) / 10_000;
            let treasury_share = token_fee - ref_share;
            
            self.emit_registered(&params.name, &params.owner);
            self.emit_fee_paid(&params.name, &relayer, Some(&token), token_fee, Some(&relayer));
            
            if treasury_share > 0 {
                ext_ft::ext(token.clone())
                    .with_attached_deposit(NearToken::from_yoctonear(1))
                    .with_static_gas(GAS_FOR_FT_TRANSFER)
                    .ft_transfer_from(relayer.clone(), self.treasury.clone(), U128(treasury_share), Some(format!("Nominal treasury fee for {}", params.name)));
            }
            if ref_share > 0 {
                ext_ft::ext(token.clone())
                    .with_attached_deposit(NearToken::from_yoctonear(1))
                    .with_static_gas(GAS_FOR_FT_TRANSFER)
                    .ft_transfer_from(relayer.clone(), relayer.clone(), U128(ref_share), Some(format!("Nominal referrer reward for {}", params.name)));
            }
        }
    }

    fn register_record_and_primary(&mut self, name: &str, owner: &AccountId, timestamp: u64) {
        let record = Record {
            owner: owner.clone(),
            resolved: owner.clone(),
            updated_at: U64(timestamp),
        };
        self.records.insert(&name.to_string(), &record);
        
        if self.primary_names.get(owner).is_none() {
            self.primary_names.insert(owner, &name.to_string());
            self.emit_primary_name_set(owner, name);
        }
    }

    fn is_valid_name(&self, name: &str) -> bool {
        !name.is_empty() && name.len() <= 64 && name.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    }

    fn assert_owner(&self) {
        require!(env::predecessor_account_id() == self.owner, "Only owner");
    }

    fn verify_signature(&mut self, params: &RegisterWithSigParams, signature: &str) {
        let current_nonce = self.nonces.get(&params.name).unwrap_or(0);
        require!(params.nonce.0 == current_nonce, "Invalid nonce");
        
        let message = self.create_registration_message(params);
      
        require!(!signature.is_empty(), "Empty signature");
       
        let parts: Vec<&str> = signature.split(':').collect();
        require!(parts.len() == 2, "Invalid signature format - expected 'signature:public_key'");
        

        let signature_bytes = bs58::decode(parts[0])
            .into_vec()
            .expect("Invalid signature base58");
        require!(signature_bytes.len() == 64, "Invalid ED25519 signature length");
        
     
        let public_key = PublicKey::from_str(parts[1])
            .expect("Invalid public key format");
        
        let message_hash = env::sha256(&message);
        
    
        let mut sig_array = [0u8; 64];
        sig_array.copy_from_slice(&signature_bytes);
        
        // For now, assume ED25519 signatures only (most common in NEAR)
        let key_data = public_key.clone().into_bytes();
        require!(key_data.len() >= 32, "Invalid public key length");
        
        // Extract the actual key bytes
        let mut key_array = [0u8; 32];
        key_array.copy_from_slice(&key_data[1..33]);
        
        // Verify ED25519 signature using NEAR's crypto functions
        let is_valid = env::ed25519_verify(&sig_array, &message_hash, &key_array);
        
        require!(is_valid, "Invalid signature");
        
        self.verify_key_belongs_to_account(&params.owner, &public_key);
        
        self.nonces.insert(&params.name, &(current_nonce + 1));
    }
    
    fn create_registration_message(&self, params: &RegisterWithSigParams) -> Vec<u8> {
        let mut message = Vec::new();
        message.extend_from_slice(env::current_account_id().as_bytes());
        message.extend_from_slice(params.name.as_bytes());
        message.extend_from_slice(params.owner.as_bytes());
        message.extend_from_slice(params.relayer.as_bytes());
        
        if let Some(currency) = &params.currency {
            message.extend_from_slice(currency.as_bytes());
        }
        
        message.extend_from_slice(&params.amount.0.to_le_bytes());
        message.extend_from_slice(&params.deadline.0.to_le_bytes());
        message.extend_from_slice(&params.nonce.0.to_le_bytes());
        
        env::sha256(&message)
    }
    
    fn verify_key_belongs_to_account(&self, account: &AccountId, public_key: &PublicKey) {
        let account_str = account.to_string();
        
        if account_str.len() == 64 && account_str.chars().all(|c| c.is_ascii_hexdigit()) {
            let expected_account = hex::encode(&public_key.clone().into_bytes()[1..33]);
            require!(account_str == expected_account, "Public key does not match implicit account");
            return;
        }
        
        let key_bytes = public_key.clone().into_bytes();
        let key_b58 = bs58::encode(&key_bytes).into_string();
        
        if let Some(_) = self.authorized_keys.get(&format!("{}:{}", account, key_b58)) {
            return; // Key is authorized
        }
        
        require!(false, "Public key not authorized for this account - call authorize_key first");
    }
    
    pub fn authorize_key(&mut self, public_key: PublicKey) {
        let caller = env::predecessor_account_id();
        let key_bytes = public_key.into_bytes();
        let key_b58 = bs58::encode(&key_bytes).into_string();
        let auth_key = format!("{}:{}", caller, key_b58);
        
        self.authorized_keys.insert(&auth_key, &true);
        env::log_str(&format!("Key authorized for account {}: {}", caller, key_b58));
    }
    
    pub fn revoke_key(&mut self, public_key: PublicKey) {
        let caller = env::predecessor_account_id();
        let key_bytes = public_key.into_bytes();
        let key_b58 = bs58::encode(&key_bytes).into_string();
        let auth_key = format!("{}:{}", caller, key_b58);
        
        self.authorized_keys.remove(&auth_key);
        env::log_str(&format!("Key revoked for account {}: {}", caller, key_b58));
    }

    pub fn set_registration_fee(&mut self, amount: U128) {
        self.assert_owner();
        self.registration_fee = amount.0;
    }

    pub fn set_treasury(&mut self, treasury: AccountId) {
        self.assert_owner();
        self.treasury = treasury;
    }

    pub fn set_referrer_bps(&mut self, bps: u16) {
        self.assert_owner();
        require!(bps <= 10000, "BPS must be <= 10000");
        self.referrer_bps = bps;
    }

    pub fn set_relayer(&mut self, relayer: AccountId, allowed: bool) {
        self.assert_owner();
        if allowed {
            self.relayers.insert(&relayer);
        } else {
            self.relayers.remove(&relayer);
        }
    }

    pub fn set_coin_fee(&mut self, coin: AccountId, fee: U128) -> U128 {
        self.assert_owner();
        self.coin_fees.insert(&coin, &fee.0);
        env::log_str(&format!("Token fee set: {} = {}", coin, fee.0));
        fee
    }

    pub fn set_require_relayer_allowlist(&mut self, required: bool) {
        self.assert_owner();
        self.require_relayer_allowlist = required;
    }

    pub fn get_record(&self, name: String) -> Option<Record> {
        self.records.get(&name)
    }

    pub fn get_primary_name(&self, account: AccountId) -> Option<String> {
        self.primary_names.get(&account)
    }

    pub fn get_coin_fee(&self, coin: AccountId) -> Option<U128> {
        self.coin_fees.get(&coin).map(U128)
    }

    pub fn is_relayer_allowed(&self, relayer: AccountId) -> bool {
        !self.require_relayer_allowlist || self.relayers.contains(&relayer)
    }

    pub fn get_nonce(&self, name: String) -> U64 {
        U64(self.nonces.get(&name).unwrap_or(0))
    }
    
    pub fn get_authorized_keys(&self, _account: AccountId) -> Vec<String> {
        // TO Do
        // This is a simplified implementation for the new storage pattern
        // In mainnet, we  want to iterate through all keys with the account prefix
        vec![] // Simplified for now
    }

    pub fn get_config(&self) -> serde_json::Value {
        serde_json::json!({
            "owner": self.owner,
            "treasury": self.treasury,
            "registration_fee": U128(self.registration_fee),
            "referrer_bps": self.referrer_bps,
            "require_relayer_allowlist": self.require_relayer_allowlist
        })
    }

    fn emit_registered(&self, name: &str, owner: &AccountId) {
        env::log_str(&format!("EVENT_JSON:{{\"event\":\"Registered\",\"name\":\"{}\",\"owner\":\"{}\"}}", name, owner));
    }

    fn emit_primary_name_set(&self, owner: &AccountId, name: &str) {
        env::log_str(&format!("EVENT_JSON:{{\"event\":\"PrimaryNameSet\",\"owner\":\"{}\",\"name\":\"{}\"}}", owner, name));
    }

    fn emit_fee_paid(&self, name: &str, payer: &AccountId, currency: Option<&AccountId>, amount: u128, referrer: Option<&AccountId>) {
        let currency_str = currency.map(|c| c.to_string()).unwrap_or_else(|| "NEAR".to_string());
        let referrer_str = referrer.map(|r| r.to_string()).unwrap_or_else(|| "null".to_string());
        env::log_str(&format!("EVENT_JSON:{{\"event\":\"FeePaid\",\"name\":\"{}\",\"payer\":\"{}\",\"currency\":\"{}\",\"amount\":\"{}\",\"referrer\":\"{}\"}}", 
            name, payer, currency_str, amount, referrer_str));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::{accounts, VMContextBuilder};
    use near_sdk::{testing_env, AccountId};

    fn get_context(predecessor: AccountId) -> VMContextBuilder {
        let mut builder = VMContextBuilder::new();
        builder.predecessor_account_id(predecessor);
        builder
    }

    #[test]
    fn test_contract_initialization() {
        let owner: AccountId = accounts(0);
        let treasury: AccountId = accounts(1);
        let registration_fee = U128(100_000_000_000_000_000_000_000); // 0.1 NEAR
        
        testing_env!(get_context(owner.clone()).build());
        
        // Test contract creation
        let contract = NameRegistry::new(owner.clone(), treasury.clone(), registration_fee);
        
        // Verify initialization
        assert_eq!(contract.owner, owner);
        assert_eq!(contract.treasury, treasury);
        assert_eq!(contract.registration_fee, registration_fee.0);
        assert_eq!(contract.referrer_bps, 500);
        assert_eq!(contract.require_relayer_allowlist, false);
        
        println!(" Contract initialization test passed!");
    }

    #[test]
    fn test_get_nonce() {
        let owner: AccountId = accounts(0);
        let treasury: AccountId = accounts(1);
        let registration_fee = U128(100_000_000_000_000_000_000_000);
        
        testing_env!(get_context(owner.clone()).build());
        
        let contract = NameRegistry::new(owner, treasury, registration_fee);
        
        // Test nonce for non-existent name
        let nonce = contract.get_nonce("test".to_string());
        assert_eq!(nonce.0, 0);
        
        println!(" Get nonce test passed!");
    }
}
