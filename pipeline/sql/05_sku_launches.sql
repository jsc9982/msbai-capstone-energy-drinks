-- One row per energy-drink SKU launched inside the PDI window, with how far it
-- got in distribution 3/6/12 months after its first sale. SKUs already selling
-- in Jan 2019 are excluded (their true launch date is unknown).
CREATE OR REPLACE TABLE `{dst}.sku_launches` AS
WITH last_month AS (
  SELECT MAX(month) AS m FROM `{src}.pdi_sku_month_distribution`
),
sku AS (
  SELECT
    GTIN,
    ANY_VALUE(brand) AS brand,
    MIN(first_sale_month) AS launch_month,
    MAX(IF(months_since_first_sale = 3, numeric_dist, NULL)) AS numeric_dist_m3,
    MAX(IF(months_since_first_sale = 6, numeric_dist, NULL)) AS numeric_dist_m6,
    MAX(IF(months_since_first_sale = 12, numeric_dist, NULL)) AS numeric_dist_m12,
    MAX(IF(months_since_first_sale = 6, stores_selling, NULL)) AS stores_selling_m6,
    MAX(IF(months_since_first_sale = 12, stores_selling, NULL)) AS stores_selling_m12,
    MAX(IF(months_since_first_sale = 6, rev_per_selling_store, NULL)) AS rev_per_selling_store_m6,
    MAX(IF(months_since_first_sale = 6, avg_price_per_unit, NULL)) AS avg_price_m6,
    MAX(peak_stores) AS peak_stores,
    SUM(revenue) AS lifetime_revenue
  FROM `{src}.pdi_sku_month_distribution`
  GROUP BY GTIN
)
SELECT
  s.*,
  EXTRACT(YEAR FROM s.launch_month) AS launch_year,
  DATE_DIFF(l.m, s.launch_month, MONTH) >= 12 AS observed_12m,
  -- Still sold in at least one store 12 months after launch (NULL if not yet observable).
  IF(DATE_DIFF(l.m, s.launch_month, MONTH) >= 12, COALESCE(s.stores_selling_m12, 0) > 0, NULL) AS survived_12m
FROM sku s
CROSS JOIN last_month l
WHERE s.launch_month > DATE '2019-01-01'
