-- Mintel consumer survey results by generation, stacked into one long table
-- (question set, item, generation, % of respondents).
CREATE OR REPLACE TABLE `{dst}.consumer_generations` AS
SELECT 'Motivations' AS question_set, motivation AS item, generation, pct
FROM `{src}.mintel_motivations_by_generation`
UNPIVOT (pct FOR generation IN (gen_z_pct AS 'Gen Z', millennials_pct AS 'Millennials', gen_x_and_older_pct AS 'Gen X & older'))
UNION ALL
SELECT 'Concept interest', concept, generation, pct
FROM `{src}.mintel_concept_interest`
UNPIVOT (pct FOR generation IN (gen_z_pct AS 'Gen Z', millennials_pct AS 'Millennials', gen_x_pct AS 'Gen X'))
UNION ALL
SELECT 'Beverages consumed', beverage_type, generation, pct
FROM `{src}.mintel_beverage_by_generation`
UNPIVOT (pct FOR generation IN (gen_z_pct AS 'Gen Z', millennials_pct AS 'Millennials', gen_x_pct AS 'Gen X', baby_boomers_pct AS 'Baby Boomers'))
UNION ALL
SELECT 'Attitudes', statement, generation, pct
FROM `{src}.mintel_statement_preferences`
UNPIVOT (pct FOR generation IN (gen_z_pct AS 'Gen Z', millennials_pct AS 'Millennials', gen_x_pct AS 'Gen X', boomers_and_older_pct AS 'Boomers & older'))
UNION ALL
SELECT 'Occasions', occasion, 'All adults', pct_of_consumers
FROM `{src}.mintel_occasions`
