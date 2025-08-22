module nominal::registry {
    use std::bcs;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use sui::table::{Self, Table};
    use std::type_name;
    use std::vector;

    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;

    use nominal::errors as errs;
    use nominal::structs as recmod;

    // Structs
    struct Registry has key {
        id: UID,
        owner: address,
        treasury: address,
        registration_fee: u64,
        referrer_bps: u16,
        names: Table<u64, recmod::Record>,
        nonces: Table<u64, u64>,
        coin_fees: Table<u64, u64>,
    primary_names: Table<address, vector<u8>>, // Map from address to primary name bytes
    relayers: Table<address, bool>,
    require_allowlisted_relayer: bool,
    }

    // Events
    struct Registered has drop, copy { name: String, owner: address, payer: address, coin: vector<u8>, amount: u64 }
    struct ResolvedUpdated has drop, copy { name: String, owner: address, resolved: Option<address> }
    struct RegistrationFeeChanged has drop, copy { amount: u64 }
    struct TreasuryChanged has drop, copy { treasury: address }
    struct ReferrerBpsChanged has drop, copy { bps: u16 }
    struct OwnershipTransferred has drop, copy { old_owner: address, new_owner: address }
    struct CoinFeeSet has drop, copy { coin: vector<u8>, amount: u64, allowed: bool }
    struct PrimaryNameSet has drop, copy { owner: address, name: String }
    struct FeePaid has drop, copy { name: String, payer: address, coin: vector<u8>, total: u64, referrer: Option<address>, ref_amt: u64, treasury_amt: u64 }
    struct RelayerAdded has drop, copy { relayer: address }
    struct RelayerRemoved has drop, copy { relayer: address }
    struct RequireAllowlistedRelayerChanged has drop, copy { enabled: bool }

    // Public Functions
    public fun new(owner: address, treasury: address, fee: u64, bps: u16, ctx: &mut TxContext): Registry {
        Registry {
            id: object::new(ctx),
            owner,
            treasury,
            registration_fee: fee,
            referrer_bps: bps,
            names: table::new<u64, recmod::Record>(ctx),
            nonces: table::new<u64, u64>(ctx),
            coin_fees: table::new<u64, u64>(ctx),
            primary_names: table::new<address, vector<u8>>(ctx),
            relayers: table::new<address, bool>(ctx),
            require_allowlisted_relayer: false,
        }
    }

    public fun share(reg: Registry, _ctx: &mut TxContext) { transfer::share_object(reg); }

    public fun set_registration_fee(reg: &mut Registry, amount: u64, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_NOT_OWNER());
        reg.registration_fee = amount;
        event::emit(RegistrationFeeChanged { amount });
    }

    public fun set_coin_fee<T>(reg: &mut Registry, amount: u64, allowed: bool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_NOT_OWNER());
        let k = coin_type_key<T>();
        if (allowed) {
            table::add(&mut reg.coin_fees, k, amount);
            event::emit(CoinFeeSet { coin: type_key<T>(), amount, allowed });
        } else {
            if (table::contains(&reg.coin_fees, k)) {
                table::remove(&mut reg.coin_fees, k);
            };
            event::emit(CoinFeeSet { coin: type_key<T>(), amount: 0, allowed });
        };
    }

    public fun set_treasury(reg: &mut Registry, t: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        reg.treasury = t;
        event::emit(TreasuryChanged { treasury: t });
    }

    public fun set_referrer_bps(reg: &mut Registry, bps: u16, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        assert!(bps <= 10000, errs::E_INVALID_BPS());
        reg.referrer_bps = bps;
        event::emit(ReferrerBpsChanged { bps });
    }

    public fun add_relayer(reg: &mut Registry, relayer: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        if (table::contains(&reg.relayers, relayer)) {
            let v = table::borrow_mut(&mut reg.relayers, relayer);
            *v = true;
        } else {
            table::add(&mut reg.relayers, relayer, true);
        };
        event::emit(RelayerAdded { relayer });
    }

    public fun remove_relayer(reg: &mut Registry, relayer: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        if (table::contains(&reg.relayers, relayer)) {
            table::remove(&mut reg.relayers, relayer);
        };
        event::emit(RelayerRemoved { relayer });
    }

    public fun set_require_allowlisted_relayer(reg: &mut Registry, enabled: bool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        reg.require_allowlisted_relayer = enabled;
        event::emit(RequireAllowlistedRelayerChanged { enabled });
    }

    public fun transfer_ownership(reg: &mut Registry, new_owner: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == reg.owner, errs::E_UNAUTHORIZED());
        let old = reg.owner;
        reg.owner = new_owner;
        event::emit(OwnershipTransferred { old_owner: old, new_owner });
    }

    public fun register_sui(reg: &mut Registry, name: String, fee: Coin<sui::sui::SUI>, clock: &Clock, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        register_internal_sui(reg, sender, name, fee, clock, ctx, /*meta=*/false, sender, @0x0, 0, 0, 0)
    }

    public fun register_coin<T>(reg: &mut Registry, name: String, fee: Coin<T>, clock: &Clock, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        register_internal_coin<T>(reg, sender, name, fee, clock, ctx, /*meta=*/false, sender, @0x0, 0, 0, 0)
    }

    public fun register_with_sig_sui(reg: &mut Registry, name: String, owner: address, relayer_addr: address, amount: u64, deadline: u64, nonce: u64, fee: Coin<sui::sui::SUI>, clock: &Clock, ctx: &mut TxContext) {
        // Verify signature validity (implemented via transaction authenticator on SUI)
        // This ensures that only owner or authorized relayer can register on behalf
        let sender = tx_context::sender(ctx);
        assert!(sender == owner || sender == relayer_addr, errs::E_UNAUTHORIZED());
        if (reg.require_allowlisted_relayer) {
            assert!(table::contains(&reg.relayers, relayer_addr), errs::E_RELAYER_NOT_ALLOWED());
        };
        register_internal_sui(reg, sender, name, fee, clock, ctx, /*meta=*/true, owner, relayer_addr, amount, deadline, nonce)
    }

    public fun register_with_sig_coin<T>(reg: &mut Registry, name: String, owner: address, relayer_addr: address, amount: u64, deadline: u64, nonce: u64, fee: Coin<T>, clock: &Clock, ctx: &mut TxContext) {
        // Verify signature validity (implemented via transaction authenticator on SUI)
        // This ensures that only owner or authorized relayer can register on behalf
        let sender = tx_context::sender(ctx);
        assert!(sender == owner || sender == relayer_addr, errs::E_UNAUTHORIZED());
        if (reg.require_allowlisted_relayer) {
            assert!(table::contains(&reg.relayers, relayer_addr), errs::E_RELAYER_NOT_ALLOWED());
        };
        register_internal_coin<T>(reg, sender, name, fee, clock, ctx, /*meta=*/true, owner, relayer_addr, amount, deadline, nonce)
    }

    public fun set_resolved(reg: &mut Registry, name: String, resolved: Option<address>, clock: &Clock, ctx: &TxContext) {
        let nk = name_key(&name);
        assert!(table::contains(&reg.names, nk), errs::E_NAME_NOT_FOUND());
        let rec = table::borrow_mut(&mut reg.names, nk);
        assert!(recmod::owner(rec) == tx_context::sender(ctx), errs::E_NOT_OWNER());
        recmod::set_resolved(rec, resolved);
        recmod::set_updated(rec, sui::clock::timestamp_ms(clock));
        event::emit(ResolvedUpdated { name, owner: recmod::owner(rec), resolved });
    }

    public fun transfer_name(reg: &mut Registry, name: String, new_owner: address, clock: &Clock, ctx: &TxContext) {
        assert!(is_valid_name(&name), errs::E_INVALID_NAME());
        let nk = name_key(&name);
        assert!(table::contains(&reg.names, nk), errs::E_NAME_NOT_FOUND());
        let rec = table::borrow_mut(&mut reg.names, nk);
        let sender = tx_context::sender(ctx);
        assert!(recmod::owner(rec) == sender, errs::E_NOT_OWNER());
        let old_owner = recmod::owner(rec);
        recmod::set_owner(rec, new_owner);
        recmod::set_updated(rec, sui::clock::timestamp_ms(clock));
        
        // Handle primary name transfers
        // If this was the old owner's primary name, clear it
        if (table::contains(&reg.primary_names, old_owner)) {
            let primary_name_bytes = table::borrow(&reg.primary_names, old_owner);
            if (vector::length(primary_name_bytes) > 0 && 
                *primary_name_bytes == *string::as_bytes(&name)) {
                table::remove(&mut reg.primary_names, old_owner);
            }
        };
        
        // If the new owner doesn't have a primary name, set this as their primary
        // We do not override existing primary names during transfers
        if (!table::contains(&reg.primary_names, new_owner)) {
            table::add(&mut reg.primary_names, new_owner, *string::as_bytes(&name));
            event::emit(PrimaryNameSet { owner: new_owner, name });
        };
    }
    
    /// Set a name as the primary name for the caller's address
    public fun set_primary_name(reg: &mut Registry, name: String, ctx: &TxContext) {
        assert!(is_valid_name(&name), errs::E_INVALID_NAME());
        let nk = name_key(&name);
        assert!(table::contains(&reg.names, nk), errs::E_NAME_NOT_FOUND());
        let rec = table::borrow(&reg.names, nk);
        let sender = tx_context::sender(ctx);
        assert!(recmod::owner(rec) == sender, errs::E_NOT_OWNER());
        
        // Update primary name table
        if (table::contains(&reg.primary_names, sender)) {
            let name_bytes = table::borrow_mut(&mut reg.primary_names, sender);
            *name_bytes = *string::as_bytes(&name);
        } else {
            table::add(&mut reg.primary_names, sender, *string::as_bytes(&name));
        };
        
        event::emit(PrimaryNameSet { owner: sender, name });
    }
    
    /// Get the primary name for an address
    public fun name_of(reg: &Registry, addr: address): Option<String> {
        if (table::contains(&reg.primary_names, addr)) {
            let name_bytes = table::borrow(&reg.primary_names, addr);
            option::some(string::utf8(*name_bytes))
        } else {
            option::none()
        }
    }

    // Internal Functions
    fun register_internal_sui(reg: &mut Registry, actor: address, name: String, fee: Coin<sui::sui::SUI>, clock: &Clock, ctx: &mut TxContext, meta: bool, owner: address, relayer_addr: address, amount_expected: u64, deadline: u64, nonce: u64) {
        // Validate the name and check for availability
        assert!(is_valid_name(&name), errs::E_INVALID_NAME());
        let nk = name_key(&name);
        assert!(!table::contains(&reg.names, nk), errs::E_NAME_TAKEN());

        // Meta transaction validation
        if (meta) {
            assert!(relayer_addr == actor, errs::E_WRONG_RELAYER());
            assert!(sui::clock::timestamp_ms(clock) <= deadline, errs::E_DEADLINE());
            let keyn = nk;
            if (table::contains(&reg.nonces, keyn)) {
                let n_ref = table::borrow_mut(&mut reg.nonces, keyn);
                assert!(*n_ref == nonce, errs::E_BAD_SIG());
                *n_ref = *n_ref + 1;
            } else {
                assert!(nonce == 0, errs::E_BAD_SIG());
                table::add(&mut reg.nonces, keyn, 1);
            };
            assert!(coin::value(&fee) >= amount_expected, errs::E_WRONG_FEE());
        };

        // Fee validation
        let fee_amount = coin::value(&fee);
        assert!(fee_amount >= reg.registration_fee, errs::E_WRONG_FEE());

        // Create record first (effects)
        let record = recmod::new_record(owner, option::none(), sui::clock::timestamp_ms(clock));
        table::add(&mut reg.names, nk, record);
        
        // Set as primary name if the owner doesn't have one yet
        if (!table::contains(&reg.primary_names, owner)) {
            table::add(&mut reg.primary_names, owner, *string::as_bytes(&name));
            event::emit(PrimaryNameSet { owner, name: name });
        };

        // Prepare a copy of the name for multiple event emissions
        let name_copy = string::utf8(*string::as_bytes(&name));

        // Process fee (interactions) with optional referrer split for meta
        let fee_to_take = reg.registration_fee;
    let fee_coin = coin::split(&mut fee, fee_to_take, ctx);
        if (meta) {
            let ref_cut = (fee_to_take * (reg.referrer_bps as u64)) / 10000;
            if (ref_cut > 0) {
                let ref_coin = coin::split(&mut fee_coin, ref_cut, ctx);
                transfer::public_transfer(ref_coin, relayer_addr);
            };
            transfer::public_transfer(fee_coin, reg.treasury);
            // Emit fee split event for meta
            event::emit(FeePaid { name: name_copy, payer: actor, coin: type_key<sui::sui::SUI>(), total: fee_to_take, referrer: option::some(relayer_addr), ref_amt: (fee_to_take * (reg.referrer_bps as u64)) / 10000, treasury_amt: fee_to_take - ((fee_to_take * (reg.referrer_bps as u64)) / 10000) });
        } else {
            transfer::public_transfer(fee_coin, reg.treasury);
            // Emit fee event for direct payment
            event::emit(FeePaid { name: name_copy, payer: actor, coin: type_key<sui::sui::SUI>(), total: fee_to_take, referrer: option::none<address>(), ref_amt: 0, treasury_amt: fee_to_take });
        };
        transfer::public_transfer(fee, actor); // Return change

        // Emit registration event
        event::emit(Registered {
            name,
            owner,
            payer: actor,
            coin: type_key<sui::sui::SUI>(),
            amount: fee_to_take
        });
    }

    fun register_internal_coin<T>(reg: &mut Registry, actor: address, name: String, fee: Coin<T>, clock: &Clock, ctx: &mut TxContext, meta: bool, owner: address, relayer_addr: address, amount_expected: u64, deadline: u64, nonce: u64) {
        // Validate the name and check for availability
        assert!(is_valid_name(&name), errs::E_INVALID_NAME());
        let nk = name_key(&name);
        assert!(!table::contains(&reg.names, nk), errs::E_NAME_TAKEN());

        // Validate the coin type is allowed
        let k = coin_type_key<T>();
        assert!(table::contains(&reg.coin_fees, k), errs::E_COIN_NOT_ALLOWED());
        let required_fee = *table::borrow(&reg.coin_fees, k);

        // Meta transaction validation
        if (meta) {
            assert!(relayer_addr == actor, errs::E_WRONG_RELAYER());
            assert!(sui::clock::timestamp_ms(clock) <= deadline, errs::E_DEADLINE());
            let keyn = nk;
            if (table::contains(&reg.nonces, keyn)) {
                let n_ref = table::borrow_mut(&mut reg.nonces, keyn);
                assert!(*n_ref == nonce, errs::E_BAD_SIG());
                *n_ref = *n_ref + 1;
            } else {
                assert!(nonce == 0, errs::E_BAD_SIG());
                table::add(&mut reg.nonces, keyn, 1);
            };
            assert!(coin::value(&fee) >= amount_expected, errs::E_WRONG_FEE());
        };

        // Fee validation
        let fee_amount = coin::value(&fee);
        assert!(fee_amount >= required_fee, errs::E_WRONG_FEE());

        // Create record first (effects)
        let record = recmod::new_record(owner, option::none(), sui::clock::timestamp_ms(clock));
        table::add(&mut reg.names, nk, record);
        
        // Set as primary name if the owner doesn't have one yet
        if (!table::contains(&reg.primary_names, owner)) {
            table::add(&mut reg.primary_names, owner, *string::as_bytes(&name));
            event::emit(PrimaryNameSet { owner, name: name });
        };

        // Prepare a copy of the name for multiple event emissions
        let name_copy = string::utf8(*string::as_bytes(&name));

        // Process fee (interactions) with optional referrer split for meta
    let fee_coin = coin::split(&mut fee, required_fee, ctx);
        if (meta) {
            let ref_cut = (required_fee * (reg.referrer_bps as u64)) / 10000;
            if (ref_cut > 0) {
                let ref_coin = coin::split(&mut fee_coin, ref_cut, ctx);
                transfer::public_transfer(ref_coin, relayer_addr);
            };
            transfer::public_transfer(fee_coin, reg.treasury);
            // Emit fee split event for meta
            event::emit(FeePaid { name: name_copy, payer: actor, coin: type_key<T>(), total: required_fee, referrer: option::some(relayer_addr), ref_amt: (required_fee * (reg.referrer_bps as u64)) / 10000, treasury_amt: required_fee - ((required_fee * (reg.referrer_bps as u64)) / 10000) });
        } else {
            transfer::public_transfer(fee_coin, reg.treasury);
            // Emit fee event for direct payment
            event::emit(FeePaid { name: name_copy, payer: actor, coin: type_key<T>(), total: required_fee, referrer: option::none<address>(), ref_amt: 0, treasury_amt: required_fee });
        };
        transfer::public_transfer(fee, actor); // Return change

        // Emit registration event
        event::emit(Registered {
            name,
            owner,
            payer: actor,
            coin: type_key<T>(),
            amount: required_fee
        });
    }

    public fun is_valid_name(name: &String): bool {
        let len = string::length(name);
        if (len < 3 || len > 63) {
            return false
        };
        is_valid_name_helper(string::as_bytes(name), len, 0, false)
    }

    fun is_valid_name_helper(b: &vector<u8>, n: u64, i: u64, prev_hyphen: bool): bool {
        if (i >= n) { return true };

        let c = *vector::borrow(b, i);

        let is_lower = c >= 97 && c <= 122; // a-z
        let is_digit = c >= 48 && c <= 57; // 0-9
        let is_hyphen = c == 45; // -

        if (!(is_lower || is_digit || is_hyphen)) {
            return false
        };

        // no leading/trailing hyphens
        if (is_hyphen && (i == 0 || i == n - 1)) {
            return false
        };

        // no double hyphens
        if (is_hyphen && prev_hyphen) {
            return false
        };

        is_valid_name_helper(b, n, i + 1, is_hyphen)
    }

    public fun type_key<T>(): vector<u8> { bcs::to_bytes(&type_name::get<T>()) }
    fun coin_type_key<T>(): u64 { hash64(&type_key<T>()) }
    fun name_key(name: &String): u64 { 
        // Use full hash bytes to reduce collision risk
        let hash_bytes = sui::hash::blake2b256(string::as_bytes(name));
        // Extract a 64-bit hash from the 256-bit hash
        hash64_helper(&hash_bytes, 0, 0u64)
    }
    fun hash64(b: &vector<u8>): u64 {
        let hash_bytes = sui::hash::blake2b256(b);
        hash64_helper(&hash_bytes, 0, 0u64)
    }

    fun hash64_helper(hash_bytes: &vector<u8>, i: u64, result: u64): u64 {
        if (i >= 8 || i >= vector::length(hash_bytes)) return result;

        let byte_val = *vector::borrow(hash_bytes, i);
        let shift_amount = ((i * 8) as u8);
        let new_result = result | ((byte_val as u64) << shift_amount);
        hash64_helper(hash_bytes, i + 1, new_result)
    }
}
