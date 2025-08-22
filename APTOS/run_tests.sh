#!/bin/bash
set -e

echo "Building Aptos test container..."
docker build -t nominal-aptos-test .

echo "Running Aptos Move tests..."
docker run --rm nominal-aptos-test aptos move test

echo "Test run complete."
