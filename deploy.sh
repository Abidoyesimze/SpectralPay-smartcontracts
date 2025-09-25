#!/bin/bash

# SpectralPay Smart Contracts Deployment Script
# This script deploys all contracts to Starknet testnet

echo "🚀 Starting SpectralPay Smart Contracts Deployment to Testnet..."

# Check if sncast is available
if ! command -v sncast &> /dev/null; then
    echo "❌ sncast not found. Please install Starknet Foundry first."
    exit 1
fi

# Set profile to testnet
export SNCAST_PROFILE=testnet

# Deploy contracts in dependency order
echo "📋 Deploying contracts in dependency order..."

# 1. Deploy ZKVerifier first (no dependencies)
echo "1️⃣ Deploying ZKVerifier..."
ZK_VERIFIER_OUTPUT=$(sncast declare --contract-name spectralpay_ZKVerifier --max-fee 1000000000000000)
echo "ZKVerifier deployment output: $ZK_VERIFIER_OUTPUT"

# Extract class hash from output (this is a simplified approach)
ZK_VERIFIER_CLASS_HASH=$(echo "$ZK_VERIFIER_OUTPUT" | grep -o 'class_hash: [0-9a-fx]*' | cut -d' ' -f2)
echo "ZKVerifier class hash: $ZK_VERIFIER_CLASS_HASH"

# 2. Deploy PseudonymRegistry (depends on ZKVerifier)
echo "2️⃣ Deploying PseudonymRegistry..."
PSEUDONYM_OUTPUT=$(sncast declare --contract-name spectralpay_PseudonymRegistry --max-fee 1000000000000000)
echo "PseudonymRegistry deployment output: $PSEUDONYM_OUTPUT"

# 3. Deploy JobMarketplace (depends on PseudonymRegistry and ZKVerifier)
echo "3️⃣ Deploying JobMarketplace..."
JOB_MARKETPLACE_OUTPUT=$(sncast declare --contract-name spectralpay_JobMarketplace --max-fee 1000000000000000)
echo "JobMarketplace deployment output: $JOB_MARKETPLACE_OUTPUT"

# 4. Deploy Escrow (depends on JobMarketplace)
echo "4️⃣ Deploying Escrow..."
ESCROW_OUTPUT=$(sncast declare --contract-name spectralpay_Escrow --max-fee 1000000000000000)
echo "Escrow deployment output: $ESCROW_OUTPUT"

echo "✅ All contracts declared successfully!"
echo "📝 Next steps:"
echo "   1. Copy the class hashes from the output above"
echo "   2. Use sncast deploy to instantiate the contracts with constructor parameters"
echo "   3. Update your frontend with the deployed contract addresses"

echo "🎉 Deployment process completed!"
