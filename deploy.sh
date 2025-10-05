#!/bin/bash

# SpectralPay Smart Contracts Deployment Script
# This script deploys all contracts to Starknet testnet

echo "Starting SpectralPay Smart Contracts Deployment to Testnet..."

# Check if sncast is available
if ! command -v sncast &> /dev/null; then
    echo " sncast not found. Please install Starknet Foundry first."
    exit 1
fi

# Set profile to testnet
export SNCAST_PROFILE=testnet

# Deploy contracts in dependency order
echo " Deploying contracts in dependency order..."

# 1. Deploy ZKVerifier first (no dependencies)
echo "1️ Deploying ZKVerifier..."
ZK_VERIFIER_OUTPUT=$(sncast declare --contract-name spectralpay_ZKVerifier --max-fee 1000000000000000)
echo "ZKVerifier deployment output: $ZK_VERIFIER_OUTPUT"

# Extract class hash from output (this is a simplified approach)
ZK_VERIFIER_CLASS_HASH=$(echo "$ZK_VERIFIER_OUTPUT" | grep -o 'class_hash: [0-9a-fx]*' | cut -d' ' -f2)
echo "ZKVerifier class hash: $ZK_VERIFIER_CLASS_HASH"

# 2. Deploy PseudonymRegistry (depends on ZKVerifier)
echo "2️ Deploying PseudonymRegistry..."
PSEUDONYM_OUTPUT=$(sncast declare --contract-name spectralpay_PseudonymRegistry --max-fee 1000000000000000)
echo "PseudonymRegistry deployment output: $PSEUDONYM_OUTPUT"

# 3. Deploy JobMarketplace (depends on PseudonymRegistry and ZKVerifier)
echo "3️ Deploying JobMarketplace..."
JOB_MARKETPLACE_OUTPUT=$(sncast declare --contract-name spectralpay_JobMarketplace --max-fee 1000000000000000)
echo "JobMarketplace deployment output: $JOB_MARKETPLACE_OUTPUT"

# 4. Deploy Escrow (depends on JobMarketplace)
echo "4️ Deploying Escrow..."
ESCROW_OUTPUT=$(sncast declare --contract-name spectralpay_Escrow --max-fee 1000000000000000)
echo "Escrow deployment output: $ESCROW_OUTPUT"

echo " All contracts declared successfully!"
echo " Next steps:"
echo "   1. Copy the class hashes from the output above"
echo "   2. Use sncast deploy to instantiate the contracts with constructor parameters"
echo "   3. Update your frontend with the deployed contract addresses"

echo ""
echo " Deploying contract instances..."

# Deploy ZKVerifier
echo "1️ Deploying ZKVerifier instance..."
ZK_VERIFIER_ADDRESS=$(sncast deploy --class-hash 0x016d7648703c209cc3c77da002124919c0efb447bab42f8ac0c2e7b89ab6208b --constructor-calldata 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef | grep -o 'contract_address: [0-9a-fx]*' | cut -d' ' -f2)
echo "ZKVerifier deployed at: $ZK_VERIFIER_ADDRESS"

# Deploy PseudonymRegistry
echo "2️ Deploying PseudonymRegistry instance..."
PSEUDONYM_ADDRESS=$(sncast deploy --class-hash 0x064f877910cb1bcc9ad11ead3292ac4fec6697646ad769e5d61af38eefebd1e5 --constructor-calldata 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a 0 1 $ZK_VERIFIER_ADDRESS | grep -o 'contract_address: [0-9a-fx]*' | cut -d' ' -f2)
echo "PseudonymRegistry deployed at: $PSEUDONYM_ADDRESS"

# Deploy Escrow
echo "3️ Deploying Escrow instance..."
ESCROW_ADDRESS=$(sncast deploy --class-hash 0x06bd81233d07960b2499f44e4af89bfe0e35f5ef3e6afd4979effe87e5689ba9 --constructor-calldata 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a 0 100 0x018ed9DA972b06b7C3479385992792900EC86cB8fEA9a7cAdD5a85fef89fD20B 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a | grep -o 'contract_address: [0-9a-fx]*' | cut -d' ' -f2)
echo "Escrow deployed at: $ESCROW_ADDRESS"

# Deploy JobMarketplace
echo "4️ Deploying JobMarketplace instance..."
JOB_MARKETPLACE_ADDRESS=$(sncast deploy --class-hash 0x07ac6b2bb7d63198ee873dad1bcdaf9bb6c6709f2a8c54de5dfe04e44eb7674c --constructor-calldata 0x2ae0011d786caa2b3467691be1c5cc754024cec3eb3f051703d1d8dda1bc99a $PSEUDONYM_ADDRESS $ESCROW_ADDRESS 0 100 0x018ed9DA972b06b7C3479385992792900EC86cB8fEA9a7cAdD5a85fef89fD20B | grep -o 'contract_address: [0-9a-fx]*' | cut -d' ' -f2)
echo "JobMarketplace deployed at: $JOB_MARKETPLACE_ADDRESS"

echo ""
echo " All contracts deployed successfully!"
echo " Contract Addresses:"
echo "   ZKVerifier: $ZK_VERIFIER_ADDRESS"
echo "   PseudonymRegistry: $PSEUDONYM_ADDRESS"
echo "   Escrow: $ESCROW_ADDRESS"
echo "   JobMarketplace: $JOB_MARKETPLACE_ADDRESS"
echo ""
echo " Update deployments.json with these addresses"
echo " Deployment process completed!"
