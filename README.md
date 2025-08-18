# BTC at Risk Query

This repository contains the SQL query used to identify quantum-vulnerable Bitcoin addresses on the Bitcoin mainnet blockchain. This query powers the [BTC at Risk Tracker](https://www.projecteleven.com/btc-at-risk) by analyzing the public Bitcoin blockchain data available through the [BigQuery Bitcoin ETL](https://github.com/blockchain-etl/bitcoin-etl).

## What Makes an Address Quantum-Vulnerable?

An address becomes quantum-vulnerable when its public key has been exposed on the Bitcoin mainnet blockchain. This can happen in two ways:

1. **Address Type**: Some address types (P2PK, P2MS, P2TR) expose their public key immediately when receiving funds.
2. **Address Reuse**: Any address that has been used to send a transaction has its public key exposed. If funds remain in or are sent back to such an address, they become quantum-vulnerable.

## Query Overview

The main query (`btc_at_quantum_risk_query.sql`) identifies addresses with exposed public keys and their current unspent balances. It:
- Tracks addresses exposed through spends
- Identifies inherently exposed address types
- Calculates current balances for all exposed addresses
- Uses table partitioning for efficient processing

## Usage

To run this query:

1. Sign up for Google Cloud Platform (includes free tier with 1TB monthly query quota)
2. Open [BigQuery Studio](https://console.cloud.google.com/bigquery)
3. Configure the query:
   ```sql
   -- Set your destination table
   CREATE OR REPLACE TABLE `your-project.your_dataset.your_table_name` AS

   -- Adjust analysis window (examples)
   DECLARE cutoff_month DATE DEFAULT '2011-01-01';        -- Early Bitcoin history
   DECLARE cutoff_block INT64 DEFAULT 100000;            -- First ~100k blocks
   ```

## Learn More

- Read our detailed blog post about [Quantum vulnerability of Bitcoin addresses](https://blog.projecteleven.com/posts/quantum-vulnerability-of-bitcoin-addresses)
- Check our [FAQs](https://www.projecteleven.com/btc-at-risk/faqs) for common questions about BTC at risk