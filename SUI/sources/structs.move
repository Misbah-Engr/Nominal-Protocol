module nominal::structs {
    use std::option::Option;

    /// Record for a registered name
    struct Record has store, drop {
        owner: address,
        resolved: Option<address>,
        updated_at: u64,
    }

    public fun new_record(owner: address, resolved: Option<address>, updated_at: u64): Record {
        Record { owner, resolved, updated_at }
    }

    public fun owner(rec: &Record): address { rec.owner }
    public fun resolved(rec: &Record): &Option<address> { &rec.resolved }
    public fun updated_at(rec: &Record): u64 { rec.updated_at }

    public fun set_owner(rec: &mut Record, o: address) { rec.owner = o; }
    public fun set_resolved(rec: &mut Record, r: Option<address>) { rec.resolved = r; }
    public fun set_updated_at(rec: &mut Record, t: u64) { rec.updated_at = t; }
    public fun set_updated(rec: &mut Record, t: u64) { rec.updated_at = t; }
}
