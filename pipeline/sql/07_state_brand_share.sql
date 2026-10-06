-- Brand revenue share by US state over the latest 12 complete months of the
-- store-level table. Scans pdi_gtin_month_store (~11 GB), the largest step.
CREATE OR REPLACE TABLE `{dst}.state_brand_share` AS
WITH window_end AS (
  SELECT MAX(month) AS m FROM `{src}.pdi_gtin_month_store`
),
gtin_brand AS (
  SELECT GTIN, ANY_VALUE(canonical_brand) AS brand
  FROM `{src}.pdi_energy_monthly_gtin`
  WHERE canonical_brand IS NOT NULL
  GROUP BY GTIN
),
stores AS (
  SELECT STORE_ID, ANY_VALUE(STATE) AS state FROM `{src}.pdi_stores` GROUP BY STORE_ID
),
sales AS (
  SELECT st.state, g.brand, s.STORE_ID, SUM(s.revenue) AS revenue, SUM(s.units) AS units
  FROM `{src}.pdi_gtin_month_store` s
  CROSS JOIN window_end w
  JOIN gtin_brand g USING (GTIN)
  JOIN stores st USING (STORE_ID)
  WHERE s.month > DATE_SUB(w.m, INTERVAL 12 MONTH) AND s.revenue > 0
  GROUP BY 1, 2, 3
),
by_state_brand AS (
  SELECT state, brand, SUM(revenue) AS revenue, SUM(units) AS units, COUNT(DISTINCT STORE_ID) AS stores_selling
  FROM sales GROUP BY 1, 2
),
by_state AS (
  SELECT state, COUNT(DISTINCT STORE_ID) AS state_stores FROM sales GROUP BY 1
)
SELECT
  b.state,
  b.brand,
  CAST(b.revenue AS FLOAT64) AS revenue,
  CAST(b.units AS FLOAT64) AS units,
  b.stores_selling,
  s.state_stores,
  SAFE_DIVIDE(b.stores_selling, s.state_stores) AS store_penetration,
  CAST(SAFE_DIVIDE(b.revenue, SUM(b.revenue) OVER (PARTITION BY b.state)) AS FLOAT64) AS revenue_share,
  CAST(SAFE_DIVIDE(b.revenue, b.stores_selling) AS FLOAT64) AS revenue_per_selling_store,
  (SELECT m FROM window_end) AS window_end_month
FROM by_state_brand b
JOIN by_state s USING (state)
WHERE b.state IS NOT NULL
