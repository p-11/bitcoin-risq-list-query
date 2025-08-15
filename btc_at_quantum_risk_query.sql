-- ============================================================================
-- QUERY OVERVIEW
-- ============================================================================
-- Purpose: Identify Bitcoin addresses with exposed public keys and their balances
-- Output: List of quantum-vulnerable addresses and their unspent balances
--
-- Performance Note: This query uses table partitioning on block_timestamp_month
-- to reduce the amount of data scanned and query costs.

-- ============================================================================
-- USAGE EXAMPLES AND CONFIGURATION
-- ============================================================================
-- USAGE SCENARIOS:
--
--   1. Initial Analysis (First 100k blocks):
--      SET cutoff_month = '2011-01-01', cutoff_block = 100000
--
--   2. Full Dataset Analysis (as of August 2025):
--      SET cutoff_month = '2025-12-12', cutoff_block = 950000
--
-- CONFIGURATION VARIABLES:
DECLARE cutoff_month DATE DEFAULT '2011-01-01';        -- Partition filter (adjust for time range)
DECLARE cutoff_block INT64 DEFAULT 100000;            -- Block number filter (set high for full dataset)

-- ============================================================================
-- OUTPUT TABLE CONFIGURATION
-- ============================================================================
-- Purpose: Define the destination table for query results
-- Note: Update the table reference below with your specific project and dataset
CREATE OR REPLACE TABLE `your-project.your_dataset.your_table_name` AS

-- ============================================================================
-- IDENTIFY ADDRESSES POTENTIALLY EXPOSED BY ADDRESS REUSE
-- ============================================================================
-- Purpose: Find addresses that use script types requiring pubkey revelation on spend
-- Details: 
--   - Includes address types: P2PKH, P2WPKH, P2SH, P2WSH.
--   - Only considers transactions up to specified cutoff block/month
-- Output: For each qualifying output:
--   - transaction_hash: Hash of the transaction containing the output
--   - index: Position of the output in the transaction (zero-based)
--   - address: The Bitcoin address associated with the output
WITH addresses_potentially_exposed_on_spend AS (
  SELECT
    transaction.hash AS transaction_hash,
    output_index AS index,
    output_address AS address,
    output.type AS script_type
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` transaction
  CROSS JOIN
    UNNEST(transaction.outputs) AS output WITH OFFSET AS output_index
  CROSS JOIN
    UNNEST(output.addresses) AS output_address
  WHERE
    transaction.block_timestamp_month <= cutoff_month
    AND transaction.block_number <= cutoff_block
    AND output.type IN (
      'pubkeyhash',
      'witness_v0_keyhash',
      'witness_v0_scripthash',
      'witness_unknown',
      'scripthash'
    )
),

-- ============================================================================
-- IDENTIFY ALL SPENT OUTPUTS
-- ============================================================================
-- Purpose: Identify all spent outputs
-- Details:
--   - Links spending transactions to their corresponding inputs
--   - Maintains the same cutoff constraints for consistency
-- Output: For each spent output:
--   - spent_transaction_hash: Hash of the transaction being spent
--   - spent_output_index: Index of the output being spent
--   - spending_address: Address that spent the output
spent_outputs AS (
  SELECT
    input.spent_transaction_hash AS spent_transaction_hash,
    input.spent_output_index AS spent_output_index,
    input_address AS spending_address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` transaction
  CROSS JOIN
    UNNEST(transaction.inputs) AS input
  CROSS JOIN
    UNNEST(input.addresses) AS input_address
  WHERE
    transaction.block_timestamp_month <= cutoff_month
    AND transaction.block_number <= cutoff_block
),

-- ============================================================================
-- IDENTIFY CONFIRMED ADDRESSES THAT EXPOSED THEIR PUBLIC KEY VIA SPENDING
-- ============================================================================
-- Purpose: Find all addresses that have definitely exposed their public keys
-- Details:
--   - Each Bitcoin address corresponds to exactly one public key
--   - Any spend from an address reveals its public key
--   - Once revealed, the public key is exposed for all outputs of that address
--   - Uses DISTINCT to eliminate duplicate address entries
-- Output: For each exposed address:
--   - address: The Bitcoin address that has revealed its public key through any spend
addresses_exposed_by_spend AS (
  SELECT DISTINCT
    potential.address,
    potential.script_type
  FROM
    addresses_potentially_exposed_on_spend potential
  JOIN
    spent_outputs spent
  ON
    potential.transaction_hash = spent.spent_transaction_hash
    AND potential.index = spent.spent_output_index
),

-- ============================================================================
-- IDENTIFY ADDRESSES WITH PUBLIC KEYS IN OUTPUT SCRIPTS
-- ============================================================================
-- Purpose: Find addresses from scripts that expose public keys in the output (no spend needed)
-- Details:
--   - Includes three script types that expose keys immediately:
--     1. P2PK (Pay to Public Key)
--     2. P2MS (Bare Multi-Signature)
--     3. P2TR (Pay to Taproot)
--   - These addresses are quantum-vulnerable from the moment of creation
--   - Uses same cutoff constraints as other sections
-- Output: For each output with exposed public key:
--   - address: The Bitcoin address derived from the exposed public key
--   - Note: For P2PK and P2MS, addresses are shown in P2PKH format since these
--     script types don't have their own address format.
addresses_exposed_by_script_type AS (
  SELECT DISTINCT
    output_address AS address,
    output.type AS script_type
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` transaction
  CROSS JOIN
    UNNEST(transaction.outputs) AS output
  CROSS JOIN
    UNNEST(output.addresses) AS output_address
  WHERE
    transaction.block_timestamp_month <= cutoff_month
    AND transaction.block_number <= cutoff_block
    AND output.type IN (
      'pubkey',
      'multisig',
      'witness_v1_taproot'
    )
),

-- ============================================================================
-- COMBINE ALL EXPOSED ADDRESSES
-- ============================================================================
-- Purpose: Create a complete set of all addresses that have exposed public keys
-- Details:
--   - Combines addresses from both spend revelation and quantum-vulnerable script types
--   - Uses UNION DISTINCT to ensure no duplicate addresses
--   - Creates final reference list for balance calculation
-- Output: For each unique exposed address:
--   - address: The Bitcoin address that has exposed its public key (either through spending or P2PK)
quantum_vulnerable_addresses AS (
  SELECT address, script_type FROM addresses_exposed_by_spend
  UNION DISTINCT
  SELECT address, script_type FROM addresses_exposed_by_script_type
),

-- ============================================================================
-- IDENTIFY ALL UNSPENT OUTPUTS
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
    transaction.hash AS transaction_hash,
    output_index AS output_index,
    output.value,
    output_address AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions` transaction
  CROSS JOIN
    UNNEST(transaction.outputs) AS output WITH OFFSET AS output_index
  CROSS JOIN
    UNNEST(output.addresses) AS output_address
  WHERE
    transaction.block_timestamp_month <= cutoff_month
    AND transaction.block_number <= cutoff_block
),

unspent_outputs AS (
  SELECT
    outputs.value,
    outputs.address
  FROM
    all_outputs outputs
  LEFT JOIN
    spent_outputs spent
    ON  outputs.transaction_hash = spent.spent_transaction_hash
    AND outputs.output_index = spent.spent_output_index
  WHERE
    spent.spent_transaction_hash IS NULL
),

-- ============================================================================
-- CALCULATE BALANCES FOR EXPOSED ADDRESSES
-- ============================================================================
-- Purpose: Sum the unspent balances for all addresses with exposed public keys
-- Details:
--   - Joins unspent outputs with our list of exposed addresses
--   - Aggregates total balance per address
-- Output: For each exposed address with unspent outputs:
--   - address: The Bitcoin address that has exposed its public key
--   - balance: Total sum of all unspent outputs for this address (in satoshis)
quantum_vulnerable_addresses_with_metadata AS (
  SELECT
    unspent.address,
    SUM(unspent.value) AS balance,
    -- Note on final `script_type` selection while aggregating results into final
    -- list of addresses:
    -- A single P2PKH-encoded address can in theory appear in multiple categories
    -- because BigQuery encodes P2PK and P2MS outputs using their P2PKH address
    -- equivalent. Hence, a single address could be labelled quantum-vulnerable due to
    -- both P2PKH spends and P2PK/P2MS usage. Since both script types are equally
    -- valid indicators of quantum vulnerability, we arbitrarily select one
    -- `script_type` per address using ARRAY_AGG/LIMIT with alphabetical ordering.
    -- The alphabetical ordering has no special meaning; it's just a stable way to pick one.
    qva_map.script_type
  FROM
    unspent_outputs AS unspent
  JOIN (
    SELECT
      address,
      ARRAY_AGG(script_type ORDER BY script_type LIMIT 1)[OFFSET(0)] AS script_type
    FROM quantum_vulnerable_addresses
    GROUP BY address
  ) AS qva_map
  ON unspent.address = qva_map.address
  GROUP BY
    unspent.address,
    qva_map.script_type
)

-- ============================================================================
-- GENERATE FINAL RESULTS
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
    balance,
    script_type
FROM
    quantum_vulnerable_addresses_with_metadata
WHERE
    balance > 0
ORDER BY
    balance DESC;