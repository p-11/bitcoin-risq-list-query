-- ======================
-- Bitcoin at Quantum Risk Query - OPTIMIZED VERSION
-- Using partitioned transactions table for massive cost reduction
-- ======================

-- ======================
-- USAGE EXAMPLES:
-- For first 100k blocks: SET cutoff_month = '2010-12-01', cutoff_block = 100000
-- For testing: SET cutoff_month = '2009-12-01', cutoff_block = 50000  
-- For full dataset: SET cutoff_month = '2024-12-01', cutoff_block = 900000
-- ======================

-- ======================
-- CONFIGURATION VARIABLES - Easy to modify!
-- ======================
DECLARE cutoff_month DATE DEFAULT '2011-01-01';        -- Partition filter (adjust for time range)
DECLARE cutoff_block INT64 DEFAULT 100000;            -- Block number filter (set high for full dataset)

-- ======================
-- TABLE DESTINATION - Update with your project/dataset!
-- ======================
CREATE OR REPLACE TABLE `your-project.your_dataset.your_table_name` AS

-- ======================
-- 1. Addresses with script types that only reveal pubkey WHEN spent
--    (excludes 'pubkey'; I will handle that separately)
-- ======================
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

-- ======================
-- 2. Inputs that spend those outputs
--    => actual "revealed" upon spending
-- ======================
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

-- ======================
-- 3. Addresses that definitely revealed a pubkey by spending
-- ======================
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

-- ======================
-- 4. Addresses that are 'pubkey' (P2PK) => exposed immediately
-- ======================
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

-- ======================
-- 5. Union the two sets of addresses => full set of "exposed" addresses
-- ======================
all_exposed_addresses AS (
  SELECT address FROM revealed_by_spend
  UNION DISTINCT
  SELECT address FROM p2pk_addresses
),

-- ======================
-- 6. All unspent outputs => using partitioned approach
--    We'll get unspent by finding outputs not in spent_details
-- ======================
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

-- ======================
-- 7. Sum balances for addresses in our full "exposed" set
-- ======================
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

-- ======================
-- 8. Return only those with >0 BTC, ordered DESC
-- ======================
SELECT
  address,
  balance
FROM
  final
WHERE
  balance > 0
ORDER BY
  balance DESC;
