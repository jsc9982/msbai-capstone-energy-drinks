-- One row per energy-drink SKU (GTIN) combining PDI sales and distribution, USDA
-- nutrition, Open Food Facts ingredients, ingredient Google Trends and brand
-- Google Trends. Column-by-column sources: docs/product_master_schema.md.
CREATE OR REPLACE TABLE `{dst}.product_master`
CLUSTER BY canonical_brand AS
WITH
-- Windows are anchored to the SKU table's own last month (it ends earlier than the
-- brand-level table: Dec 2025 vs Jun 2026).
last_month AS (
  SELECT MAX(month) AS m FROM `{src}.pdi_energy_monthly_gtin`
),

-- ---------------------------------------------------------------- sales (PDI)
sales AS (
  SELECT
    g.GTIN, g.month,
    ANY_VALUE(g.canonical_brand) AS canonical_brand,
    ANY_VALUE(g.brand_raw) AS brand_raw,
    ANY_VALUE(g.subcategory) AS subcategory,
    CAST(SUM(g.revenue) AS FLOAT64) AS revenue,
    CAST(SUM(g.units) AS FLOAT64) AS units,
    CAST(SUM(g.transactions) AS FLOAT64) AS transactions
  FROM `{src}.pdi_energy_monthly_gtin` g
  CROSS JOIN last_month l
  WHERE g.month <= l.m
  GROUP BY g.GTIN, g.month
),
sku_sales AS (
  SELECT
    s.GTIN,
    LPAD(LTRIM(REGEXP_REPLACE(s.GTIN, r'[^0-9]', ''), '0'), 14, '0') AS gtin14,
    ANY_VALUE(s.canonical_brand) AS canonical_brand,
    ANY_VALUE(s.brand_raw) AS brand_raw,
    ANY_VALUE(s.subcategory) AS subcategory,
    MIN(IF(s.revenue > 0, s.month, NULL)) AS first_sale_month,
    MAX(IF(s.revenue > 0, s.month, NULL)) AS last_sale_month,
    COUNTIF(s.revenue > 0) AS months_with_sales,
    SUM(s.revenue) AS revenue_total,
    SUM(s.units) AS units_total,
    SUM(s.transactions) AS transactions_total,
    SUM(IF(s.month > DATE_SUB(l.m, INTERVAL 12 MONTH), s.revenue, 0)) AS revenue_last_12m,
    SUM(IF(s.month > DATE_SUB(l.m, INTERVAL 12 MONTH), s.units, 0)) AS units_last_12m,
    SUM(IF(s.month <= DATE_SUB(l.m, INTERVAL 12 MONTH) AND s.month > DATE_SUB(l.m, INTERVAL 24 MONTH), s.revenue, 0)) AS revenue_prior_12m,
    LOGICAL_OR(s.month = l.m AND s.revenue > 0) AS is_active,
    ARRAY_AGG(STRUCT(s.month, s.revenue, s.units, s.transactions) ORDER BY s.month) AS sales_monthly
  FROM sales s
  CROSS JOIN last_month l
  GROUP BY s.GTIN
),

-- ------------------------------------------------------- attributes (PDI)
attrs AS (
  SELECT
    GTIN,
    ANY_VALUE(PRODUCT_DESCRIPTION) AS product_description,
    ANY_VALUE(MANUFACTURER) AS manufacturer,
    ANY_VALUE(MANUFACTURER_PARENT) AS manufacturer_parent,
    ANY_VALUE(CATEGORY) AS category,
    ANY_VALUE(PRODUCT_TYPE) AS product_type,
    ANY_VALUE(SUB_PRODUCT_TYPE) AS sub_product_type,
    ANY_VALUE(FLAVOR) AS flavor,
    ANY_VALUE(PACKAGE) AS package,
    ANY_VALUE(PACK_SIZE) AS pack_size,
    ANY_VALUE(UNIT_SIZE) AS unit_size,
    MIN(CREATED_AT) AS pdi_created_at
  FROM `{src}.pdi_master_gtin`
  GROUP BY GTIN
),
parents AS (
  SELECT canonical_brand, ANY_VALUE(parent_company) AS parent_company
  FROM `{src}.brand_crosswalk`
  WHERE source = 'pdi' AND canonical_brand IS NOT NULL
  GROUP BY canonical_brand
),

-- ---------------------------------------------- distribution & launch (PDI)
dist AS (
  SELECT
    GTIN,
    MIN(first_sale_month) AS launch_month,
    MAX(peak_stores) AS peak_stores,
    MAX(month) AS dist_last_month,
    ARRAY_AGG(STRUCT(stores_selling, numeric_dist, dist_frac_of_peak, n_states) ORDER BY month DESC LIMIT 1)[OFFSET(0)] AS latest,
    MAX(IF(months_since_first_sale = 6, numeric_dist, NULL)) AS numeric_dist_m6,
    MAX(IF(months_since_first_sale = 12, numeric_dist, NULL)) AS numeric_dist_m12,
    MAX(IF(months_since_first_sale = 12, stores_selling, NULL)) AS stores_selling_m12
  FROM `{src}.pdi_sku_month_distribution`
  GROUP BY GTIN
),

-- --------------------------------------------------- geography (PDI stores)
geo_state AS (
  SELECT s.GTIN, st.state, CAST(SUM(s.revenue) AS FLOAT64) AS revenue, COUNT(DISTINCT s.STORE_ID) AS stores
  FROM `{src}.pdi_gtin_month_store` s
  JOIN (SELECT STORE_ID, ANY_VALUE(STATE) AS state FROM `{src}.pdi_stores` GROUP BY STORE_ID) st USING (STORE_ID)
  WHERE s.revenue > 0
    AND s.month > DATE_SUB((SELECT MAX(month) FROM `{src}.pdi_gtin_month_store`), INTERVAL 12 MONTH)
  GROUP BY s.GTIN, st.state
),
geo AS (
  SELECT
    GTIN,
    SUM(stores) AS stores_sold_last_12m,  -- each store is in one state, so this is a distinct count
    COUNT(DISTINCT state) AS states_sold_last_12m,
    ARRAY_AGG(STRUCT(state, revenue) ORDER BY revenue DESC LIMIT 1)[OFFSET(0)] AS top,
    SUM(revenue) AS geo_revenue
  FROM geo_state
  GROUP BY GTIN
),

-- --------------------------------------------------------- nutrition (USDA)
usda AS (
  SELECT
    LPAD(LTRIM(REGEXP_REPLACE(gtin_upc, r'[^0-9]', ''), '0'), 14, '0') AS gtin14,
    ARRAY_AGG(STRUCT(
      fdc_id, description, brand_owner, branded_food_category,
      NULLIF(TRIM(ingredients), '') AS ingredients,
      serving_size, serving_size_unit, energy_kcal, total_sugars_g, added_sugars_g,
      sodium_mg, carbohydrate_g, protein_g, caffeine_per_serving_mg, discontinued_date
    ) ORDER BY publication_date DESC LIMIT 1)[OFFSET(0)] AS u
  FROM `{src}.usda_branded_foods`
  WHERE is_energy_drink AND is_latest_for_upc AND gtin_upc IS NOT NULL
  GROUP BY 1
),

-- ------------------------------------------------- Open Food Facts (clean)
off AS (
  SELECT
    LPAD(LTRIM(REGEXP_REPLACE(product_id, r'[^0-9]', ''), '0'), 14, '0') AS gtin14,
    product_id, product_name, brand, brands_tags, categories_tags,
    NULLIF(TRIM(ingredients_text), '') AS ingredients_text,
    ingredients_tags, countries, labels_tags, serving_size, serving_size_value, serving_size_unit,
    energy, sugar, fat, protein, salt, caffeine, nutrition_grade, last_modified
  FROM `{clean}.energy_drinks`
),
off_ingr AS (
  SELECT product_id,
         COUNT(*) AS ingredient_count,
         ARRAY_AGG(ingredient_name ORDER BY rank) AS ingredients_ranked
  FROM (
    SELECT product_id, ingredient_name, MIN(ingredient_rank) AS rank
    FROM `{clean}.product_ingredients`
    GROUP BY product_id, ingredient_name
  )
  GROUP BY product_id
),

-- ------------------------------------------------ base row per SKU, joined
base AS (
  SELECT
    s.*,
    a.* EXCEPT (GTIN),
    p.parent_company,
    d.* EXCEPT (GTIN),
    g.* EXCEPT (GTIN),
    u.u,
    o.* EXCEPT (gtin14),
    oi.ingredient_count AS off_ingredient_count,
    oi.ingredients_ranked AS off_ingredients_ranked,
    COALESCE(o.ingredients_text, u.u.ingredients) AS ingredients,
    CASE WHEN o.ingredients_text IS NOT NULL THEN 'open_food_facts'
         WHEN u.u.ingredients IS NOT NULL THEN 'usda' END AS ingredients_source
  FROM sku_sales s
  LEFT JOIN attrs a USING (GTIN)
  LEFT JOIN parents p USING (canonical_brand)
  LEFT JOIN dist d USING (GTIN)
  LEFT JOIN geo g USING (GTIN)
  LEFT JOIN usda u USING (gtin14)
  LEFT JOIN off o USING (gtin14)
  LEFT JOIN off_ingr oi ON oi.product_id = o.product_id
),

-- ----------------------------------------- ingredient Google Trends (clean)
term_stats AS (
  SELECT
    t.search_term,
    AVG(IF(t.week_start_date > DATE_SUB(w.mx, INTERVAL 52 WEEK), t.interest_score, NULL)) AS interest_last_52w,
    AVG(IF(t.week_start_date <= DATE_SUB(w.mx, INTERVAL 52 WEEK)
           AND t.week_start_date > DATE_SUB(w.mx, INTERVAL 104 WEEK), t.interest_score, NULL)) AS interest_prior_52w,
    MIN(t.interest_score) < 100 AS has_signal  -- terms stuck at 100 every week carry no information
  FROM `{clean}.google_trends` t
  CROSS JOIN (SELECT MAX(week_start_date) AS mx FROM `{clean}.google_trends`) w
  GROUP BY t.search_term
),
-- Ingredients found in nearly every product; excluded from the product-level averages.
generic_terms AS (
  SELECT term FROM UNNEST([
    'water', 'carbonated water', 'flavouring', 'natural flavouring', 'flavoring', 'natural flavoring',
    'vitamins', 'minerals', 'sodium', 'salt', 'sugar', 'added sugar', 'colour', 'color',
    'acid', 'acidity regulator', 'preservative', 'sweetener', 'e330'
  ]) AS term
),
-- Path 1: Open Food Facts parsed ingredient list.
sku_terms_off AS (
  SELECT b.GTIN, pi.ingredient_name AS ingredient, ts.search_term, 'open_food_facts_ingredient' AS match_method
  FROM base b
  JOIN `{clean}.product_ingredients` pi ON pi.product_id = b.product_id
  JOIN term_stats ts ON ts.search_term = LOWER(REPLACE(pi.ingredient_name, '-', ' '))
),
-- Path 2: SKUs without a parsed list (mostly USDA-only) - find terms inside the ingredient text.
sku_terms_text AS (
  SELECT b.GTIN, ts.search_term AS ingredient, ts.search_term, 'ingredient_text_match' AS match_method
  FROM base b
  CROSS JOIN term_stats ts
  WHERE b.ingredients IS NOT NULL
    AND b.GTIN NOT IN (SELECT GTIN FROM sku_terms_off)
    AND REGEXP_CONTAINS(ts.search_term, r'^[a-z0-9 ]+$')
    AND REGEXP_CONTAINS(LOWER(b.ingredients), CONCAT(r'(^|[^a-z0-9])', ts.search_term, r'($|[^a-z0-9])'))
),
sku_terms AS (
  SELECT DISTINCT * FROM (SELECT * FROM sku_terms_off UNION ALL SELECT * FROM sku_terms_text)
),
ingredient_trends AS (
  SELECT
    st.GTIN,
    ARRAY_AGG(STRUCT(
      st.ingredient, st.search_term, st.match_method,
      ts.interest_last_52w, ts.interest_prior_52w,
      SAFE_DIVIDE(ts.interest_last_52w, ts.interest_prior_52w) - 1 AS interest_yoy_pct,
      ts.has_signal,
      gt.term IS NOT NULL AS is_generic
    ) ORDER BY st.search_term) AS ingredient_trends,
    COUNTIF(ts.has_signal) AS trend_terms_matched,
    AVG(IF(ts.has_signal AND gt.term IS NULL,
           SAFE_DIVIDE(ts.interest_last_52w, ts.interest_prior_52w) - 1, NULL)) AS trend_interest_yoy_avg_pct,
    COUNTIF(ts.has_signal AND gt.term IS NULL
            AND SAFE_DIVIDE(ts.interest_last_52w, ts.interest_prior_52w) - 1 > 0.20) AS trend_rising_ingredients,
    ARRAY_AGG(IF(ts.has_signal AND gt.term IS NULL
                 AND ts.interest_prior_52w > 0, st.search_term, NULL) IGNORE NULLS
              ORDER BY SAFE_DIVIDE(ts.interest_last_52w, ts.interest_prior_52w) DESC LIMIT 1)[SAFE_OFFSET(0)] AS trend_top_rising_ingredient,
    LOGICAL_OR(ts.has_signal) AS trend_has_signal,
    ANY_VALUE(st.match_method) AS trend_match_method
  FROM sku_terms st
  JOIN term_stats ts USING (search_term)
  LEFT JOIN generic_terms gt ON gt.term = st.search_term
  GROUP BY st.GTIN
),

-- -------------------------------------------------- brand Google Trends
brand_trends AS (
  SELECT
    b.canonical_brand,
    ANY_VALUE(b.search_term) AS search_term,
    AVG(IF(b.week_start_date > DATE_SUB(w.mx, INTERVAL 52 WEEK), b.interest_score, NULL)) AS interest_last_52w,
    AVG(IF(b.week_start_date <= DATE_SUB(w.mx, INTERVAL 52 WEEK)
           AND b.week_start_date > DATE_SUB(w.mx, INTERVAL 104 WEEK), b.interest_score, NULL)) AS interest_prior_52w,
    MAX(b.interest_score) AS interest_peak,
    ARRAY_AGG(STRUCT(b.week_start_date, b.interest_score) ORDER BY b.week_start_date) AS weekly
  FROM `{dst}.google_trends_brands` b
  CROSS JOIN (SELECT MAX(week_start_date) AS mx FROM `{dst}.google_trends_brands`) w
  GROUP BY b.canonical_brand
),

-- ---------------------------------------------- brand market context
xw AS (
  SELECT source, raw_label, ANY_VALUE(canonical_brand) AS canonical_brand
  FROM `{src}.brand_crosswalk` GROUP BY 1, 2
),
passport AS (
  SELECT
    COALESCE(x.canonical_brand, p.brand) AS canonical_brand,
    MAX(IF(p.measure = 'retail_value_rsp_pct', p.share_pct, NULL)) AS passport_value_share_pct,
    MAX(IF(p.measure = 'total_volume_pct', p.share_pct, NULL)) AS passport_volume_share_pct,
    ANY_VALUE(p.year) AS passport_share_year
  FROM `{src}.passport_brand_shares` p
  LEFT JOIN xw x ON x.source = 'passport' AND x.raw_label = p.brand
  WHERE p.year = (SELECT MAX(year) FROM `{src}.passport_brand_shares`)
    AND p.brand NOT IN ('Total', 'Others')
  GROUP BY 1
),
mintel AS (
  SELECT
    COALESCE(x.canonical_brand, m.brand) AS canonical_brand,
    MAX(m.share_2025_pct) AS mintel_mulo_share_2025_pct,
    MAX(m.share_2026_pct) AS mintel_mulo_share_2026_pct,
    MAX(m.sales_change_pct) AS mintel_mulo_sales_change_pct
  FROM `{src}.mintel_mulo_brand_sales` m
  LEFT JOIN xw x ON x.source = 'mintel' AND x.raw_label = m.brand
  WHERE NOT COALESCE(m.is_total_row, FALSE) AND m.brand NOT IN ('Others', 'Private label')
  GROUP BY 1
)

SELECT
  -- A. identity & attributes
  b.GTIN AS gtin,
  b.gtin14,
  b.product_description,
  b.brand_raw,
  b.canonical_brand,
  b.parent_company,
  b.manufacturer,
  b.manufacturer_parent,
  b.category,
  b.subcategory,
  b.product_type,
  b.sub_product_type,
  b.flavor,
  b.package,
  b.pack_size,
  b.unit_size,
  CASE
    WHEN REGEXP_CONTAINS(UPPER(b.unit_size), r'OZ') THEN SAFE_CAST(REGEXP_EXTRACT(b.unit_size, r'([0-9]*\.?[0-9]+)') AS FLOAT64)
    WHEN REGEXP_CONTAINS(UPPER(b.unit_size), r'ML') THEN SAFE_CAST(REGEXP_EXTRACT(b.unit_size, r'([0-9]*\.?[0-9]+)') AS FLOAT64) / 29.5735
  END AS unit_size_oz,
  b.pdi_created_at,

  -- B. revenue & sales (PDI c-store panel)
  b.first_sale_month,
  b.last_sale_month,
  b.months_with_sales,
  b.revenue_total,
  b.units_total,
  b.transactions_total,
  b.revenue_last_12m,
  b.units_last_12m,
  b.revenue_prior_12m,
  SAFE_DIVIDE(b.revenue_last_12m, b.revenue_prior_12m) - 1 AS revenue_yoy_pct,
  SAFE_DIVIDE(b.revenue_last_12m, b.units_last_12m) AS avg_price_per_unit_last_12m,
  SAFE_DIVIDE(b.revenue_last_12m, SUM(b.revenue_last_12m) OVER (PARTITION BY b.canonical_brand)) AS revenue_share_of_brand_last_12m,
  RANK() OVER (ORDER BY b.revenue_last_12m DESC) AS revenue_rank_last_12m,
  b.sales_monthly,

  -- C. distribution & launch
  b.launch_month,
  b.launch_month > DATE '2019-01-01' AS is_launched_in_window,
  b.peak_stores,
  b.latest.stores_selling AS stores_selling_latest,
  b.latest.numeric_dist AS numeric_dist_latest,
  b.numeric_dist_m6,
  b.numeric_dist_m12,
  b.latest.dist_frac_of_peak AS dist_frac_of_peak_latest,
  b.latest.n_states AS n_states_latest,
  IF(DATE_DIFF(b.dist_last_month, b.launch_month, MONTH) >= 12, COALESCE(b.stores_selling_m12, 0) > 0, NULL) AS survived_12m,

  -- D. geography
  b.stores_sold_last_12m,
  b.states_sold_last_12m,
  b.top.state AS top_state,
  SAFE_DIVIDE(b.top.revenue, b.geo_revenue) AS top_state_revenue_share,

  -- E. USDA nutrition (per 100 g/ml unless noted)
  b.u.fdc_id AS usda_fdc_id,
  b.u.description AS usda_description,
  b.u.brand_owner AS usda_brand_owner,
  b.u.branded_food_category AS usda_food_category,
  b.u.ingredients AS usda_ingredients,
  b.u.serving_size,
  b.u.serving_size_unit,
  b.u.energy_kcal AS kcal_per_100,
  b.u.total_sugars_g AS sugars_g_per_100,
  b.u.added_sugars_g AS added_sugars_g_per_100,
  b.u.sodium_mg AS sodium_mg_per_100,
  b.u.carbohydrate_g AS carbohydrate_g_per_100,
  b.u.protein_g AS protein_g_per_100,
  b.u.caffeine_per_serving_mg AS caffeine_mg_per_serving_usda,
  COALESCE(b.u.total_sugars_g, b.sugar) < 0.5 AS is_zero_sugar,
  b.u.discontinued_date AS usda_discontinued_date,

  -- F. Open Food Facts
  b.product_id AS off_product_id,
  b.product_name AS off_product_name,
  b.brand AS off_brand,
  b.brands_tags AS off_brands_tags,
  b.categories_tags AS off_categories_tags,
  b.ingredients_text AS off_ingredients_text,
  b.ingredients_tags AS off_ingredients_tags,
  b.countries AS off_countries,
  b.labels_tags AS off_labels_tags,
  b.serving_size AS off_serving_size,
  b.serving_size_value AS off_serving_size_value,
  b.serving_size_unit AS off_serving_size_unit,
  b.energy AS off_kcal_per_100,
  b.sugar AS off_sugars_g_per_100,
  b.fat AS off_fat_g_per_100,
  b.protein AS off_protein_g_per_100,
  b.salt AS off_salt_g_per_100,
  b.caffeine AS off_caffeine_raw,
  CASE WHEN b.caffeine BETWEEN 0.001 AND 0.1 THEN b.caffeine * 1000
       WHEN b.caffeine BETWEEN 1 AND 100 THEN b.caffeine END AS off_caffeine_mg_per_100,
  b.nutrition_grade AS off_nutrition_grade,
  b.last_modified AS off_last_modified,
  b.off_ingredient_count,
  b.off_ingredients_ranked,

  -- G. unified ingredients
  b.ingredients,
  b.ingredients_source,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'caffeine') AS has_caffeine,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'taurine') AS has_taurine,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'sucralose') AS has_sucralose,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'aspartame') AS has_aspartame,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'erythritol') AS has_erythritol,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'stevia|rebaudioside') AS has_stevia,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'guaran') AS has_guarana,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'ginseng') AS has_ginseng,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'beta[- ]?alanine') AS has_beta_alanine,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'green tea') AS has_green_tea,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'l[- ]?theanine') AS has_l_theanine,
  REGEXP_CONTAINS(LOWER(b.ingredients), r'electrolyte|potassium') AS has_electrolytes,

  -- H. ingredient Google Trends
  it.ingredient_trends,
  COALESCE(it.trend_terms_matched, 0) AS trend_terms_matched,
  it.trend_interest_yoy_avg_pct,
  it.trend_rising_ingredients,
  it.trend_top_rising_ingredient,
  it.trend_has_signal,
  it.trend_match_method,

  -- H2. brand Google Trends [brand]
  bt.search_term AS brand_trends_search_term,
  bt.interest_last_52w AS brand_trends_interest_last_52w,
  bt.interest_prior_52w AS brand_trends_interest_prior_52w,
  SAFE_DIVIDE(bt.interest_last_52w, bt.interest_prior_52w) - 1 AS brand_trends_interest_yoy_pct,
  bt.interest_peak AS brand_trends_interest_peak,
  bt.weekly AS brand_trends_weekly,

  -- I. market context [brand]
  pp.passport_value_share_pct,
  pp.passport_volume_share_pct,
  pp.passport_share_year,
  mm.mintel_mulo_share_2025_pct,
  mm.mintel_mulo_share_2026_pct,
  mm.mintel_mulo_sales_change_pct,
  SUM(b.revenue_last_12m) OVER (PARTITION BY b.canonical_brand) AS brand_revenue_last_12m,
  COUNT(*) OVER (PARTITION BY b.canonical_brand) AS brand_sku_count,

  -- J. data-quality flags
  b.u.fdc_id IS NOT NULL AS has_usda_match,
  b.product_id IS NOT NULL AS has_off_match,
  b.ingredients IS NOT NULL AS has_ingredients,
  COALESCE(it.trend_terms_matched, 0) > 0 AS has_ingredient_trends,
  bt.canonical_brand IS NOT NULL AS has_brand_trends,
  b.is_active
FROM base b
LEFT JOIN ingredient_trends it USING (GTIN)
LEFT JOIN brand_trends bt USING (canonical_brand)
LEFT JOIN passport pp USING (canonical_brand)
LEFT JOIN mintel mm USING (canonical_brand)
