-- US energy-drink market size history and forecast, long format:
-- Euromonitor Passport (all channels, to 2030) and Mintel (with fan-chart bands).
CREATE OR REPLACE TABLE `{dst}.market_outlook` AS
SELECT
  'Euromonitor Passport' AS source,
  CONCAT(data_type, ' (', unit, ')') AS metric,
  year,
  value,
  CAST(NULL AS FLOAT64) AS low_90,
  CAST(NULL AS FLOAT64) AS high_90,
  year > 2025 AS is_forecast
FROM `{src}.passport_market_size`
WHERE NOT per_capita AND category = 'Energy Drinks'
UNION ALL
SELECT 'Mintel', 'Retail sales (USD million)', f.year, f.central_forecast_usd_m, f.low_90_usd_m, f.high_90_usd_m,
       -- Mintel has no explicit forecast flag; years with a non-degenerate band are forecasts.
       COALESCE(f.low_90_usd_m != f.high_90_usd_m, FALSE)
FROM `{src}.mintel_market_forecast` f
