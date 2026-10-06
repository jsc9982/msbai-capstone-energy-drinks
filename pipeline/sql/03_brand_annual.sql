-- Annual brand revenue and share. Growth is like-for-like: each year is compared
-- with the same calendar months of the prior year, so a partial current year
-- (YTD) gets a fair YoY figure.
CREATE OR REPLACE TABLE `{dst}.brand_annual` AS
WITH coverage AS (
  SELECT EXTRACT(YEAR FROM month) AS year, MAX(EXTRACT(MONTH FROM month)) AS through_month,
         COUNT(DISTINCT month) AS months_covered
  FROM `{dst}.brand_monthly`
  GROUP BY 1
),
yearly AS (
  SELECT
    EXTRACT(YEAR FROM m.month) AS year,
    m.brand,
    ANY_VALUE(m.parent_company) AS parent_company,
    SUM(m.revenue) AS revenue,
    SUM(m.units) AS units,
    MAX(m.stores) AS peak_stores
  FROM `{dst}.brand_monthly` m
  GROUP BY 1, 2
),
prior_lfl AS (
  -- Prior-year revenue restricted to the months covered in the following year.
  SELECT EXTRACT(YEAR FROM m.month) + 1 AS year, m.brand, SUM(m.revenue) AS revenue
  FROM `{dst}.brand_monthly` m
  JOIN coverage c ON c.year = EXTRACT(YEAR FROM m.month) + 1
  WHERE EXTRACT(MONTH FROM m.month) <= c.through_month
  GROUP BY 1, 2
),
prior_lfl_total AS (
  SELECT year, SUM(revenue) AS revenue FROM prior_lfl GROUP BY year
),
shares AS (
  SELECT y.*, SAFE_DIVIDE(y.revenue, SUM(y.revenue) OVER (PARTITION BY y.year)) AS revenue_share
  FROM yearly y
)
SELECT
  s.year,
  c.months_covered,
  c.months_covered < 12 AS is_partial_year,
  s.brand,
  s.parent_company,
  s.revenue,
  s.units,
  s.peak_stores,
  s.revenue_share,
  SAFE_DIVIDE(s.revenue, p.revenue) - 1 AS revenue_yoy_lfl_pct,
  (s.revenue_share - SAFE_DIVIDE(p.revenue, pt.revenue)) * 100 AS share_change_pp
FROM shares s
JOIN coverage c USING (year)
LEFT JOIN prior_lfl p USING (year, brand)
LEFT JOIN prior_lfl_total pt USING (year)
