-- ============================================================================
-- SECTION 0: QUERY OVERVIEW
-- ============================================================================
-- Purpose: Identify Bitcoin addresses with exposed public keys and their balances
-- Output: List of quantum-vulnerable addresses and their unspent balances
--
-- Performance Note: This query uses table partitioning on block_timestamp_month
-- to reduce the amount of data scanned and query costs.

-- ============================================================================
-- SECTION 1: USAGE EXAMPLES AND CONFIGURATION
-- ============================================================================
-- USAGE SCENARIOS:
--
--   1. Initial Analysis (First 100k blocks):
--      SET cutoff_month = '2010-12-01', cutoff_block = 100000
--
--   2. Full Dataset Analysis (as of August 2025):
--      SET cutoff_month = '2025-12-12', cutoff_block = 950000
--
-- CONFIGURATION VARIABLES:
DECLARE cutoff_month DATE DEFAULT '2011-01-01';        -- Partition filter (adjust for time range)
DECLARE cutoff_block INT64 DEFAULT 100000;            -- Block number filter (set high for full dataset)

-- ============================================================================
-- SECTION 2: OUTPUT TABLE CONFIGURATION
-- ============================================================================
-- Purpose: Define the destination table for query results
-- Note: Update the table reference below with your specific project and dataset
CREATE OR REPLACE TABLE `your-project.your_dataset.your_table_name` AS

-- ============================================================================
-- SECTION 3: IDENTIFY ADDRESSES POTENTIALLY EXPOSED BY ADDRESS REUSE
-- ============================================================================
-- Purpose: Find addresses that use script types requiring pubkey revelation on spend
-- Details: 
--   - Includes address types: P2PKH, P2WPKH, P2TR, P2SH, P2WPKH, P2WSH.
--   - Only considers transactions up to specified cutoff block/month
-- Output: For each qualifying output:
--   - transaction_hash: Hash of the transaction containing the output
--   - index: Position of the output in the transaction (zero-based)
--   - address: The Bitcoin address associated with the output
WITH potentially_exposed AS (
  SELECT
    t.hash AS transaction_hash,
    o_index AS index,
    addr AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` t
  CROSS JOIN
    UNNEST(t.outputs) AS o WITH OFFSET AS o_index
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  WHERE
    t.block_timestamp_month <= cutoff_month    -- partition filter ✔
    AND t.block_number <= cutoff_block        -- logical filter
    AND o.type IN (
      'pubkeyhash',
      'witness_v0_keyhash',
      'witness_v1_taproot',
      'witness_v0_scripthash',
      'witness_unknown',
      'multisig',
      'scripthash'
      -- Add or remove other types as needed
    )
),

-- ============================================================================
-- SECTION 4: IDENTIFY ALL SPENT OUTPUTS
-- ============================================================================
-- Purpose: Identify all spent outputs
-- Details:
--   - Links spending transactions to their corresponding inputs
--   - Maintains the same cutoff constraints for consistency
-- Output: For each spent output:
--   - spent_tx_hash: Hash of the transaction being spent
--   - spent_tx_index: Index of the output being spent
--   - spending_address: Address that spent the output
spent_details AS (
  SELECT
    i.spent_transaction_hash AS spent_tx_hash,
    i.spent_output_index AS spent_tx_index,
    addr AS spending_address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` t
  CROSS JOIN
    UNNEST(t.inputs) AS i
  CROSS JOIN
    UNNEST(i.addresses) AS addr
  WHERE
    t.block_timestamp_month <= cutoff_month    -- partition filter ✔
    AND t.block_number <= cutoff_block        -- logical filter
),

-- ============================================================================
-- SECTION 5: IDENTIFY CONFIRMED ADDRESSES THAT EXPOSED THEIR PUBLIC KEY VIA SPENDING
-- ============================================================================
-- Purpose: Find all addresses that have definitely exposed their public keys
-- Details:
--   - Joins potentially exposed addresses with actual spend events
--   - Uses DISTINCT to eliminate duplicate exposures
--   - Creates definitive list of addresses known to have revealed pubkeys
-- Output: For each exposed address:
--   - address: The Bitcoin address that has revealed its public key through spending
revealed_by_spend AS (
  SELECT DISTINCT
    p.address
  FROM
    potentially_exposed p
  JOIN
    spent_details s
  ON
    p.transaction_hash = s.spent_tx_hash
    AND p.index = s.spent_tx_index
),

-- ============================================================================
-- SECTION 6: IDENTIFY ADDRESSES WITH QUANTUM-VULNERABLE SCRIPT TYPES
-- ============================================================================
-- Purpose: Find addresses that used P2PK script type (public key exposed on creation)
-- Details:
--   - P2PK outputs expose public keys immediately in the locking script
--   - These addresses are at quantum risk from the moment of creation
--   - Uses same cutoff constraints as other sections
-- Output: For each P2PK output:
--   - address: The Bitcoin addresses associated with the quantum-vulnerable scripts
p2pk_addresses AS (
  SELECT DISTINCT
    addr AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` t
  CROSS JOIN
    UNNEST(t.outputs) AS o
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  WHERE
    t.block_timestamp_month <= cutoff_month    -- partition filter ✔
    AND t.block_number <= cutoff_block        -- logical filter
    AND o.type = 'pubkey'
),

-- ============================================================================
-- SECTION 7: COMBINE ALL EXPOSED ADDRESSES
-- ============================================================================
-- Purpose: Create a complete set of all addresses that have exposed public keys
-- Details:
--   - Combines addresses from both spend revelation and quantum-vulnerable script types
--   - Uses UNION DISTINCT to ensure no duplicate addresses
--   - Creates final reference list for balance calculation
-- Output: For each unique exposed address:
--   - address: The Bitcoin address that has exposed its public key (either through spending or P2PK)
all_exposed_addresses AS (
  SELECT address FROM revealed_by_spend
  UNION DISTINCT
  SELECT address FROM p2pk_addresses
),

-- ============================================================================
-- SECTION 8: IDENTIFY ALL UNSPENT OUTPUTS
-- ============================================================================
-- Purpose: Find all unspent transaction outputs (UTXOs) within our analysis window
-- Details:
--   - Uses partitioned approach for better performance
--   - Captures all outputs within cutoff constraints
--   - Prepares data for identifying unspent balances
-- Output: For each transaction output:
--   - transaction_hash: Hash of the transaction containing the output
--   - output_index: Position of the output in the transaction (zero-based)
--   - value: Amount of bitcoin in the output (in satoshis)
--   - address: The Bitcoin address controlling this output
all_outputs AS (
  SELECT
    t.hash AS transaction_hash,
    o_index AS output_index,
    o.value,
    addr AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` t
  CROSS JOIN
    UNNEST(t.outputs) AS o WITH OFFSET AS o_index
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  WHERE
    t.block_timestamp_month <= cutoff_month    -- partition filter ✔
    AND t.block_number <= cutoff_block        -- logical filter
),

unspent AS (
  SELECT
    ao.value,
    ao.address
  FROM
    all_outputs ao
  LEFT JOIN
    spent_details sd
  ON
    ao.transaction_hash = sd.spent_tx_hash
    AND ao.output_index = sd.spent_tx_index
  WHERE
    sd.spent_tx_hash IS NULL  -- unspent condition
),

-- ============================================================================
-- SECTION 9: CALCULATE BALANCES FOR EXPOSED ADDRESSES
-- ============================================================================
-- Purpose: Sum the unspent balances for all addresses with exposed public keys
-- Details:
--   - Joins unspent outputs with our list of exposed addresses
--   - Aggregates total balance per address
-- Output: For each exposed address with unspent outputs:
--   - address: The Bitcoin address that has exposed its public key
--   - balance: Total sum of all unspent outputs for this address (in satoshis)
final AS (
  SELECT
    u.address,
    SUM(u.value) AS balance
  FROM
    unspent u
  WHERE
    u.address IN (SELECT address FROM all_exposed_addresses)
  GROUP BY
    u.address
)

-- ============================================================================
-- SECTION 10: GENERATE FINAL RESULTS
-- ============================================================================
-- Purpose: Output addresses with exposed public keys that have non-zero balances
-- Details:
--   - Filters out zero-balance addresses
--   - Orders results by balance (highest first)
-- Output: For each at-risk address (ordered by balance):
--   - address: The Bitcoin address that has exposed its public key
--   - balance: Total unspent amount controlled by this address (in satoshis)
SELECT
  address,
  balance
FROM
  final
WHERE
  balance > 0
ORDER BY
  balance DESC;
