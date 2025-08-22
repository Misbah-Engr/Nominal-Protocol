module nominal::structs {
    use std::option;

    struct Record has store, drop {
        owner: address,
        resolved: option::Option<address>,
        updated_at: u64,
    }

    public fun new_record(owner: address, resolved: option::Option<address>, ts: u64): Record {
        Record { owner, resolved, updated_at: ts }
    }

    public fun owner(r: &Record): address { r.owner }
    public fun set_owner(r: &mut Record, o: address) { r.owner = o }
    public fun set_resolved(r: &mut Record, v: option::Option<address>) { r.resolved = v }
    public fun set_updated(r: &mut Record, ts: u64) { r.updated_at = ts }
}
