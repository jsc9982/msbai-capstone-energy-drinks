"""Export the analytics tables to dashboard/data.js for the static dashboard.

Run after run_pipeline.py:
    python -m pipeline.export_dashboard_data

The output is a plain script (window.DASHBOARD_DATA = {...}) so the dashboard
works straight from disk, on GitHub Pages, or any static host.
"""

import datetime as dt
import decimal
import json
from pathlib import Path

from pipeline.config import SOURCE, TARGET, TARGET_LOCATION, TARGET_PROJECT, get_client

OUT = Path(__file__).resolve().parent.parent / "dashboard" / "data.js"

# Brands that get their own color; everything else folds into "Other". Chosen by
# revenue over the latest 12 months, then fixed so colors follow the brand.
TOP_N = 7

QUERIES = {
    "top_brands": f"""
        SELECT brand FROM `{TARGET}.brand_monthly`
        WHERE month > DATE_SUB((SELECT MAX(month) FROM `{TARGET}.brand_monthly`), INTERVAL 12 MONTH)
        GROUP BY brand ORDER BY SUM(revenue) DESC LIMIT {TOP_N}""",
    "category_monthly": f"""
        SELECT segment, month, revenue, revenue_per_store, avg_price_per_unit,
               revenue_yoy_pct, revenue_per_store_yoy_pct, avg_price_yoy_pct, consumer_confidence_index
        FROM `{TARGET}.category_monthly` WHERE is_complete_month ORDER BY segment, month""",
    "brand_monthly_share": f"""
        WITH top AS ({{top}})
        SELECT month, IF(brand IN (SELECT brand FROM top), brand, 'Other') AS brand,
               SUM(revenue_share) AS revenue_share, SUM(revenue) AS revenue
        FROM `{TARGET}.brand_monthly` GROUP BY 1, 2 ORDER BY 1, 2""",
    "brand_annual": f"""
        SELECT year, is_partial_year, months_covered, brand, parent_company, revenue, revenue_share,
               revenue_yoy_lfl_pct, share_change_pp, peak_stores
        FROM `{TARGET}.brand_annual`
        WHERE brand IN (SELECT brand FROM `{TARGET}.brand_annual` GROUP BY brand ORDER BY SUM(revenue) DESC LIMIT 15)
        ORDER BY year, revenue DESC""",
    "brand_share_benchmark": f"""
        SELECT source, measure, year, brand, share_pct FROM `{TARGET}.brand_share_benchmark`
        WHERE NOT is_partial_year ORDER BY source, measure, year, share_pct DESC""",
    "sku_launch_summary": f"""
        SELECT * FROM `{TARGET}.sku_launch_summary` WHERE skus_launched >= 10 ORDER BY skus_launched DESC""",
    "launches_by_year": f"""
        SELECT launch_year, COUNT(*) AS skus, COUNTIF(survived_12m) AS survived, COUNTIF(observed_12m) AS observed
        FROM `{TARGET}.sku_launches` GROUP BY 1 ORDER BY 1""",
    "state_brand_share": f"""
        WITH top AS ({{top}})
        SELECT state, IF(brand IN (SELECT brand FROM top), brand, 'Other') AS brand,
               SUM(revenue) AS revenue, SUM(revenue_share) AS revenue_share,
               MAX(state_stores) AS state_stores, MAX(window_end_month) AS window_end_month
        FROM `{TARGET}.state_brand_share` GROUP BY 1, 2 ORDER BY 1, 2""",
    "zero_sugar_monthly": f"""
        SELECT month, zero_sugar_share, match_coverage FROM `{TARGET}.zero_sugar_monthly` ORDER BY month""",
    "nutrition_by_brand": f"""
        SELECT brand, COUNT(*) AS skus, COUNTIF(is_zero_sugar) AS zero_sugar_skus,
               AVG(sugars_g_per_100) AS avg_sugars_g_per_100, AVG(kcal_per_100) AS avg_kcal_per_100,
               SUM(lifetime_revenue) AS matched_revenue
        FROM `{TARGET}.sku_nutrition` WHERE brand IS NOT NULL
        GROUP BY brand HAVING skus >= 5 ORDER BY matched_revenue DESC LIMIT 15""",
    "market_outlook": f"""SELECT * FROM `{TARGET}.market_outlook` ORDER BY source, metric, year""",
    "consumer_generations": f"""SELECT * FROM `{TARGET}.consumer_generations`""",
}


def to_json(value):
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()[:10]
    raise TypeError(f"Cannot serialize {type(value)}")


def main() -> None:
    client = get_client(TARGET_PROJECT)
    top_sql = QUERIES["top_brands"]
    data = {}
    for name, sql in QUERIES.items():
        rows = client.query(sql.replace("{top}", top_sql), location=TARGET_LOCATION).result()
        data[name] = [dict(r.items()) for r in rows]
        print(f"{name:24s} {len(data[name]):6d} rows")
    data["top_brands"] = [r["brand"] for r in data["top_brands"]]
    data["meta"] = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "source_dataset": SOURCE,
        "analytics_dataset": TARGET,
    }
    OUT.write_text("window.DASHBOARD_DATA = " + json.dumps(data, default=to_json, separators=(",", ":")) + ";\n")
    print(f"Wrote {OUT} ({OUT.stat().st_size / 1e3:.0f} KB)")


if __name__ == "__main__":
    main()
