#!/bin/bash

set -e

echo "=================================="
echo "🚀 Cardano Stake Pool Setup Menu"
echo "=================================="
echo "1. Create New Stake Pool Operator (SPO)"
echo "2. Manage Existing Pool (Operator Actions)"
read -p "Enter your choice (1 or 2): " MAIN_CHOICE

if [ "$MAIN_CHOICE" -eq 2 ]; then
    echo "Available Operator Actions:"
    echo "1. Change Pool Parameters"
    echo "2. Withdraw Pool Rewards"
    read -p "Select action (1 or 2): " OPERATION

    if [ "$OPERATION" -eq 1 ]; then
        change_pool_parameters
        exit 0
    elif [ "$OPERATION" -eq 2 ]; then
        withdraw_rewards
        exit 0
    else
        echo "Invalid operation choice. Exiting..."
        exit 1
    fi
fi


# ===  System Update and Dependencies ===

echo "=== Updating System and Installing Dependencies ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget tar ufw nginx git jq bc unzip net-tools

# === Install Cardano CLI ===

echo "=== Installing Cardano CLI ==="
cd ~
CARDANO_CLI_VERSION="1.35.4"  
wget https://github.com/input-output-hk/cardano-node/releases/download/${CARDANO_CLI_VERSION}/cardano-node-${CARDANO_CLI_VERSION}-linux.tar.gz
tar -xzvf cardano-node-${CARDANO_CLI_VERSION}-linux.tar.gz
sudo mv cardano-node-${CARDANO_CLI_VERSION}/cardano-cli /usr/local/bin/
rm -rf cardano-node-${CARDANO_CLI_VERSION}

echo "=== Select Network ==="
echo "1. Mainnet"
echo "2. Preview"
read -p "Enter the network choice (1 for Mainnet, 2 for Preview): " NETWORK_CHOICE

if [ "$NETWORK_CHOICE" -eq 1 ]; then
    NETWORK="mainnet"
    CARDANO_CLI_NETWORK_PARAM="--mainnet"
elif [ "$NETWORK_CHOICE" -eq 2 ]; then
    NETWORK="preview"
    CARDANO_CLI_NETWORK_PARAM="--testnet-magic 1" 
else
    echo "Invalid selection. Exiting..."
    exit 1
fi

# === Prompt for Pool Parameters ===

echo "=== Cardano Stake Pool Setup ==="
read -p "Enter your pool name (e.g., MyPool): " POOL_NAME
read -p "Enter your pool ticker (3-5 uppercase letters): " POOL_TICKER
read -p "Enter your pool description (max 255 characters): " POOL_DESCRIPTION
read -p "Enter your pool homepage URL: " POOL_HOMEPAGE
read -p "Enter your pledge amount in ADA (e.g., 500000): " POOL_PLEDGE
read -p "Enter your pool cost per epoch in ADA (minimum 340): " POOL_COST
read -p "Enter your pool margin (e.g., 0.05 for 5%): " POOL_MARGIN
read -p "Enter your relay node DNS or IP: " RELAY_HOST
read -p "Enter your relay node port (e.g., 6000): " RELAY_PORT
read -p "Enter your metadata URL (publicly hosted poolMetaData.json): " METADATA_URL

PLEDGE_LOVELACE=$((POOL_PLEDGE * 1000000))
COST_LOVELACE=$((POOL_COST * 1000000))

# === Generate Payment and Stake Keys ===

echo "=== Generating Payment and Stake Keys ==="
mkdir -p ~/cardano-node/keys
cd ~/cardano-node/keys

cardano-cli address key-gen --verification-key-file payment.vkey --signing-key-file payment.skey
cardano-cli stake-address key-gen --verification-key-file stake.vkey --signing-key-file stake.skey
cardano-cli address build --payment-verification-key-file payment.vkey --stake-verification-key-file stake.vkey $CARDANO_CLI_NETWORK_PARAM --out-file payment.addr
cardano-cli stake-address build --stake-verification-key-file stake.vkey $CARDANO_CLI_NETWORK_PARAM --out-file stake.addr

# === Balance Check ===

echo "=== Checking Wallet Balance ==="
BALANCE=$(cardano-cli query utxo --address $(cat payment.addr) $CARDANO_CLI_NETWORK_PARAM | tail -n +3 | awk '{print $3}')
if [ "$BALANCE" -lt 10000000 ]; then 
    echo "Your balance is below 10 ADA. Please top up your wallet."
    echo "Waiting for balance to increase..."
    while [ "$BALANCE" -lt 10000000 ]; do
        sleep 100 
        BALANCE=$(cardano-cli query utxo --address $(cat payment.addr) $CARDANO_CLI_NETWORK_PARAM | tail -n +3 | awk '{print $3}')
    done
    echo "Balance is sufficient. Proceeding with the setup..."
fi

# === Node Keys ===

echo "=== Generating Cold, KES, and VRF Keys ==="
cardano-cli node key-gen --cold-verification-key-file cold.vkey --cold-signing-key-file cold.skey --operational-certificate-issue-counter cold.counter
cardano-cli node key-gen-KES --verification-key-file kes.vkey --signing-key-file kes.skey
cardano-cli node key-gen-VRF --verification-key-file vrf.vkey --signing-key-file vrf.skey

# === [7/14] Generate Operational Certificate ===

echo "=== Generating Operational Certificate ==="
SLOT_NO=$(cardano-cli query tip $CARDANO_CLI_NETWORK_PARAM | jq -r .slot)
KES_PERIOD=$((SLOT_NO / 129600))

cardano-cli node issue-op-cert \
  --kes-verification-key-file kes.vkey \
  --cold-signing-key-file cold.skey \
  --operational-certificate-issue-counter cold.counter \
  --kes-period $KES_PERIOD \
  --out-file node.cert

# === Create Pool Metadata ===

echo "=== Creating Pool Metadata ==="
cat > poolMetaData.json << EOF
{
  "name": "$POOL_NAME",
  "description": "$POOL_DESCRIPTION",
  "ticker": "$POOL_TICKER",
  "homepage": "$POOL_HOMEPAGE"
}
EOF

cardano-cli stake-pool metadata-hash --pool-metadata-file poolMetaData.json > poolMetaDataHash.txt

# === Register Stake Address ===

echo "=== Registering Stake Address ==="
cardano-cli stake-address registration-certificate \
  --stake-verification-key-file stake.vkey \
  --out-file stake.cert

# === Generate Pool Registration Certificate ===

echo "=== Generating Pool Registration Certificate ==="
METADATA_HASH=$(cat poolMetaDataHash.txt)

cardano-cli stake-pool registration-certificate \
  --cold-verification-key-file cold.vkey \
  --vrf-verification-key-file vrf.vkey \
  --pool-pledge $PLEDGE_LOVELACE \
  --pool-cost $COST_LOVELACE \
  --pool-margin $POOL_MARGIN \
  --pool-reward-account-verification-key-file stake.vkey \
  --pool-owner-stake-verification-key-file stake.vkey \
  $CARDANO_CLI_NETWORK_PARAM \
  --single-host-pool-relay $RELAY_HOST \
  --pool-relay-port $RELAY_PORT \
  --metadata-url $METADATA_URL \
  --metadata-hash $METADATA_HASH \
  --out-file pool.cert

# === Generate Delegation Certificate ===

echo "=== Generating Delegation Certificate ==="
cardano-cli stake-address delegation-certificate \
  --stake-verification-key-file stake.vkey \
  --cold-verification-key-file cold.vkey \
  --out-file delegation.cert

# === Prepare Transaction Inputs ===

echo "=== Querying UTXO and Preparing Inputs ==="
cardano-cli query utxo --address $(cat payment.addr) $CARDANO_CLI_NETWORK_PARAM > fullUtxo.out
TX_IN=$(tail -n +3 fullUtxo.out | awk '{ print $1 "#" $2 }' | tr '\n' ' ')
TOTAL_LOVELACE=$(tail -n +3 fullUtxo.out | awk '{ sum += $3 } END { print sum }')

# === Build Transaction Draft ===

echo "=== Building Transaction Draft ==="
cardano-cli query protocol-parameters $CARDANO_CLI_NETWORK_PARAM --out-file protocol.json

cardano-cli transaction build-raw \
  --tx-in $TX_IN \
  --tx-out $(cat payment.addr)+0 \
  --ttl 0 \
  --fee 0 \
  --out-file tx.tmp \
  --certificate-file stake.cert \
  --certificate-file pool.cert \
  --certificate-file delegation.cert

FEE=$(cardano-cli transaction calculate-min-fee \
  --tx-body-file tx.tmp \
  --tx-in-count 1 \
  --tx-out-count 1 \
  --$CARDANO_CLI_NETWORK_PARAM \
  --witness-count 3 \
  --byron-witness-count 0 \
  --protocol-params-file protocol.json | awk '{ print $1 }')

CHANGE=$((TOTAL_LOVELACE - PLEDGE_LOVELACE - COST_LOVELACE - FEE))

cardano-cli transaction build-raw \
  --tx-in $TX_IN \
  --tx-out $(cat payment.addr)+$CHANGE \
  --fee $FEE \
  --out-file tx.raw \
  --certificate-file stake.cert \
  --certificate-file pool.cert \
  --certificate-file delegation.cert

# === Sign the Transaction ===

echo "=== Signing Transaction ==="
cardano-cli transaction sign \
  --tx-body-file tx.raw \
  --signing-key-file payment.skey \
  --signing-key-file stake.skey \
  --signing-key-file cold.skey \
  $CARDANO_CLI_NETWORK_PARAM \
  --out-file tx.signed

# === Submit the Transaction ===

echo "=== Submitting Transaction to the Network ==="
cardano-cli transaction submit --tx-file tx.signed $CARDANO_CLI_NETWORK_PARAM

# === Save Keys and Information to a File ===

echo "=== Saving Keys and Information ==="
cat > pooloperator.txt << EOF
Pool Name: $POOL_NAME
Pool Ticker: $POOL_TICKER
Pool Description: $POOL_DESCRIPTION
Pool Homepage: $POOL_HOMEPAGE
Pool Pledge: $POOL_PLEDGE ADA
Pool Cost: $POOL_COST ADA
Pool Margin: $POOL_MARGIN
Relay Host: $RELAY_HOST
Relay Port: $RELAY_PORT
Metadata URL: $METADATA_URL

Payment Address: $(cat payment.addr)
Stake Address: $(cat stake.addr)

Cold Key: $(cat cold.vkey)
KES Key: $(cat kes.vkey)
VRF Key: $(cat vrf.vkey)

Mnemonic: [Placeholder for your mnemonic, if required]

=== End of Configuration ===
EOF

echo "=== Setup Complete! ==="
echo "Keys and information saved to pooloperator.txt"
echo "=== Installing Prometheus and Grafana ==="
echo "global:
  scrape_interval: 10s
scrape_configs:
  - job_name: 'cardano-node'
    static_configs:
      - targets: ['localhost:12798']  
" | sudo tee /etc/prometheus/prometheus.yml

sudo systemctl enable prometheus
sudo systemctl start prometheus

sudo systemctl enable grafana-server
sudo systemctl start grafana-server

echo "Prometheus and Grafana are installed and running. Access Grafana at http://localhost:3000 (default credentials: admin/admin)."

echo "=== Setting up Grafana Dashboard ==="
sudo grafana-cli plugins install grafana-cardano-datasource

sudo grafana-cli plugins enable grafana-cardano-datasource

sudo systemctl restart grafana-server

change_pool_parameters() {
    echo "=== Changing Pool Parameters ==="
    read -p "Enter the new pool pledge (in ADA): " NEW_PLEDGE
    read -p "Enter the new pool cost (in ADA): " NEW_COST
    read -p "Enter the new pool margin (e.g., 0.05 for 5%): " NEW_MARGIN
    
    NEW_PLEDGE_LOVELACE=$((NEW_PLEDGE * 1000000))
    NEW_COST_LOVELACE=$((NEW_COST * 1000000))

    cardano-cli stake-pool registration-certificate \
      --cold-verification-key-file cold.vkey \
      --vrf-verification-key-file vrf.vkey \
      --pool-pledge $NEW_PLEDGE_LOVELACE \
      --pool-cost $NEW_COST_LOVELACE \
      --pool-margin $NEW_MARGIN \
      --pool-reward-account-verification-key-file stake.vkey \
      --pool-owner-stake-verification-key-file stake.vkey \
      $CARDANO_CLI_NETWORK_PARAM \
      --single-host-pool-relay $RELAY_HOST \
      --pool-relay-port $RELAY_PORT \
      --metadata-url $METADATA_URL \
      --metadata-hash $METADATA_HASH \
      --out-file new_pool.cert

    echo "Pool parameters updated successfully!"
}
withdraw_rewards() {
    echo "=== Withdrawing Pool Rewards ==="
    read -p "Enter your withdrawal address: " WITHDRAWAL_ADDRESS
    read -p "Enter the amount to withdraw (in ADA): " WITHDRAW_AMOUNT

    WITHDRAW_AMOUNT_LOVELACE=$((WITHDRAW_AMOUNT * 1000000))
    cardano-cli transaction build-raw \
      --tx-in $TX_IN \
      --tx-out $WITHDRAWAL_ADDRESS+$WITHDRAW_AMOUNT_LOVELACE \
      --fee 0 \
      --out-file withdraw.tx

    FEE=$(cardano-cli transaction calculate-min-fee \
      --tx-body-file withdraw.tx \
      --tx-in-count 1 \
      --tx-out-count 1 \
      --$CARDANO_CLI_NETWORK_PARAM \
      --witness-count 3 \
      --protocol-params-file protocol.json | awk '{ print $1 }')

    cardano-cli transaction build-raw \
      --tx-in $TX_IN \
      --tx-out $WITHDRAWAL_ADDRESS+$WITHDRAW_AMOUNT_LOVELACE \
      --fee $FEE \
      --out-file withdraw.raw

    cardano-cli transaction sign \
      --tx-body-file withdraw.raw \
      --signing-key-file payment.skey \
      --signing-key-file stake.skey \
      --signing-key-file cold.skey \
      $CARDANO_CLI_NETWORK_PARAM \
      --out-file withdraw.signed
    cardano-cli transaction submit --tx-file withdraw.signed $CARDANO_CLI_NETWORK_PARAM

    echo "Withdrawal request submitted successfully!"
}

echo "Choose an operation:"
echo "1. Change Pool Parameters"
echo "2. Withdraw Pool Rewards"
read -p "Enter choice (1 or 2): " OPERATION

if [ "$OPERATION" -eq 1 ]; then
    change_pool_parameters
elif [ "$OPERATION" -eq 2 ]; then
    withdraw_rewards
else
    echo "Invalid operation choice. Exiting..."
fi

echo "=== End of Configuration ==="