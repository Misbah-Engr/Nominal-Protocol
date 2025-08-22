#[test_only]
module nominal::primary_name_tests {
    use std::string;
    use std::option;
    use sui::coin;
    use sui::clock::{Self, Clock};
    use sui::test_scenario as ts;
    use sui::tx_context::{TxContext};

    // Import the registry module
    use nominal::registry::{Self as reg, Registry};

    #[test_only]
    fun clock_for_testing(ctx: &mut TxContext): Clock {
        clock::create_for_testing(ctx)
    }

    // Helper to destroy unused clock objects
    fun destroy_clock(clock: Clock) {
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_primary_name_set_on_registration() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Register a name
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice"), fee, &clock, ctx);
            
            // Check that it was set as primary
            let primary_name = reg::name_of(&r, alice);
            assert!(option::is_some(&primary_name), 0);
            assert!(option::destroy_some(primary_name) == string::utf8(b"alice"), 1);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_set_primary_name() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Register two names
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            
            // Register first name
            let fee1 = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice1"), fee1, &clock, ctx);
            
            // Register second name
            let fee2 = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice2"), fee2, &clock, ctx);
            
            // First name should be primary
            let primary_name = reg::name_of(&r, alice);
            assert!(option::destroy_some(primary_name) == string::utf8(b"alice1"), 0);
            
            // Set second name as primary
            reg::set_primary_name(&mut r, string::utf8(b"alice2"), ctx);
            
            // Check that it changed
            let primary_name2 = reg::name_of(&r, alice);
            assert!(option::destroy_some(primary_name2) == string::utf8(b"alice2"), 1);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = nominal::registry)]
    fun test_set_primary_name_invalid_name() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Register a name
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"alice"), fee, &clock, ctx);
            
            // Try to set an invalid name as primary (invalid characters)
            reg::set_primary_name(&mut r, string::utf8(b"ALICE!"), ctx);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 12, location = nominal::registry)]
    fun test_set_primary_name_nonexistent() {
        let admin = @0xA1;
        let alice = @0xB1;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Try to set a nonexistent name as primary
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            
            // Try to set a name that doesn't exist
            reg::set_primary_name(&mut r, string::utf8(b"nonexistent"), ctx);
            
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = 11, location = nominal::registry)]
    fun test_set_primary_name_not_owner() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Alice registers a name
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

        // Bob tries to set Alice's name as his primary
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            
            // Try to set Alice's name as Bob's primary
            reg::set_primary_name(&mut r, string::utf8(b"alice"), ctx);
            
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_transfer_name_primary_name_handling() {
        let admin = @0xA1;
        let alice = @0xB1;
        let bob = @0xB2;
        let treasury = @0xC1;
        let scenario_val = ts::begin(admin);
        let scenario = &mut scenario_val;

        // Create and share the registry
        {
            let ctx = ts::ctx(scenario);
            let r = reg::new(admin, treasury, 1000, 300, ctx);
            reg::share(r, ctx);
        };

        // Alice registers a name
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            
            let fee = coin::mint_for_testing<sui::sui::SUI>(1000, ctx);
            reg::register_sui(&mut r, string::utf8(b"test"), fee, &clock, ctx);
            
            // Check that it's Alice's primary name
            let primary_name = reg::name_of(&r, alice);
            assert!(option::destroy_some(primary_name) == string::utf8(b"test"), 0);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Alice transfers the name to Bob
        ts::next_tx(scenario, alice);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            
            // Transfer to Bob
            reg::transfer_name(&mut r, string::utf8(b"test"), bob, &clock, ctx);
            
            // Alice's primary name should be cleared
            let alice_primary = reg::name_of(&r, alice);
            assert!(option::is_none(&alice_primary), 1);
            
            // Bob should have it as primary
            let bob_primary = reg::name_of(&r, bob);
            assert!(option::destroy_some(bob_primary) == string::utf8(b"test"), 2);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        // Bob transfers back to Alice
        ts::next_tx(scenario, bob);
        {
            let r = ts::take_shared<Registry>(scenario);
            let ctx = ts::ctx(scenario);
            let clock = clock_for_testing(ctx);
            
            // Transfer back to Alice
            reg::transfer_name(&mut r, string::utf8(b"test"), alice, &clock, ctx);
            
            // Bob's primary name should be cleared
            let bob_primary = reg::name_of(&r, bob);
            assert!(option::is_none(&bob_primary), 3);
            
            // Alice should have it as primary again
            let alice_primary = reg::name_of(&r, alice);
            assert!(option::destroy_some(alice_primary) == string::utf8(b"test"), 4);
            
            destroy_clock(clock);
            ts::return_shared(r);
        };

        ts::end(scenario_val);
    }
}
