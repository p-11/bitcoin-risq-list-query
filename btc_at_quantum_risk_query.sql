-- ======================
-- 1. Addresses with script types that only reveal pubkey WHEN spent
--    (excludes 'pubkey'; I will handle that separately)
-- ======================
WITH potentially_exposed AS (
  SELECT
    o.transaction_hash,
    o.index,
    addr AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.outputs` o
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  WHERE
    o.type IN (
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
    `bigquery-public-data.crypto_bitcoin.inputs` i
  CROSS JOIN
    UNNEST(i.addresses) AS addr
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
    `bigquery-public-data.crypto_bitcoin.outputs` o
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  WHERE
    o.type = 'pubkey'
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
-- 6. All unspent outputs => standard approach
--    (i.spent_transaction_hash IS NULL means still unspent)
-- ======================
unspent AS (
  SELECT
    o.value,
    addr AS address
  FROM
    `bigquery-public-data.crypto_bitcoin.outputs` o
  CROSS JOIN
    UNNEST(o.addresses) AS addr
  LEFT JOIN
    `bigquery-public-data.crypto_bitcoin.inputs` i
  ON
    o.transaction_hash = i.spent_transaction_hash
    AND o.index = i.spent_output_index
  WHERE
    i.spent_transaction_hash IS NULL
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