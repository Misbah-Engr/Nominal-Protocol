module nominal::errors {
    public fun E_INVALID_NAME(): u64 { 1 }
    public fun E_NAME_TAKEN(): u64 { 2 }
    public fun E_WRONG_FEE(): u64 { 3 }
    public fun E_COIN_NOT_ALLOWED(): u64 { 4 }
    public fun E_UNAUTHORIZED(): u64 { 5 }
    public fun E_DEADLINE(): u64 { 8 }
    public fun E_BAD_SIG(): u64 { 9 }
    public fun E_WRONG_RELAYER(): u64 { 10 }
    public fun E_NOT_OWNER(): u64 { 11 }
    public fun E_NAME_NOT_FOUND(): u64 { 12 }
    public fun E_INVALID_BPS(): u64 { 13 }
    public fun E_RELAYER_NOT_ALLOWED(): u64 { 14 }
}
