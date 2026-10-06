-- Monthly sales for energy drinks, energy shots and sports drinks from the PDI
-- convenience-store panel. The panel grew from ~400 stores (2016) to ~20k (2026),
-- so raw revenue trends mostly reflect panel growth; revenue_per_store is the
-- comparable trend measure. Months before 2019 (panel < 2k stores) are dropped,
-- and a trailing partial month (revenue < half the prior month) is flagged.
CREATE OR REPLACE TABLE `{dst}.category_monthly` AS
WITH seg AS (
  SELECT 'Energy Drinks' AS segment, month, revenue, units, txns, stores FROM `{src}.pdi_energy_drinks_monthly`
  UNION ALL
  SELECT 'Energy Shots', month, revenue, units, txns, stores FROM `{src}.pdi_energy_shots_monthly`
  UNION ALL
  SELECT 'Sports Drinks', month, revenue, units, txns, stores FROM `{src}.pdi_sports_drinks_monthly`
),
agg AS (
  SELECT
    segment,
    month,
    SUM(revenue) AS revenue,
    SUM(units) AS units,
    SUM(txns) AS transactions,
    -- Store count of the most widely distributed brand: a lower bound on stores
    -- carrying the segment, used as the per-store denominator.
    MAX(stores) AS selling_stores
  FROM seg
  WHERE month >= DATE '2019-01-01'
  GROUP BY segment, month
),
flagged AS (
  SELECT
    *,
    COALESCE(revenue >= 0.5 * LAG(revenue) OVER (PARTITION BY segment ORDER BY month), TRUE) AS is_complete_month
  FROM agg
)
SELECT
  f.segment,
  f.month,
  f.is_complete_month,
  f.revenue,
  f.units,
  f.transactions,
  f.selling_stores,
  SAFE_DIVIDE(f.revenue, f.selling_stores) AS revenue_per_store,
  SAFE_DIVIDE(f.units, f.selling_stores) AS units_per_store,
  SAFE_DIVIDE(f.revenue, f.units) AS avg_price_per_unit,
  SAFE_DIVIDE(f.revenue, f.transactions) AS revenue_per_transaction,
  SAFE_DIVIDE(f.revenue, p.revenue) - 1 AS revenue_yoy_pct,
  SAFE_DIVIDE(SAFE_DIVIDE(f.revenue, f.selling_stores), SAFE_DIVIDE(p.revenue, p.selling_stores)) - 1 AS revenue_per_store_yoy_pct,
  SAFE_DIVIDE(SAFE_DIVIDE(f.revenue, f.units), SAFE_DIVIDE(p.revenue, p.units)) - 1 AS avg_price_yoy_pct,
  s.consumer_confidence_index
FROM flagged f
LEFT JOIN flagged p
  ON p.segment = f.segment AND p.month = DATE_SUB(f.month, INTERVAL 12 MONTH)
LEFT JOIN `{src}.umich_consumer_sentiment` s
  ON s.month = f.month
