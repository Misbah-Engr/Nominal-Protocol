#!/bin/bash

# Example script for interacting with the Nominal Protocol NEAR contract
# This script demonstrates how to use NEAR CLI to interact with the contract

# Set variables
CONTRACT_ID="dev-1661234567890-12345678901234"
TREASURY_ID="treasury.near"
ALICE_ID="alice.near"
BOB_ID="bob.near"

# 1. Deploy the contract (assuming it's already built)
echo "Deploying contract..."
near dev-deploy target/wasm32-unknown-unknown/release/nominal_protocol.wasm

# 2. Initialize the contract
echo "Initializing contract..."
near call $CONTRACT_ID new '{"owner": "'$ALICE_ID'", "treasury": "'$TREASURY_ID'", "registration_fee": "1000000000000000000000000", "referrer_bps": 300}' --accountId $ALICE_ID

# 3. Register a name
echo "Registering a name..."
near call $CONTRACT_ID register '{"name": "alice"}' --accountId $ALICE_ID --deposit 1

# 4. Get the record for a name
echo "Getting record for name..."
near view $CONTRACT_ID get_record '{"name": "alice"}'

# 5. Get the primary name for an account
echo "Getting primary name for account..."
near view $CONTRACT_ID name_of '{"account": "'$ALICE_ID'"}'

# 6. Set a resolved address
echo "Setting resolved address..."
near call $CONTRACT_ID set_resolved '{"name": "alice", "resolved": "'$BOB_ID'"}' --accountId $ALICE_ID

# 7. Transfer name ownership
echo "Transferring name ownership..."
near call $CONTRACT_ID transfer_name '{"name": "alice", "new_owner": "'$BOB_ID'"}' --accountId $ALICE_ID

# 8. Set a name as primary
echo "Setting primary name..."
near call $CONTRACT_ID set_primary_name '{"name": "alice"}' --accountId $BOB_ID

# 9. Admin: Change registration fee
echo "Changing registration fee..."
near call $CONTRACT_ID set_registration_fee '{"amount": "2000000000000000000000000"}' --accountId $ALICE_ID

echo "Done!"
