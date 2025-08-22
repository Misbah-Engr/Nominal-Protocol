#!/bin/bash

# This script builds and tests the Nominal Protocol NEAR implementation

echo "Building the contract..."
cd /workspaces/Nominal-Protocol/NEAR
rustup target add wasm32-unknown-unknown

# Try to build the contract (even if tests can't run)
cargo build --target wasm32-unknown-unknown --release

if [ $? -eq 0 ]; then
    echo -e "\n✅ Build successful!"
    echo "The contract is ready at target/wasm32-unknown-unknown/release/nominal_protocol.wasm"
    
    # Check the file size
    ls -lh target/wasm32-unknown-unknown/release/nominal_protocol.wasm
    
    echo -e "\nℹ️ Note: Due to dependency issues, unit tests could not be run directly."
    echo "To test in a full NEAR environment, you would deploy to testnet with:"
    echo "near dev-deploy target/wasm32-unknown-unknown/release/nominal_protocol.wasm"
else
    echo -e "\n❌ Build failed."
fi
