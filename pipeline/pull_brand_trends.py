"""Pull weekly US Google Trends interest per energy-drink brand with pytrends and
load it into BigQuery (`google_trends_brands`), then rebuild product_master.

    pip install pytrends
    python -m pipeline.pull_brand_trends
    python -m pipeline.run_pipeline --only 13

pytrends is an unofficial client for trends.google.com, so it needs a network that
can reach that site, and Google may rate-limit it (HTTP 429). The script waits
and retries.

Comparability: Google scales each request 0-100 on its own. Every request here
holds the anchor brand plus up to 4 others, and each batch is rescaled so the
anchor's average matches its average in the first batch. That puts all brands on
one scale (100 = the anchor's peak in batch 1), so brands can be compared with
each other as well as over time.
"""

import datetime as dt
import time

from pytrends.exceptions import TooManyRequestsError
from pytrends.request import TrendReq

from pipeline.config import TARGET, TARGET_LOCATION, TARGET_PROJECT, get_client

TIMEFRAME = "today 5-y"  # weekly points
GEO = "US"
ANCHOR = "Red Bull"

# canonical_brand (as in pdi_energy_monthly_gtin) -> plain search phrase. Ambiguous
# names (Celsius, Bang, Ghost, Prime, C4, Reign, Venom...) get "energy" added, and
# where Google has an entity "topic" for the drink, the script uses that instead.
BRAND_TERMS = {  # top 20 brands by PDI revenue, 2025
    "Red Bull": "red bull",
    "Monster": "monster energy",
    "Celsius": "celsius energy drink",
    "Alani Nu": "alani nu",
    "C4": "c4 energy",
    "Ghost": "ghost energy",
    "Rockstar": "rockstar energy",
    "NOS": "nos energy drink",
    "Bang": "bang energy",
    "Reign": "reign energy",
    "Full Throttle": "full throttle energy",
    "Venom": "venom energy",
    "Bucked Up": "bucked up energy",
    "Rip It": "rip it energy",
    "Guayaki": "guayaki",
    "AMP": "amp energy",
    "Arizona Energy": "arizona energy drink",
    "Prime": "prime energy",
    "REDCON1": "redcon1 energy",
    "Ryse": "ryse energy",
}

TOPIC_HINTS = ("drink", "beverage", "brand", "energy")


def resolve_keyword(pytrends: TrendReq, phrase: str) -> str:
    """Use Google's entity topic id for the brand when one is clearly a drink; else the phrase."""
    try:
        for s in pytrends.suggestions(phrase):
            if any(h in s.get("type", "").lower() for h in TOPIC_HINTS):
                return s["mid"]
    except Exception:
        pass
    return phrase


def fetch(pytrends: TrendReq, keywords: list[str]):
    for attempt in range(6):
        try:
            pytrends.build_payload(keywords, timeframe=TIMEFRAME, geo=GEO)
            df = pytrends.interest_over_time()
            return df.drop(columns=["isPartial"], errors="ignore")
        except TooManyRequestsError:
            wait = 60 * (attempt + 1)
            print(f"  rate-limited; waiting {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"Google Trends kept rate-limiting for {keywords}")


def main() -> None:
    pytrends = TrendReq(hl="en-US", tz=300, retries=2, backoff_factor=1)
    keyword_of = {}
    for brand, phrase in BRAND_TERMS.items():
        keyword_of[brand] = resolve_keyword(pytrends, phrase)
        print(f"{brand:16s} -> {keyword_of[brand]}")
        time.sleep(2)

    anchor_kw = keyword_of[ANCHOR]
    others = [b for b in BRAND_TERMS if b != ANCHOR]
    anchor_ref = None
    rows = []
    for i in range(0, len(others), 4):
        batch = others[i:i + 4]
        df = fetch(pytrends, [anchor_kw] + [keyword_of[b] for b in batch])
        anchor_mean = df[anchor_kw].mean()
        if anchor_ref is None:
            anchor_ref = anchor_mean
            batch = [ANCHOR] + batch  # keep the anchor's own series once
        scale = anchor_ref / anchor_mean if anchor_mean else 1.0
        for brand in batch:
            for week, score in df[keyword_of[brand]].items():
                rows.append({
                    "canonical_brand": brand,
                    "search_term": f"{BRAND_TERMS[brand]} ({keyword_of[brand]})",
                    "week_start_date": week.date().isoformat(),
                    "interest_score": float(score) * scale,
                    "anchor_term": ANCHOR,
                    "geo": GEO,
                    "load_timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                })
        print(f"batch {i // 4 + 1}: {', '.join(batch)} (scale {scale:.3f})")
        time.sleep(10)

    from google.cloud import bigquery

    client = get_client(TARGET_PROJECT)
    table = client.get_table(f"{TARGET}.google_trends_brands")  # created by sql/12
    job = client.load_table_from_json(
        rows,
        table,
        job_config=bigquery.LoadJobConfig(schema=table.schema, write_disposition="WRITE_TRUNCATE"),
        location=TARGET_LOCATION,
    )
    job.result()
    print(f"Loaded {len(rows)} rows into {TARGET}.google_trends_brands")


if __name__ == "__main__":
    main()
