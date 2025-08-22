#[test_only]
module nominal::registry_tests {
    use std::string;
    use std::option;
    use sui::coin;
    use sui::clock::{Self, Clock};
    use sui::test_scenario as ts;
    use sui::tx_context::{TxContext};
    use sui::event;
    use std::vector;

    // Import the module
    use nominal::registry::{Self as reg, Registry, RelayerAdded, RequireAllowlistedRelayerChanged, FeePaid};

    struct TestCoin has drop {}

    #[test_only]
    fun clock_for_testing(ctx: &mut TxContext): Clock {
        clock::create_for_testing(ctx)
    }

    #[test]
    fun test_register_with_sig_sui_referrer_split() {
        let admin = @0xA1;
        let alice = @0xB1; // owner
        let relayer = @0xD1; // relayer/sender
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry (fee=1000, bps=300 => 3%)
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Relayer performs meta registration for Alice
        ts::next_tx(scenario, relayer);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            // Mint 1500 SUI to pay 1000 fee, leaving 500 change
            let fee = coin::mint_for_testing<sui::sui::SUI>(1500, ctx);
            // deadline sufficiently in the future
            reg::register_with_sig_sui(&mut r, string::utf8(b"meta-alice"), alice, relayer, 1500, 1000, 0, fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Inspect balances transferred to treasury and relayer
        ts::next_tx(scenario, admin);
        {
            // Treasury should receive 1000 - 3% = 970
            let tcoin = ts::take_from_address<coin::Coin<sui::sui::SUI>>(scenario, treasury);
            assert!(coin::value(&tcoin) == 970, 100);
            let _ = coin::burn_for_testing<sui::sui::SUI>(tcoin);

            // Relayer receives referrer cut (30) and change (500) in two separate coins
            let c1 = ts::take_from_address<coin::Coin<sui::sui::SUI>>(scenario, relayer);
            let c2 = ts::take_from_address<coin::Coin<sui::sui::SUI>>(scenario, relayer);
            let v1 = coin::value(&c1);
            let v2 = coin::value(&c2);
            let min = if (v1 < v2) { v1 } else { v2 };
            let max = if (v1 < v2) { v2 } else { v1 };
            assert!(min == 30, 101);
            assert!(max == 500, 102);
            let _ = coin::burn_for_testing<sui::sui::SUI>(c1);
            let _ = coin::burn_for_testing<sui::sui::SUI>(c2);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_register_with_sig_coin_referrer_split() {
        let admin = @0xA1;
        let alice = @0xB1; // owner
        let relayer = @0xD1; // relayer/sender
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry (bps=300)
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Allow TestCoin with required fee 50_000
        ts::next_tx(scenario, admin);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::set_coin_fee<TestCoin>(&mut r, 50_000, true, ts::ctx(scenario));
            ts::return_shared(r);
        };

        // Relayer performs meta registration for Alice paying with TestCoin
        ts::next_tx(scenario, relayer);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            // Mint 60_000 TestCoin to pay 50_000 required, leaving 10_000 change
            let fee = coin::mint_for_testing<TestCoin>(60_000, ctx);
            reg::register_with_sig_coin<TestCoin>(&mut r, string::utf8(b"meta-alice-coin"), alice, relayer, 60_000, 1000, 0, fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Inspect balances transferred to treasury and relayer
        ts::next_tx(scenario, admin);
        {
            // Treasury should receive 50_000 - 3% = 48_500
            let tcoin = ts::take_from_address<coin::Coin<TestCoin>>(scenario, treasury);
            assert!(coin::value(&tcoin) == 48_500, 200);
            let _ = coin::burn_for_testing<TestCoin>(tcoin);

            // Relayer receives referrer cut (1_500) and change (10_000)
            let c1 = ts::take_from_address<coin::Coin<TestCoin>>(scenario, relayer);
            let c2 = ts::take_from_address<coin::Coin<TestCoin>>(scenario, relayer);
            let v1 = coin::value(&c1);
            let v2 = coin::value(&c2);
            let min = if (v1 < v2) { v1 } else { v2 };
            let max = if (v1 < v2) { v2 } else { v1 };
            assert!(min == 1_500, 201);
            assert!(max == 10_000, 202);
            let _ = coin::burn_for_testing<TestCoin>(c1);
            let _ = coin::burn_for_testing<TestCoin>(c2);
        };

        ts::end(scenario_val);
    }

    // Helper to destroy unused clock objects
    fun destroy_clock(clock: Clock) {
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_name_validation_cases() {
        // Valid names
        assert!(reg::is_valid_name(&string::utf8(b"abc")), 1);
        assert!(reg::is_valid_name(&string::utf8(b"a1b-2c")), 2);
        assert!(reg::is_valid_name(&string::utf8(b"nominal-protocol1")), 3);
        // Invalid: too short/long, uppercase, spaces, leading/trailing/double hyphen
        assert!(!reg::is_valid_name(&string::utf8(b"ab")), 10);
        assert!(!reg::is_valid_name(&string::utf8(b"Abc")), 11);
        assert!(!reg::is_valid_name(&string::utf8(b"hello world")), 12);
        assert!(!reg::is_valid_name(&string::utf8(b"-bad")), 13);
        assert!(!reg::is_valid_name(&string::utf8(b"bad-")), 14);
        assert!(!reg::is_valid_name(&string::utf8(b"bad--bad")), 15);
    }

    #[test]
    fun test_admin_can_change_fee() {
        let admin = @0xA1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry in the first tx
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Test admin can change fee
        ts::next_tx(scenario, admin);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::set_registration_fee(&mut r, 2000, ts::ctx(scenario));
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    #[expected_failure(abort_code = 11, location = nominal::registry)]
    fun test_user_cannot_change_fee() {
        let admin = @0xA1;
        let user = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry in the first tx
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Test user cannot change fee
        ts::next_tx(scenario, user);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::set_registration_fee(&mut r, 3000, ts::ctx(scenario));
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_register_sui_happy() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Test registration
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice"), fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    #[expected_failure(abort_code = 2, location = nominal::registry)]
    fun test_register_sui_duplicate() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Register first time
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice"), fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Try to register duplicate - should fail
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee2 = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice"), fee2, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = nominal::registry)]
    fun test_register_sui_wrong_fee() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Test fee validation (under)
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee_under = coin::mint_for_testing<sui::sui::SUI>(999, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice-under"), fee_under, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    fun test_register_sui_over_fee() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Test fee validation (over is ok, contract should refund)
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee_over = coin::mint_for_testing<sui::sui::SUI>(1001, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice-over"), fee_over, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = nominal::registry)]
    fun test_register_coin_not_allowed() {
        let admin = @0xA1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Test coin registration (not allowed yet)
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee_fail = coin::mint_for_testing<TestCoin>(50_000, ctx);
            reg::register_coin<TestCoin>(&mut r, string::utf8(b"bob-fail"), fee_fail, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    fun test_register_coin_allowlist_and_happy() {
        let admin = @0xA1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Allow the coin
        ts::next_tx(scenario, admin);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::set_coin_fee<TestCoin>(&mut r, 50_000, true, ts::ctx(scenario));
            ts::return_shared(r);
        };

        // Test coin registration (now allowed)
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee_ok = coin::mint_for_testing<TestCoin>(50_000, ctx);
            reg::register_coin<TestCoin>(&mut r, string::utf8(b"bob-ok"), fee_ok, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 11, location = nominal::registry)]
    fun test_set_resolved_unauthorized() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Register a name for alice
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"own"), fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Bob can't set resolved addr for alice's name
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::set_resolved(&mut r, string::utf8(b"own"), option::some(bob), &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    fun test_set_resolved_and_transfer() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Register a name for alice
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"own"), fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Alice sets her resolved address
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::set_resolved(&mut r, string::utf8(b"own"), option::some(alice), &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Alice transfers name to Bob
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::transfer_name(&mut r, string::utf8(b"own"), bob, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    #[expected_failure(abort_code = 11, location = nominal::registry)]
    fun test_transferred_name_permissions() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Register a name for alice
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"own"), fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Alice transfers name to Bob
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::transfer_name(&mut r, string::utf8(b"own"), bob, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Alice can no longer manage the name
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::set_resolved(&mut r, string::utf8(b"own"), option::none(), &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
    
    #[test]
    fun test_primary_name_functionality() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 0, ctx);
            reg::share(r, ctx);
        };

        // Register first name for Alice (should become primary automatically)
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice1"), fee, &clock, ctx);
            
            // Verify it's set as primary
            let primary_name = reg::name_of(&r, alice);
            assert!(option::is_some(&primary_name), 1);
            assert!(option::destroy_some(primary_name) == string::utf8(b"alice1"), 2);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };
        
        // Register second name for Alice (should not override primary)
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice2"), fee, &clock, ctx);
            
            // Verify primary is still the first name
            let primary_name = reg::name_of(&r, alice);
            assert!(option::is_some(&primary_name), 3);
            assert!(option::destroy_some(primary_name) == string::utf8(b"alice1"), 4);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };
        
        // Alice explicitly changes primary name
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            reg::set_primary_name(&mut r, string::utf8(b"alice2"), ctx);
            
            // Verify primary changed
            let primary_name = reg::name_of(&r, alice);
            assert!(option::is_some(&primary_name), 5);
            assert!(option::destroy_some(primary_name) == string::utf8(b"alice2"), 6);
            
            ts::return_shared(r);
        };
        
        // Bob registers a name
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"bob1"), fee, &clock, ctx);
            
            // Verify it's set as primary
            let primary_name = reg::name_of(&r, bob);
            assert!(option::is_some(&primary_name), 7);
            assert!(option::destroy_some(primary_name) == string::utf8(b"bob1"), 8);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };
        
        // Alice transfers her primary name to Bob (should not override Bob's primary)
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            reg::transfer_name(&mut r, string::utf8(b"alice2"), bob, &clock, ctx);
            
            // Verify Alice no longer has a primary name
            let alice_primary = reg::name_of(&r, alice);
            assert!(option::is_none(&alice_primary), 9);
            
            // Verify Bob's primary is unchanged
            let bob_primary = reg::name_of(&r, bob);
            assert!(option::is_some(&bob_primary), 10);
            assert!(option::destroy_some(bob_primary) == string::utf8(b"bob1"), 11);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };
        
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 14, location = nominal::registry)]
    fun test_relayer_allowlist_enforced_negative() {
        let admin = @0xA1;
        let alice = @0xB1;
        let relayer = @0xD1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry (fee=1000, bps=300)
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Enable relayer allowlist gating; assert event emitted
        ts::next_tx(scenario, admin);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::set_require_allowlisted_relayer(&mut r, true, ts::ctx(scenario));
            // Expect exactly one event in this tx and it should be of type RequireAllowlistedRelayerChanged
            let total = event::num_events();
            assert!(total == 1, 1000);
            let v = event::events_by_type<RequireAllowlistedRelayerChanged>();
            assert!(vector::length(&v) == 1, 1001);
            ts::return_shared(r);
        };

        // Relayer attempts meta registration but is not allowlisted -> abort E_RELAYER_NOT_ALLOWED (14)
        ts::next_tx(scenario, relayer);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            // deadline in future, amount_expected equals provided
            reg::register_with_sig_sui(&mut r, string::utf8(b"deny"), alice, relayer, 1000, 9999999999, 0, fee, &clock, ctx);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_relayer_allowlist_positive_and_events() {
        let admin = @0xA1;
        let alice = @0xB1; // owner
        let relayer = @0xD1; // relayer/sender
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        {
            // Create and share the registry (fee=1000, bps=300)
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Admin allowlists relayer and enables gating; assert both events
        ts::next_tx(scenario, admin);
        {
            let r = ts::take_shared<Registry>(scenario);
            reg::add_relayer(&mut r, relayer, ts::ctx(scenario));
            reg::set_require_allowlisted_relayer(&mut r, true, ts::ctx(scenario));
            // We expect two events in this tx: RelayerAdded and RequireAllowlistedRelayerChanged
            let total = event::num_events();
            assert!(total == 2, 1100);
            let v_added = event::events_by_type<RelayerAdded>();
            assert!(vector::length(&v_added) == 1, 1101);
            let v_req = event::events_by_type<RequireAllowlistedRelayerChanged>();
            assert!(vector::length(&v_req) == 1, 1102);
            ts::return_shared(r);
        };

        // Relayer performs meta registration for Alice; assert FeePaid event fields
        ts::next_tx(scenario, relayer);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1200, ctx); // overpay to test change; required is 1000
            reg::register_with_sig_sui(&mut r, string::utf8(b"allow"), alice, relayer, 1200, 9999999999, 0, fee, &clock, ctx);
            // Expect at least one FeePaid event in this tx
            let v_fee = event::events_by_type<FeePaid>();
            assert!(vector::length(&v_fee) >= 1, 1200);
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
}
