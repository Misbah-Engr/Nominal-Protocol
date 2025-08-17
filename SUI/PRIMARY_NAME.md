# Primary Name Feature in Nominal Protocol (SUI)

## Overview

The primary name feature enhances the Nominal Protocol on SUI by enabling bidirectional resolution between names and addresses. This implementation aligns with the EVM version and completes the functionality described in the litepaper.

## Key Components

1. **Storage**:
   - Added `primary_names: Table<address, vector<u8>>` to the Registry struct to track primary names per address

2. **New Functions**:
   - `name_of(reg: &Registry, addr: address): Option<String>` - Returns the primary name for an address
   - `set_primary_name(reg: &mut Registry, name: String, ctx: &TxContext)` - Sets a name as primary for the caller's address

3. **Enhanced Functions**:
   - Updated `register_internal_sui` and `register_internal_coin` to set the first registered name as primary
   - Updated `transfer_name` to handle primary name changes during ownership transfers

4. **New Event**:
   - `PrimaryNameSet { owner: address, name: String }` - Emitted when a primary name is set or changed

## Behavior

1. **Initial Registration**:
   - When a user registers their first name, it's automatically set as their primary name
   - Subsequent registrations don't change the primary name

2. **Setting Primary Name**:
   - A user can explicitly choose which of their names is primary via `set_primary_name`
   - Only the owner of a name can set it as their primary name
   - The name must exist and be valid

3. **Name Transfers**:
   - When a user transfers a name that is their primary, their primary name is cleared
   - If the recipient doesn't have a primary name, the transferred name becomes their primary
   - If the recipient already has a primary name, it remains unchanged

## Testing

Comprehensive tests cover all aspects of primary name functionality:
- Automatic primary name setting during registration
- Explicit primary name changes
- Validation of name ownership and existence
- Primary name behavior during transfers
- Edge cases and error handling

## Integration with Cross-Chain Functionality

This enhancement supports the cross-chain vision of Nominal Protocol by:
1. Enabling wallets to display human-readable names for addresses on SUI
2. Providing consistent UX between EVM and SUI implementations
3. Supporting the authority score calculation described in the litepaper
