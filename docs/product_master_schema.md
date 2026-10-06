# Product master dataset: schema and source map

**Target table:** `msbai-capstone-energy-drinks.energy_drinks_analytics.product_master`
**Grain:** one row per energy-drink SKU (GTIN / UPC barcode).
**Universe:** every GTIN in `energy_drinks.pdi_energy_monthly_gtin` (about 2,176 SKUs, all
subcategory "Energy Drinks"), so every row has sales. Other sources are LEFT JOINed onto it.

Dataset shorthand used below:

| Shorthand | Full BigQuery path | Status |
|---|---|---|
| `ed` | `msbai-capstone-energydrinks.energy_drinks` | Schemas verified (queried 2026-10-06) |
| `clean` | `msbai-dwd-jsc9982.clean` | Schemas verified (queried 2026-10-06). Tables: `energy_drinks` (Open Food Facts products, 4,931 rows), `product_ingredients` (one row per product × ingredient, 92,984 rows), `google_trends` (search term × week, 113,184 rows) |

Both datasets are in location `US`, so they can be joined in one query.

---

## 1. How the sources fit together

```
                         ┌──────────────────── join key: gtin14 (SKU level) ────────────────────┐
ed.pdi_energy_monthly_gtin ──┬── ed.pdi_master_gtin            (product attributes)
  (universe + revenue)       ├── ed.pdi_sku_month_distribution (store distribution, launch)
                             ├── ed.pdi_gtin_month_store       (state footprint)
                             ├── ed.usda_branded_foods         (nutrition + USDA ingredient text)
                             └── clean.energy_drinks           (Open Food Facts: ingredients, scores)
                                    └── clean.product_ingredients (one row per ingredient)
                                           └── clean.google_trends  (join: ingredient name = search_term)
                         ┌──────────────────── join key: canonical_brand (brand level) ─────────┐
                             ├── ed.brand_crosswalk            (brand → parent company)
                             ├── ed.passport_brand_shares      (all-channel share)
                             └── ed.mintel_mulo_brand_sales    (MULO share)
```

### Join keys

**`gtin14`, the SKU key.** Each source stores barcodes differently: PDI `GTIN` (14 digits,
zero-padded), USDA `gtin_upc`, and Open Food Facts `clean.energy_drinks.product_id` (8–22 digits,
all numeric). Normalize all of them the same way:

```sql
LPAD(LTRIM(REGEXP_REPLACE(barcode, r'[^0-9]', ''), '0'), 14, '0') AS gtin14
```

Measured match rates against the 2,176 PDI energy-drink SKUs:

| Source | SKUs matched | Share of PDI revenue |
|---|---|---|
| Open Food Facts (`clean.energy_drinks`) | 392 | 65.8% |
| USDA (`ed.usda_branded_foods`, has ingredient text) | 565 | n/a |
| Ingredient text from either source | 810 | 90.0% |

A fallback match that ignores the barcode's check digit adds 32 SKUs but no material revenue, and it
risks false matches. Use the exact match only.

**`canonical_brand`, the brand key.** Comes from `ed.pdi_energy_monthly_gtin.canonical_brand`,
which is already standardized. `ed.brand_crosswalk` maps raw labels to canonical brands for the
sources `pdi`, `passport`, `mintel`, `simmons` and `gnpd`.

**`search_term`, the trends key.** `clean.google_trends` contains **ingredient** search terms
(432 terms such as `caffeine`, `taurine`, `sucralose`, `e330`, `panax ginseng`), not brand names.
It joins to products through their ingredients:

```sql
LOWER(REPLACE(product_ingredients.ingredient_name, '-', ' ')) = google_trends.search_term
```

That expression matches 428 of the 432 terms. The dataset also contains category terms with no
single ingredient behind them (`energy drink`, `sugar free energy drink`, `gaming energy`,
`natural caffeine`). Those belong in a monthly context table, not on product rows. 341 PDI SKUs (about 65% of revenue) have
at least one ingredient with trend data.

### Brand-level data repeats on every SKU

Passport and Mintel measure brands, not SKUs, so every Red Bull SKU carries the same Red Bull
share values. That's fine for filtering and description. In a SKU-level model, though,
these columns can only explain differences *between brands*, and they shouldn't be summed across
SKUs. Columns where this applies are tagged **[brand]** below.

---

## 2. Column dictionary

Types are BigQuery types. "Derivation" is the logic applied to the source columns; *as-is* means a
straight copy.

### A. Identity and product attributes

| Column | Type | Source table | Source column(s) | Derivation |
|---|---|---|---|---|
| `gtin` | STRING | `ed.pdi_energy_monthly_gtin` | `GTIN` | as-is; primary key |
| `gtin14` | STRING | `ed.pdi_energy_monthly_gtin` | `GTIN` | normalized 14-digit key (see above) |
| `product_description` | STRING | `ed.pdi_master_gtin` | `PRODUCT_DESCRIPTION` | as-is |
| `brand_raw` | STRING | `ed.pdi_energy_monthly_gtin` | `brand_raw` | as-is |
| `canonical_brand` | STRING | `ed.pdi_energy_monthly_gtin` | `canonical_brand` | `ANY_VALUE` per GTIN |
| `parent_company` | STRING | `ed.brand_crosswalk` | `parent_company` | where `source='pdi'`, joined on `canonical_brand` |
| `manufacturer` | STRING | `ed.pdi_master_gtin` | `MANUFACTURER` | as-is |
| `manufacturer_parent` | STRING | `ed.pdi_master_gtin` | `MANUFACTURER_PARENT` | as-is |
| `category` | STRING | `ed.pdi_master_gtin` | `CATEGORY` | as-is |
| `subcategory` | STRING | `ed.pdi_energy_monthly_gtin` | `subcategory` | as-is |
| `product_type` | STRING | `ed.pdi_master_gtin` | `PRODUCT_TYPE` | as-is |
| `sub_product_type` | STRING | `ed.pdi_master_gtin` | `SUB_PRODUCT_TYPE` | as-is |
| `flavor` | STRING | `ed.pdi_master_gtin` | `FLAVOR` | as-is |
| `package` | STRING | `ed.pdi_master_gtin` | `PACKAGE` | as-is |
| `pack_size` | STRING | `ed.pdi_master_gtin` | `PACK_SIZE` | as-is |
| `unit_size` | STRING | `ed.pdi_master_gtin` | `UNIT_SIZE` | as-is (text, e.g. "16 OZ") |
| `unit_size_oz` | FLOAT64 | `ed.pdi_master_gtin` | `UNIT_SIZE` | parsed to fluid ounces |
| `pdi_created_at` | DATE | `ed.pdi_master_gtin` | `CREATED_AT` | as-is |

### B. Revenue and sales (PDI convenience-store panel)

All sales columns come from `ed.pdi_energy_monthly_gtin` (columns `month`, `revenue`, `units`,
`transactions`, `store_skus`, `store_days`). "Last 12m" means the 12 latest *complete* months.
Revenue covers **PDI panel stores only**, not the whole US market.

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `first_sale_month` | DATE | `month` | `MIN(month)` |
| `last_sale_month` | DATE | `month` | `MAX(month)` |
| `months_with_sales` | INT64 | `month` | `COUNT(DISTINCT month)` where `revenue > 0` |
| `revenue_total` | FLOAT64 | `revenue` | `SUM`, all months |
| `units_total` | FLOAT64 | `units` | `SUM`, all months |
| `transactions_total` | FLOAT64 | `transactions` | `SUM`, all months |
| `revenue_last_12m` | FLOAT64 | `revenue` | `SUM`, last 12 complete months |
| `units_last_12m` | FLOAT64 | `units` | `SUM`, last 12 complete months |
| `revenue_prior_12m` | FLOAT64 | `revenue` | `SUM`, the 12 months before that |
| `revenue_yoy_pct` | FLOAT64 | `revenue` | `revenue_last_12m / revenue_prior_12m - 1` |
| `avg_price_per_unit_last_12m` | FLOAT64 | `revenue`, `units` | `revenue_last_12m / units_last_12m` |
| `revenue_share_of_brand_last_12m` | FLOAT64 | `revenue` | SKU ÷ `canonical_brand` total, last 12m |
| `revenue_rank_last_12m` | INT64 | `revenue` | rank among all SKUs |
| `sales_monthly` | ARRAY<STRUCT<month DATE, revenue FLOAT64, units FLOAT64, transactions FLOAT64>> | `month`, `revenue`, `units`, `transactions` | full monthly history nested in the row |

### C. Distribution and launch (PDI)

Source: `ed.pdi_sku_month_distribution`, one row per GTIN × month.

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `launch_month` | DATE | `first_sale_month` | `MIN` |
| `is_launched_in_window` | BOOL | `first_sale_month` | `> 2019-01-01` (earlier SKUs' true launch is unknown) |
| `peak_stores` | INT64 | `peak_stores` | `MAX` |
| `stores_selling_latest` | INT64 | `stores_selling` | value in latest month |
| `numeric_dist_latest` | FLOAT64 | `numeric_dist` | value in latest month |
| `numeric_dist_m6` / `_m12` | FLOAT64 | `numeric_dist`, `months_since_first_sale` | value at month 6 / 12 after launch |
| `dist_frac_of_peak_latest` | FLOAT64 | `dist_frac_of_peak` | value in latest month |
| `n_states_latest` | INT64 | `n_states` | value in latest month |
| `survived_12m` | BOOL | `stores_selling`, `months_since_first_sale` | still selling 12 months after launch; NULL if not yet observable |

### D. Geographic footprint (PDI)

Source: `ed.pdi_gtin_month_store` (GTIN × store × month; about 11 GB, so run it once and
materialize) joined to `ed.pdi_stores` on `STORE_ID`. Covers the latest 12 months available
(currently through 2025-12).

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `stores_sold_last_12m` | INT64 | `STORE_ID`, `revenue` | `COUNT(DISTINCT STORE_ID)` where `revenue > 0` |
| `states_sold_last_12m` | INT64 | `pdi_stores.STATE` | `COUNT(DISTINCT STATE)` |
| `top_state` | STRING | `pdi_stores.STATE`, `revenue` | state with the highest SKU revenue |
| `top_state_revenue_share` | FLOAT64 | `revenue` | top state ÷ SKU total |

### E. Ingredients and nutrition: USDA FoodData Central

Source: `ed.usda_branded_foods`, filtered to `is_energy_drink AND is_latest_for_upc`, joined on
`gtin14` from `gtin_upc`. USDA nutrient values are **per 100 g/ml**; the `*_per_serving` columns
are per serving.

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `usda_fdc_id` | INT64 | `fdc_id` | as-is |
| `usda_match_method` | STRING | n/a | `'gtin14'` or `'gtin13_no_check_digit'` |
| `usda_description` | STRING | `description` | as-is |
| `usda_brand_owner` | STRING | `brand_owner` | as-is |
| `usda_food_category` | STRING | `branded_food_category` | as-is |
| `usda_ingredients` | STRING | `ingredients` | as-is (label ingredient text) |
| `serving_size` / `serving_size_unit` | FLOAT64 / STRING | `serving_size`, `serving_size_unit` | as-is |
| `kcal_per_100` | FLOAT64 | `energy_kcal` | as-is |
| `sugars_g_per_100` | FLOAT64 | `total_sugars_g` | as-is |
| `added_sugars_g_per_100` | FLOAT64 | `added_sugars_g` | as-is |
| `sodium_mg_per_100` | FLOAT64 | `sodium_mg` | as-is |
| `carbohydrate_g_per_100` | FLOAT64 | `carbohydrate_g` | as-is |
| `protein_g_per_100` | FLOAT64 | `protein_g` | as-is |
| `caffeine_mg_per_serving_usda` | FLOAT64 | `caffeine_per_serving_mg` | as-is (only about 9 SKUs have it) |
| `is_zero_sugar` | BOOL | `total_sugars_g` | `< 0.5` g per 100 ml |
| `usda_discontinued_date` | DATE | `discontinued_date` | as-is |

### F. Ingredients and attributes: Open Food Facts

Source: `clean.energy_drinks`, joined on `gtin14` from `product_id`, with one row per barcode (no
duplicates). Nutrient values are **per 100 g/ml**.

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `off_product_id` | STRING | `product_id` | as-is |
| `off_product_name` | STRING | `product_name` | as-is |
| `off_brand` | STRING | `brand` | as-is |
| `off_brands_tags` | ARRAY<STRING> | `brands_tags` | as-is |
| `off_categories_tags` | ARRAY<STRING> | `categories_tags` | as-is |
| `off_ingredients_text` | STRING | `ingredients_text` | as-is (empty string → NULL) |
| `off_ingredients_tags` | ARRAY<STRING> | `ingredients_tags` | as-is (taxonomy tags, e.g. `en:taurine`) |
| `off_countries` | STRING | `countries` | as-is |
| `off_labels_tags` | ARRAY<STRING> | `labels_tags` | as-is (e.g. vegan, no-sugar claims) |
| `off_serving_size` | STRING | `serving_size` | as-is |
| `off_serving_size_value` / `_unit` | FLOAT64 / STRING | `serving_size_value`, `serving_size_unit` | as-is |
| `off_kcal_per_100` | FLOAT64 | `energy` | as-is. Mostly kcal; values above about 100 are probably kJ, so check before using |
| `off_sugars_g_per_100` | FLOAT64 | `sugar` | as-is |
| `off_fat_g_per_100` | FLOAT64 | `fat` | as-is |
| `off_protein_g_per_100` | FLOAT64 | `protein` | as-is |
| `off_salt_g_per_100` | FLOAT64 | `salt` | as-is |
| `off_caffeine_raw` | FLOAT64 | `caffeine` | as-is (units are inconsistent, see next row) |
| `off_caffeine_mg_per_100` | FLOAT64 | `caffeine` | values 0.001–0.1 are grams → × 1000; values 1–100 are already mg; anything else → NULL |
| `off_nutrition_grade` | STRING | `nutrition_grade` | Nutri-Score letter, as-is |
| `off_last_modified` | TIMESTAMP | `last_modified` | as-is |
| `off_ingredient_count` | INT64 | `clean.product_ingredients.ingredient_name` | `COUNT(DISTINCT)` per `product_id` |
| `off_ingredients_ranked` | ARRAY<STRING> | `clean.product_ingredients.ingredient_name`, `ingredient_rank` | `ARRAY_AGG(ingredient_name ORDER BY ingredient_rank)` |

### G. Unified ingredients (the "ingredients list" column)

| Column | Type | Source | Derivation |
|---|---|---|---|
| `ingredients` | STRING | `clean.energy_drinks.ingredients_text`, then `ed.usda_branded_foods.ingredients` | `COALESCE(off_ingredients_text, usda_ingredients)` |
| `ingredients_source` | STRING | n/a | `'open_food_facts'`, `'usda'` or NULL |
| `has_caffeine`, `has_taurine`, `has_sucralose`, `has_guarana`, `has_ginseng`, `has_beta_alanine`, … | BOOL | `ingredients` | `REGEXP_CONTAINS(LOWER(ingredients), r'\btaurine\b')` etc.; pick the flags your analysis needs |

Open Food Facts comes first because it was pulled specifically for ingredients and has
parsed lists. USDA fills in 418 SKUs that Open Food Facts lacks. Together they cover 810 SKUs,
about 90% of revenue.

### H. Google Trends for ingredients

Source: `clean.google_trends` (`search_term`, `week_start_date`, `interest_score`), weekly from
2021-07-04 to 2026-07-05. It links to a SKU through `clean.product_ingredients` using the
`search_term` key above. Trends exist only for SKUs matched to Open Food Facts; SKUs with USDA
ingredients only can be added with a text match, see section 6.

**How to read these values:**
- **Scores aren't comparable across terms.** Each term is scaled 0–100 on its own (each has a
  max of 100 and no zeros), so "taurine = 40, caffeine = 72" doesn't mean caffeine is searched
  more. Use change within a term (last 52 weeks vs prior 52) as the signal.
- **35 terms carry no signal.** Their score is 100 every week, so they're excluded via
  `trend_has_signal`.
- **Generic ingredients dominate.** "water", "flavouring", "vitamins" and "sodium" appear in most
  products. Keep a short exclusion list so the product-level averages reflect distinctive
  ingredients.

| Column | Type | Source column(s) | Derivation |
|---|---|---|---|
| `ingredient_trends` | ARRAY<STRUCT<ingredient STRING, search_term STRING, interest_last_52w FLOAT64, interest_prior_52w FLOAT64, interest_yoy_pct FLOAT64>> | `product_ingredients.ingredient_name`; `google_trends.search_term`, `week_start_date`, `interest_score` | one element per matched ingredient; `AVG(interest_score)` over each 52-week window |
| `trend_terms_matched` | INT64 | same | number of ingredients with a usable trend series |
| `trend_interest_yoy_avg_pct` | FLOAT64 | same | mean of `interest_yoy_pct` across the SKU's distinctive ingredients |
| `trend_rising_ingredients` | INT64 | same | count of ingredients with `interest_yoy_pct > 0.20` |
| `trend_top_rising_ingredient` | STRING | same | ingredient with the highest `interest_yoy_pct` |
| `trend_has_signal` | BOOL | `google_trends.interest_score` | FALSE if every one of the SKU's matched terms is constant at 100 |

The four category terms (`energy drink`, `sugar free energy drink`, `gaming energy`,
`natural caffeine`) describe the whole market. Put them in the monthly companion table in
section 5, not on product rows.

### I. Market context from other sources [brand]

| Column | Type | Source table | Source column(s) | Derivation |
|---|---|---|---|---|
| `passport_value_share_pct` | FLOAT64 | `ed.passport_brand_shares` | `share_pct` | `measure='retail_value_rsp_pct'`, latest `year`; brand mapped via `brand_crosswalk` (`source='passport'`) |
| `passport_volume_share_pct` | FLOAT64 | `ed.passport_brand_shares` | `share_pct` | `measure='total_volume_pct'`, latest `year` |
| `passport_company_value_share_pct` | FLOAT64 | `ed.passport_company_shares` | `share_pct` | joined on `parent_company` |
| `mintel_mulo_share_2025_pct` | FLOAT64 | `ed.mintel_mulo_brand_sales` | `share_2025_pct` | brand via `brand_crosswalk` (`source='mintel'`); `is_total_row = FALSE` |
| `mintel_mulo_share_2026_pct` | FLOAT64 | `ed.mintel_mulo_brand_sales` | `share_2026_pct` | same |
| `mintel_mulo_sales_change_pct` | FLOAT64 | `ed.mintel_mulo_brand_sales` | `sales_change_pct` | same |
| `brand_revenue_last_12m` | FLOAT64 | `ed.pdi_energy_monthly_gtin` | `revenue` | sum over the brand |
| `brand_sku_count` | INT64 | `ed.pdi_energy_monthly_gtin` | `GTIN` | count of SKUs in the brand |

### J. Data-quality flags

| Column | Type | Derivation |
|---|---|---|
| `has_usda_match` | BOOL | `usda_fdc_id IS NOT NULL` |
| `has_off_match` | BOOL | `off_code IS NOT NULL` |
| `has_off_ingredients` | BOOL | `off_ingredients_text IS NOT NULL` |
| `has_trends` | BOOL | `trend_terms_matched > 0` |
| `is_active` | BOOL | sold in the latest complete month |

---

## 3. Candidate tables to add after checking their schemas

These are in `ed` and are probably relevant, but I haven't inspected their columns yet:

| Table | Likely use | Join |
|---|---|---|
| `gnpd_products` (766 rows) | Mintel new-product launches: claims, launch date, possibly ingredients and barcodes | `gtin14` if it has barcodes, otherwise brand via `brand_crosswalk` (`source='gnpd'`) |
| `simmons_brand_profiles` (603 rows) | Consumer audience profile per brand (age, income, psychographics) [brand] | brand via `brand_crosswalk` (`source='simmons'`) |

## 4. Tables deliberately left out of the product master

These have no product or brand key. Join them at analysis time by month, region or generation
instead of copying them onto every SKU row.

| Table(s) | Why excluded |
|---|---|
| `mintel_*` category tables (channel sales, forecasts, occasions, motivations, surveys) | Category- or generation-level, not product-level |
| `passport_market_size` | Total-market size |
| `umich_consumer_sentiment`, `us_population_by_age`, `reference_generations` | Macro / time-series context; join on month |
| `scarborough_*`, `dma_control_block_2025`, `connexions_segments` | Market (DMA) demographics; join via store geography if needed |
| `pdi_daily_agg` | ~420 GB daily detail; the monthly tables above already summarize it |
| `pdi_energy_drinks_monthly`, `pdi_energy_shots_monthly`, `pdi_sports_drinks_monthly` | Brand-month rollups; the GTIN-level table is used instead |
| `similarweb_visits_all` | Contains no energy-drink brand websites |
| `pdi_stores_status`, `sa_variable_inventory`, `scarborough_variables`, `simmons_catalyst_*`, `simmons_row_taxonomy` | Reference or metadata tables |

## 5. Companion table for time-series work

`product_master` nests the monthly history in `sales_monthly` and `trends_monthly`. For
regression or forecasting it's often easier to also build a long table,
`product_month` (one row per GTIN × month), with: revenue, units, stores_selling and
numeric_dist (from `pdi_sku_month_distribution`), the mean monthly interest of the SKU's
ingredient terms, the four category-level trend terms that month, and
`consumer_confidence_index` (`ed.umich_consumer_sentiment`). Weekly trends roll up to months by
`DATE_TRUNC(week_start_date, MONTH)`. Static product attributes stay in
`product_master` and are joined on `gtin`.

## 6. Open items before building

1. **Decide whether to extend trends to USDA-only SKUs.** About 470 SKUs have USDA ingredient text
   but no Open Food Facts match. Matching trend terms inside that text with
   `REGEXP_CONTAINS(LOWER(ingredients), CONCAT(r'\b', search_term, r'\b'))` would roughly double
   trend coverage. The risk is that short terms like `e330` won't appear in English USDA text.
2. **Agree on the generic-ingredient exclusion list** for the trend averages.
3. **Spot-check `off_kcal_per_100` and `off_caffeine_mg_per_100`** against a few known products
   (for example, Red Bull 8.4 oz is 80 mg caffeine and 110 kcal).
4. **Decide whether you also want brand search interest.** It isn't in either dataset; it would
   need a new Google Trends pull for brand names such as "red bull", "monster energy" and
   "celsius".
