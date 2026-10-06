-- Launch scorecard by brand: how many SKUs each brand launched and how well
-- they reached distribution (medians to resist outliers).
CREATE OR REPLACE TABLE `{dst}.sku_launch_summary` AS
SELECT
  brand,
  COUNT(*) AS skus_launched,
  COUNTIF(launch_year >= 2024) AS skus_launched_since_2024,
  COUNTIF(observed_12m) AS skus_observed_12m,
  SAFE_DIVIDE(COUNTIF(survived_12m), COUNTIF(observed_12m)) AS survival_rate_12m,
  APPROX_QUANTILES(numeric_dist_m6, 2)[OFFSET(1)] AS median_numeric_dist_m6,
  APPROX_QUANTILES(numeric_dist_m12, 2)[OFFSET(1)] AS median_numeric_dist_m12,
  APPROX_QUANTILES(rev_per_selling_store_m6, 2)[OFFSET(1)] AS median_rev_per_store_m6,
  SUM(lifetime_revenue) AS launched_sku_revenue
FROM `{dst}.sku_launches`
GROUP BY brand
