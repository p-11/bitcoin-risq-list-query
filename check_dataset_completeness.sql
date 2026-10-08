-- ============================================================================
-- DATASET COMPLETENESS CHECK
-- ============================================================================
-- Purpose: Confirm that the public BigQuery Bitcoin dataset holds every block up
-- to the cutoff, exactly once, with all of its transactions. Run this before
-- btc_at_quantum_risk_query.sql, using the same cutoff values.
--
-- Why: the main query decides which outputs are unspent by looking for the
-- inputs that spend them. If a block is missing, its inputs are missing too, so
-- the coins they spent look unspent and balances come out too high. Deposits
-- made in the missing block are lost, so other balances come out too low.
-- Between July and mid-September 2025 the dataset was missing about 2,100
-- blocks, which was reported to have inflated the total by roughly 1M BTC.
--
-- Result: one row. `is_complete` must be TRUE before the main query's results
-- can be trusted. The other columns say what is wrong if it is not.
--
-- Cost: reads only block heights and transaction counts (roughly 10 GB for the
-- full chain).

-- CONFIGURATION VARIABLES (use the same values as the main query):
DECLARE cutoff_month DATE DEFAULT '2011-01-01';        -- Partition filter
DECLARE cutoff_block INT64 DEFAULT 100000;            -- Highest block to check

WITH block_coverage AS (
  SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT number) AS distinct_heights,
    MIN(number) AS min_height,
    MAX(number) AS max_height
  FROM
    `bigquery-public-data.crypto_bitcoin.blocks`
  WHERE
    timestamp_month <= cutoff_month
    AND number <= cutoff_block
),

tx_per_block AS (
  SELECT
    block_number,
    COUNT(*) AS tx_rows
  FROM
    `bigquery-public-data.crypto_bitcoin.transactions`
  WHERE
    block_timestamp_month <= cutoff_month
    AND block_number <= cutoff_block
  GROUP BY
    block_number
),

blocks_in_range AS (
  SELECT
    number,
    transaction_count
  FROM
    `bigquery-public-data.crypto_bitcoin.blocks`
  WHERE
    timestamp_month <= cutoff_month
    AND number <= cutoff_block
),

-- Blocks whose transaction rows don't match the block's transaction_count.
-- FULL JOIN also catches transactions whose block is missing from `blocks`.
tx_count_mismatches AS (
  SELECT
    COALESCE(b.number, t.block_number) AS height,
    IFNULL(b.transaction_count, 0) AS expected,
    IFNULL(t.tx_rows, 0) AS actual
  FROM
    blocks_in_range b
  FULL OUTER JOIN
    tx_per_block t
  ON
    t.block_number = b.number
  WHERE
    IFNULL(b.transaction_count, 0) != IFNULL(t.tx_rows, 0)
)

SELECT
  coverage.row_count = cutoff_block + 1
    AND coverage.distinct_heights = cutoff_block + 1
    AND coverage.min_height = 0
    AND coverage.max_height = cutoff_block
    AND (SELECT COUNT(*) FROM tx_count_mismatches) = 0 AS is_complete,
  cutoff_block + 1 - coverage.distinct_heights AS missing_heights,
  coverage.row_count - coverage.distinct_heights AS duplicate_height_rows,
  coverage.max_height,
  (SELECT COUNT(*) FROM tx_count_mismatches) AS blocks_with_wrong_tx_count,
  (SELECT ARRAY_AGG(STRUCT(height, expected, actual) ORDER BY height LIMIT 20)
     FROM tx_count_mismatches) AS example_mismatches
FROM
  block_coverage coverage;
