# Product master dataset: schema and source map

**Target table:** `msbai-capstone-energy-drinks.energy_drinks_analytics.product_master`
**Grain:** one row per energy-drink SKU (GTIN / UPC barcode).
**Universe:** every GTIN in `energy_drinks.pdi_energy_monthly_gtin` (about 2,176 SKUs, all
subcategory "Energy Drinks"), so every row has sales. Other sources are LEFT JOINed onto it.

Dataset shorthand used below:

| Shorthand | Full BigQuery path | Status |
|---|---|---|
| `ed` | `msbai-capstone-energydrinks.energy_drinks` | Schemas verified (queried 2026-10-06) |
| `clean` | `msbai-dwd-jsc9982.clean` | **Not yet inspected.** Table and column names marked ⚠ are placeholders until confirmed |

---

## 1. How the sources fit together

```
                         ┌──────────────────────── join key: gtin14 (SKU level) ───────────────────────┐
ed.pdi_energy_monthly_gtin ──┬── ed.pdi_master_gtin            (product attributes)
  (universe + revenue)       ├── ed.pdi_sku_month_distribution (store distribution, launch)
                             ├── ed.pdi_gtin_month_store       (state footprint)
                             ├── ed.usda_branded_foods         (nutrition + USDA ingredients)
                             └── clean.<open food facts> ⚠     (ingredients, additives, scores)
                         ┌──────────────────────── join key: canonical_brand (brand level) ────────────┐
                             ├── ed.brand_crosswalk            (brand → parent company)
                             ├── clean.<google trends> ⚠       (search interest, via keyword→brand map)
                             ├── ed.passport_brand_shares      (all-channel share)
                             └── ed.mintel_mulo_brand_sales    (MULO share)
```

### Join keys

**`gtin14`, the SKU key.** Each source stores barcodes differently: PDI `GTIN`, USDA `gtin_upc`,
and the Open Food Facts `code` (EAN-13). Normalize all of them the same way:

```sql
LPAD(LTRIM(REGEXP_REPLACE(barcode, r'[^0-9]', ''), '0'), 14, '0') AS gtin14
```

Earlier work matched only 612 of the 2,176 PDI GTINs to USDA by barcode. Some feeds drop the
check digit, so if the match rate stays low, add a fallback join on the barcode without its last
digit (`SUBSTR(gtin14, 1, 13)`) and record which join hit in `*_match_method`.

**`canonical_brand`, the brand key.** Comes from `ed.pdi_energy_monthly_gtin.canonical_brand`,
which is already standardized. `ed.brand_crosswalk` maps raw labels to canonical brands for the
sources `pdi`, `passport`, `mintel`, `simmons` and `gnpd`. It has **no Google Trends rows**, so
you need to add one, either as rows with `source = 'google_trends'` in a project-owned copy of the
crosswalk, or as a small mapping table `keyword → canonical_brand`.

### Brand-level data repeats on every SKU

Google Trends, Passport and Mintel measure brands, not SKUs, so every Red Bull SKU carries the same
Red Bull trends values. That's fine for filtering and description. In a SKU-level model, though,
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

### F. Ingredients and attributes: Open Food Facts ⚠

Source: `clean.<open food facts table>` ⚠, joined on `gtin14` from the barcode column (Open Food
Facts calls it `code`). The source columns below follow standard Open Food Facts field names;
**rename them to match the cleaned table** once it's inspected.

| Column | Type | Source column(s) ⚠ | Derivation |
|---|---|---|---|
| `off_code` | STRING | `code` | as-is |
| `off_product_name` | STRING | `product_name` | as-is |
| `off_ingredients_text` | STRING | `ingredients_text` | as-is |
| `off_ingredients_list` | ARRAY<STRING> | `ingredients_text` or parsed ingredient list | split on commas, trimmed, lower-cased |
| `off_additives` | ARRAY<STRING> | `additives_tags` | as-is |
| `off_caffeine_mg_per_100` | FLOAT64 | `caffeine_100g` | grams × 1000 if stored in grams |
| `off_sugars_g_per_100` | FLOAT64 | `sugars_100g` | as-is |
| `off_nutriscore_grade` | STRING | `nutriscore_grade` | as-is |
| `off_nova_group` | INT64 | `nova_group` | as-is |
| `off_labels` | ARRAY<STRING> | `labels_tags` | e.g. vegan, sugar-free |
| `off_allergens` | ARRAY<STRING> | `allergens_tags` | as-is |

### G. Unified ingredients (the "ingredients list" column)

| Column | Type | Source | Derivation |
|---|---|---|---|
| `ingredients` | STRING | `clean.<open food facts>` ⚠ then `ed.usda_branded_foods` | `COALESCE(off_ingredients_text, usda_ingredients)` |
| `ingredients_source` | STRING | n/a | `'open_food_facts'`, `'usda'` or NULL |
| `has_taurine`, `has_sucralose`, `has_guarana`, … | BOOL | `ingredients` | `REGEXP_CONTAINS(LOWER(ingredients), r'taurine')` etc.; pick the flags your analysis needs |

Open Food Facts comes first because it's the source you pulled specifically for ingredients. Swap
the order if you find USDA more complete.

### H. Google Trends [brand] ⚠

Source: `clean.<google trends table>` ⚠, assumed shape `keyword` × `date` × `interest` (0–100).
It joins to `canonical_brand` through the keyword→brand mapping described in section 1.

| Column | Type | Source column(s) ⚠ | Derivation |
|---|---|---|---|
| `trends_keyword` | STRING | `keyword` | the search term mapped to this brand |
| `trends_interest_last_12m_avg` | FLOAT64 | `interest`, `date` | mean over the same 12 months as `revenue_last_12m` |
| `trends_interest_prior_12m_avg` | FLOAT64 | `interest`, `date` | mean over the prior 12 months |
| `trends_interest_yoy_pct` | FLOAT64 | n/a | last ÷ prior − 1 |
| `trends_interest_peak` | FLOAT64 | `interest` | `MAX` |
| `trends_monthly` | ARRAY<STRUCT<month DATE, interest FLOAT64>> | `interest`, `date` | monthly mean, nested |

Google Trends values are scaled 0–100 *within each request*. Brands are only comparable with
each other if they were fetched in the same request (up to 5 terms) or rescaled against a shared
anchor term. Check how the cleaned table was built before comparing brands.

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
| `has_trends` | BOOL | `trends_keyword IS NOT NULL` |
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
numeric_dist (from `pdi_sku_month_distribution`), brand trends interest that month, and
`consumer_confidence_index` (`ed.umich_consumer_sentiment`). Static product attributes stay in
`product_master` and are joined on `gtin`.

## 6. Open items before building

1. List the tables and columns in `msbai-dwd-jsc9982.clean`, then replace every ⚠ placeholder:
   ```sql
   SELECT table_name, column_name, data_type
   FROM `msbai-dwd-jsc9982.clean.INFORMATION_SCHEMA.COLUMNS`
   ORDER BY table_name, ordinal_position;
   ```
2. Check the barcode match rates (PDI → USDA, PDI → Open Food Facts) and decide whether the
   check-digit fallback is needed.
3. Build the Google Trends keyword → `canonical_brand` mapping.
4. Confirm the location of the `clean` dataset. BigQuery can't join datasets in different
   locations; the `ed` dataset is in `US`.
