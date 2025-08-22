module nominal::test_coin {
    use aptos_framework::coin;
    use std::signer;
    use std::string;

    struct TestCoin has key, store, drop {}

    struct Caps has key {
        mint: coin::MintCapability<TestCoin>,
        burn: coin::BurnCapability<TestCoin>,
        freeze: coin::FreezeCapability<TestCoin>,
    }

    public fun init(admin: &signer) {
    let (burn, freeze, mint) = coin::initialize<TestCoin>(
            admin,
            string::utf8(b"Nominal Test Coin"),
            string::utf8(b"NTC"),
            6,
            false
        );
    move_to(admin, Caps { mint, burn, freeze });
    }

    public fun register(account: &signer) { coin::register<TestCoin>(account); }

    #[test_only]
    public fun mint_for_testing(admin: &signer, to: address, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(signer::address_of(admin));
        let c = coin::mint(amount, &caps.mint);
        coin::deposit<TestCoin>(to, c);
    }
}
