-- Brand share of US energy drinks from three sources side by side, mapped to a
-- canonical brand via brand_crosswalk: the PDI c-store panel (revenue share),
-- Euromonitor Passport (all-channel value/volume) and Mintel MULO.
CREATE OR REPLACE TABLE `{dst}.brand_share_benchmark` AS
WITH xw AS (
  SELECT source, raw_label, ANY_VALUE(canonical_brand) AS canonical_brand
  FROM `{src}.brand_crosswalk`
  GROUP BY 1, 2
)
SELECT 'PDI c-store panel' AS source, 'revenue_share_pct' AS measure, year, brand,
       revenue_share * 100 AS share_pct, is_partial_year
FROM `{dst}.brand_annual`
UNION ALL
SELECT 'Euromonitor Passport', p.measure, p.year, COALESCE(x.canonical_brand, p.brand), p.share_pct, FALSE
FROM `{src}.passport_brand_shares` p
LEFT JOIN xw x ON x.source = 'passport' AND x.raw_label = p.brand
WHERE p.brand NOT IN ('Total')
UNION ALL
SELECT 'Mintel MULO', 'dollar_share_pct', yr, COALESCE(x.canonical_brand, m.brand), share, FALSE
FROM `{src}.mintel_mulo_brand_sales` m
CROSS JOIN UNNEST([STRUCT(2025 AS yr, m.share_2025_pct AS share), STRUCT(2026, m.share_2026_pct)])
LEFT JOIN xw x ON x.source = 'mintel' AND x.raw_label = m.brand
WHERE NOT COALESCE(m.is_total_row, FALSE)
