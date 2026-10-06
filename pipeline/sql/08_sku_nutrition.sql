-- Nutrition facts for PDI energy-drink SKUs, matched to USDA FoodData Central
-- branded foods by GTIN/UPC (leading zeros ignored). USDA nutrient values are
-- per 100 g/ml. Zero sugar = under 0.5 g sugar per 100 ml.
CREATE OR REPLACE TABLE `{dst}.sku_nutrition` AS
WITH usda AS (
  SELECT
    LTRIM(gtin_upc, '0') AS gtin_key,
    ANY_VALUE(brand_name) AS usda_brand,
    ANY_VALUE(description) AS description,
    AVG(total_sugars_g) AS sugars_g_per_100,
    AVG(added_sugars_g) AS added_sugars_g_per_100,
    AVG(energy_kcal) AS kcal_per_100,
    AVG(sodium_mg) AS sodium_mg_per_100
  FROM `{src}.usda_branded_foods`
  WHERE is_energy_drink AND is_latest_for_upc AND gtin_upc IS NOT NULL
  GROUP BY 1
),
pdi AS (
  SELECT GTIN, LTRIM(GTIN, '0') AS gtin_key, ANY_VALUE(canonical_brand) AS brand,
         SUM(revenue) AS revenue
  FROM `{src}.pdi_energy_monthly_gtin`
  GROUP BY GTIN
)
SELECT
  p.GTIN,
  p.brand,
  u.usda_brand,
  u.description,
  u.sugars_g_per_100,
  u.added_sugars_g_per_100,
  u.kcal_per_100,
  u.sodium_mg_per_100,
  u.sugars_g_per_100 < 0.5 AS is_zero_sugar,
  CAST(p.revenue AS FLOAT64) AS lifetime_revenue
FROM pdi p
JOIN usda u USING (gtin_key)
