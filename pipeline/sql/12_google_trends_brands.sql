-- Weekly Google Trends interest per energy-drink brand (US). Created empty here;
-- filled by `python -m pipeline.pull_brand_trends`, which must run somewhere that
-- can reach trends.google.com. interest_score is rescaled so every brand shares
-- the anchor term's scale and can be compared across brands.
CREATE TABLE IF NOT EXISTS `{dst}.google_trends_brands` (
  canonical_brand STRING,
  search_term STRING,
  week_start_date DATE,
  interest_score FLOAT64,
  anchor_term STRING,
  geo STRING,
  load_timestamp TIMESTAMP
)
