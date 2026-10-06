# msbai-capstone-energy-drinks

Analysis of the US energy-drink market. A BigQuery pipeline reads the shared course
dataset, builds analysis tables in our own project, and exports them to a static
dashboard.

```
msbai-capstone-energydrinks.energy_drinks      (source, read-only)
        │  pipeline/run_pipeline.py  — runs pipeline/sql/*.sql in order
        ▼
msbai-capstone-energy-drinks.energy_drinks_analytics   (our tables)
        │  pipeline/export_dashboard_data.py
        ▼
dashboard/data.js  →  dashboard/index.html
```

## Running it

```bash
pip install -r requirements.txt
gcloud auth application-default login          # or: export GCP_ACCESS_TOKEN=$(gcloud auth print-access-token)

python -m pipeline.run_pipeline --dry-run      # validate SQL, show GB scanned per step
python -m pipeline.run_pipeline                # build all tables (~15 GB scanned in total)
python -m pipeline.export_dashboard_data       # write dashboard/data.js
python -m http.server -d dashboard 8000        # open http://localhost:8000
```

For unattended runs (e.g. a cloud session), put a service-account key's JSON in the
`GCP_SERVICE_ACCOUNT_JSON` environment variable instead. The account needs BigQuery Data
Viewer on the source dataset, plus BigQuery Job User and BigQuery Data Editor on
`msbai-capstone-energy-drinks`.

Rebuild a single step with `--only 07`. Datasets can be changed with the
`ED_SOURCE_DATASET`, `ED_TARGET_PROJECT` and `ED_TARGET_DATASET` environment variables.
`dashboard/data.js` is gitignored because it contains figures derived from licensed data (Mintel, Euromonitor, PDI) and this repo is public; don't publish it on a public site.

## Tables built

| Table | What it holds | Main sources |
|---|---|---|
| `category_monthly` | Monthly revenue, revenue per store, price, YoY change for energy drinks, shots and sports drinks; consumer sentiment | `pdi_*_monthly`, `umich_consumer_sentiment` |
| `brand_monthly` | Brand × month revenue, share, price, stores, parent company | `pdi_energy_drinks_monthly`, `brand_crosswalk` |
| `brand_annual` | Brand × year revenue, share, like-for-like YoY growth and share change (handles a partial current year) | `brand_monthly` |
| `brand_share_benchmark` | Brand share from PDI vs Euromonitor Passport vs Mintel MULO | `passport_brand_shares`, `mintel_mulo_brand_sales` |
| `sku_launches` | One row per SKU launched after Jan 2019, with distribution at 3/6/12 months and 12-month survival | `pdi_sku_month_distribution` |
| `sku_launch_summary` | Launch scorecard by brand | `sku_launches` |
| `state_brand_share` | Brand share, store penetration and revenue per store by state, latest 12 months | `pdi_gtin_month_store`, `pdi_stores` |
| `sku_nutrition` | Sugar, calories and sodium per 100 ml for PDI SKUs matched to USDA by UPC | `usda_branded_foods` |
| `zero_sugar_monthly` | Zero-sugar share of revenue over time, with match coverage | `pdi_energy_monthly_gtin`, `sku_nutrition` |
| `market_outlook` | US market size history and forecast (Passport to 2030; Mintel with 90% band) | `passport_market_size`, `mintel_market_forecast` |
| `consumer_generations` | Mintel motivations, concept interest, attitudes and occasions by generation | `mintel_*` |

## Data notes

- **The PDI store panel grows** from ~400 stores (2016) to ~20,000 (2026), so raw revenue
  growth is mostly panel growth. Trend charts use revenue per store; data before 2019 is dropped.
- **Partial months** (the trailing month, if its revenue is under half the prior month's) are
  flagged and excluded from brand and dashboard views.
- **PDI is convenience stores only**, so its brand shares differ from all-channel sources;
  `brand_share_benchmark` puts them side by side.
- **`pdi_daily_agg` (~420 GB) is never queried**; the pipeline uses the monthly rollups.
  The largest step is `07_state_brand_share` (~11 GB).
- Not used: `similarweb_visits_all` contains no energy-drink brand domains, and USDA caffeine
  is populated for only a handful of products.
