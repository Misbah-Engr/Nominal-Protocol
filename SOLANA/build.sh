#!/bin/bash

set -e

echo "=== Nominal Registry Solana - Build & Test Script ==="

echo "Step 1: Install dependencies"
npm install

echo "Step 2: Build the program"
anchor build

echo "Step 3: Run tests"
anchor test --skip-local-validator

echo "Step 4: Run security checks"
cd programs/nominal-registry
cargo clippy -- -D warnings
cargo audit

echo "Step 5: Generate IDL and types"
cd ../..
anchor idl parse --file target/idl/nominal_registry.json > idl.json

echo "=== Build Complete! ==="
echo "Next steps:"
echo "1. Deploy to devnet: anchor deploy --provider.cluster devnet"  
echo "2. Initialize registry with admin keys"
echo "3. Test registration flows"
echo "4. Deploy to mainnet when ready"
