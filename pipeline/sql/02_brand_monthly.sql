-- Energy-drink sales by brand and month with parent company and share of the
-- month's category revenue. Only complete months from category_monthly are kept.
CREATE OR REPLACE TABLE `{dst}.brand_monthly` AS
WITH parents AS (
  SELECT canonical_brand, ANY_VALUE(parent_company) AS parent_company
  FROM `{src}.brand_crosswalk`
  WHERE source = 'pdi' AND canonical_brand IS NOT NULL
  GROUP BY canonical_brand
),
months AS (
  SELECT month FROM `{dst}.category_monthly`
  WHERE segment = 'Energy Drinks' AND is_complete_month
),
brand AS (
  SELECT
    b.month,
    COALESCE(b.canonical_brand, b.BRAND) AS brand,
    SUM(b.revenue) AS revenue,
    SUM(b.units) AS units,
    SUM(b.txns) AS transactions,
    MAX(b.stores) AS stores,
    MAX(b.gtins) AS gtins
  FROM `{src}.pdi_energy_drinks_monthly` b
  JOIN months USING (month)
  GROUP BY 1, 2
)
SELECT
  b.month,
  b.brand,
  COALESCE(p.parent_company, 'Other / unmapped') AS parent_company,
  b.revenue,
  b.units,
  b.transactions,
  b.stores,
  b.gtins,
  SAFE_DIVIDE(b.revenue, SUM(b.revenue) OVER (PARTITION BY b.month)) AS revenue_share,
  SAFE_DIVIDE(b.units, SUM(b.units) OVER (PARTITION BY b.month)) AS unit_share,
  SAFE_DIVIDE(b.revenue, b.units) AS avg_price_per_unit,
  SAFE_DIVIDE(b.revenue, b.stores) AS revenue_per_store,
  RANK() OVER (PARTITION BY b.month ORDER BY b.revenue DESC) AS revenue_rank
FROM brand b
LEFT JOIN parents p ON p.canonical_brand = b.brand
