#!/bin/bash

# This script builds and runs a Docker container for testing the NEAR implementation

echo "Building Docker image for NEAR testing..."
cd /workspaces/Nominal-Protocol/NEAR
docker build -t nominal-near .

echo "Running Docker container..."
docker run -it --rm nominal-near

# Note: This will open a bash shell inside the container where you can:
# 1. Deploy the contract: near dev-deploy target/wasm32-unknown-unknown/release/nominal_protocol.wasm
# 2. Interact with it using NEAR CLI commands
# 3. Type 'near-help' for guidance
