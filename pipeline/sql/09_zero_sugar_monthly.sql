-- Zero-sugar share of energy-drink revenue over time, among SKUs with USDA
-- nutrition data. match_coverage is the share of total revenue that could be
-- classified; read the trend alongside it.
CREATE OR REPLACE TABLE `{dst}.zero_sugar_monthly` AS
WITH months AS (
  SELECT month FROM `{dst}.category_monthly` WHERE segment = 'Energy Drinks' AND is_complete_month
)
SELECT
  g.month,
  CAST(SUM(g.revenue) AS FLOAT64) AS revenue,
  CAST(SUM(IF(n.GTIN IS NOT NULL, g.revenue, 0)) AS FLOAT64) AS matched_revenue,
  CAST(SUM(IF(n.is_zero_sugar, g.revenue, 0)) AS FLOAT64) AS zero_sugar_revenue,
  CAST(SAFE_DIVIDE(SUM(IF(n.GTIN IS NOT NULL, g.revenue, 0)), SUM(g.revenue)) AS FLOAT64) AS match_coverage,
  CAST(SAFE_DIVIDE(SUM(IF(n.is_zero_sugar, g.revenue, 0)), SUM(IF(n.GTIN IS NOT NULL, g.revenue, 0))) AS FLOAT64) AS zero_sugar_share
FROM `{src}.pdi_energy_monthly_gtin` g
JOIN months USING (month)
LEFT JOIN `{dst}.sku_nutrition` n ON n.GTIN = g.GTIN
GROUP BY g.month
