-- ============================================================================
-- VAHAN PA CASE STUDY: SQL ANALYSIS
-- Dialect: BigQuery Standard SQL
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. DATA PROFILING
-- Business question: How big is the dataset, what does it cover, and are there structural surprises 
-- (missing keys, one row per lead, single-batch cohorts) before any metric is trusted?
-- ----------------------------------------------------------------------------
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT candidate_phone) AS unique_candidate_phones,
  COUNT(*) - COUNT(candidate_phone) AS rows_missing_phone,
  COUNT(DISTINCT lead_source) AS distinct_cohorts,
  COUNT(DISTINCT upload_date) AS distinct_upload_dates,
  MIN(upload_date) AS earliest_upload_date,
  MAX(upload_date) AS latest_upload_date,
  SUM(`Uploaded Leads`) AS sum_uploaded_leads_flag 
FROM `raw_data`;


-- ----------------------------------------------------------------------------
-- 2. GRAIN / CARDINALITY CHECK
-- Business question: Does a candidate_phone repeat within the SAME cohort
-- (true duplicate upload) or only ACROSS cohorts (re-targeting)?
-- ----------------------------------------------------------------------------
WITH phone_cohort_counts AS (
  SELECT candidate_phone, lead_source, upload_date, COUNT(*) AS n
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
  GROUP BY candidate_phone, lead_source, upload_date
)
SELECT
  COUNTIF(n > 1) AS true_duplicate_upload_rows 
FROM phone_cohort_counts;


-- ----------------------------------------------------------------------------
-- 3. FUNNEL CONVERSION - OVERALL (ALL COHORTS COMBINED)
-- Business question: Where in Lead -> Attempted -> Connected -> Interested -> OB -> FT does volume fall off the most?
-- Logic: stage-over-previous-stage AND stage-over-total-leads, both are reported because 
-- "previous stage" rates can look healthy while the absolute leak (vs. total leads) is what actually costs FT volume.
-- NULLIF guards every division so a zero-volume cohort never throws.
-- ----------------------------------------------------------------------------
WITH funnel AS (
  SELECT
    COUNT(*) AS leads,
    SUM(Attempted) AS attempted,
    SUM(Connected) AS connected,
    SUM(Interested) AS interested,
    SUM(OB_after_upload) AS ob_after_upload,
    SUM(FT_after_upload) AS ft_after_upload
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
)
SELECT
  leads, attempted, connected, interested, ob_after_upload, ft_after_upload,

  -- stage-over-previous-stage
  ROUND(SAFE_DIVIDE(attempted, leads) * 100, 2) AS attempt_rate_pct,
  ROUND(SAFE_DIVIDE(connected, NULLIF(attempted,0)) * 100, 2)  AS connect_rate_pct_of_attempted,
  ROUND(SAFE_DIVIDE(interested, NULLIF(connected,0)) * 100, 2) AS interest_rate_pct_of_connected,

  -- stage-over-total-leads (comparable across cohorts of any size)
  ROUND(SAFE_DIVIDE(connected, leads) * 100, 4)   AS lead_to_connected_pct,
  ROUND(SAFE_DIVIDE(interested, leads) * 100, 4)  AS lead_to_interested_pct,
  ROUND(SAFE_DIVIDE(ob_after_upload, leads) * 100, 4) AS lead_to_ob_pct,
  ROUND(SAFE_DIVIDE(ft_after_upload, leads) * 100, 4) AS lead_to_ft_pct
FROM funnel;


-- ----------------------------------------------------------------------------
-- 4. COHORT-LEVEL AGGREGATION 
-- (the "aggregate table" required by Case Question 2). 
-- Grain of aggregation = lead_source (cohort), because every cohort in this data is a single upload batch 
-- (one lead_source maps to one, or at most two, upload_date values).
-- ----------------------------------------------------------------------------
WITH cohort_agg AS (
  SELECT
    lead_source,
    MIN(upload_date) AS cohort_upload_date,
    DATE_DIFF((SELECT MAX(upload_date) FROM `raw_data`),
    MIN(upload_date), DAY) AS cohort_age_days,
    COUNT(*) AS leads,
    SUM(Attempted) AS attempted,
    SUM(Connected) AS connected,
    SUM(tag_filled) AS tag_filled,
    SUM(Interested) AS interested,
    SUM(OB_after_upload) AS ob_after_upload,
    SUM(FT_after_upload) AS ft_after_upload,
    SUM(FT_after_first_attempt) AS ft_after_first_attempt
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
  GROUP BY lead_source
)
SELECT
  lead_source, cohort_upload_date, cohort_age_days, leads, attempted, connected, interested, ft_after_upload,
  ROUND(SAFE_DIVIDE(attempted, leads) * 100, 2) AS attempt_rate_pct,
  ROUND(SAFE_DIVIDE(connected, NULLIF(attempted,0)) * 100, 2) AS connect_rate_pct,
  ROUND(SAFE_DIVIDE(interested, NULLIF(connected,0)) * 100, 2) AS interest_rate_pct,
  ROUND(SAFE_DIVIDE(ft_after_upload, leads) * 100, 4)         AS lead_to_ft_pct
FROM cohort_agg
ORDER BY leads DESC;


-- ----------------------------------------------------------------------------
-- 5. TOP-PERFORMING COHORTS (Case Question 1)
-- Business question: which 3 cohorts convert leads to FT most effectively?
-- Metric chosen: Lead -> FT_after_upload conversion rate (the end business outcome), 
-- NOT Lead -> FT_after_first_attempt (narrower, too rare to be stable: only 17 events total) 
-- and NOT interest/connect rate (intermediate,not the business objective).
-- Filters applied and justified in the report:
-- a)leads >= 1,000  -> excludes 5 cohorts with 1-3 leads whose rates are single-event artifacts, not signal.
-- b)cohort_age_days >= 5 -> excludes cohorts uploaded so recently that FT 
-- (which the data shows takes 1-2+ weeks to register) has not had time to occur (right-censoring).
-- ----------------------------------------------------------------------------
WITH cohort_agg AS (
  SELECT lead_source,
    MIN(upload_date) AS cohort_upload_date,
    DATE_DIFF((SELECT MAX(upload_date) FROM `raw_data`), MIN(upload_date), DAY) AS cohort_age_days,
    COUNT(*) AS leads,
    SUM(FT_after_upload) AS ft_after_upload
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
  GROUP BY lead_source
)
SELECT
  lead_source, cohort_upload_date, cohort_age_days, leads, ft_after_upload,
  ROUND(SAFE_DIVIDE(ft_after_upload, leads) * 100, 4) AS lead_to_ft_pct
FROM cohort_agg
WHERE leads >= 1000
  AND cohort_age_days >= 5
ORDER BY lead_to_ft_pct DESC
LIMIT 3;


-- ----------------------------------------------------------------------------
-- 6. COHORT COMPARISON - MATURE vs. IMMATURE COHORTS
-- Business question: are the newest cohorts under-performing for real, or simply too young to have converted yet? 
-- Segregates cohorts by age so a 0%-FT cohort uploaded yesterday isn't wrongly read as "bad".
-- ----------------------------------------------------------------------------
WITH cohort_agg AS (
  SELECT
    lead_source,
    DATE_DIFF((SELECT MAX(upload_date) FROM `raw_data`), MIN(upload_date), DAY) AS cohort_age_days,
    COUNT(*) AS leads,
    SUM(FT_after_upload) AS ft_after_upload
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
  GROUP BY lead_source
)
SELECT
  CASE WHEN cohort_age_days >= 5 THEN 'Mature (>=5 days)' ELSE 'Immature (<5 days)' END AS maturity_bucket,
  COUNT(*) AS cohorts,
  SUM(leads) AS total_leads,
  SUM(ft_after_upload) AS total_ft,
  ROUND(SAFE_DIVIDE(SUM(ft_after_upload), SUM(leads)) * 100, 4) AS lead_to_ft_pct
FROM cohort_agg
GROUP BY maturity_bucket;


-- ----------------------------------------------------------------------------
-- 7. DATE / TIME ANALYSIS - SPEED-TO-CALL vs. OUTCOME
-- Business question: does calling a lead sooner after upload associate with
-- a better connect outcome?
-- ----------------------------------------------------------------------------
SELECT
  CASE
    WHEN upload_to_first_attempt_P50_hrs IS NULL THEN 'Never attempted'
    WHEN upload_to_first_attempt_P50_hrs <= 24  THEN '0-24 hrs'
    WHEN upload_to_first_attempt_P50_hrs <= 96  THEN '24-96 hrs'
    WHEN upload_to_first_attempt_P50_hrs <= 240 THEN '96-240 hrs'
    ELSE '240+ hrs'
  END AS speed_to_first_attempt_bucket,
  COUNT(*) AS leads,
  SUM(Connected) AS connected,
  ROUND(SAFE_DIVIDE(SUM(Connected), COUNT(*)) * 100, 2) AS connect_rate_pct
FROM (
  SELECT *, `upload_to_first_attempt_P50 (hrs)` AS upload_to_first_attempt_P50_hrs
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
)
GROUP BY speed_to_first_attempt_bucket
ORDER BY leads DESC;


-- ----------------------------------------------------------------------------
-- 8. FUNNEL-STATE CONSISTENCY / LEAKAGE CHECK
-- Business question: does "Interested" behave as a reliable gate before OB
-- and FT, or do candidates reach OB/FT without ever being tagged Interested?
-- This directly informs whether Interested is safe to use as a model feature (Part 4 / Part 8 of the brief).
-- ----------------------------------------------------------------------------
SELECT
  COUNTIF(OB_after_upload = 1) AS total_ob,
  COUNTIF(OB_after_upload = 1 AND Interested = 0) AS ob_without_interested_flag,
  ROUND(SAFE_DIVIDE(
    COUNTIF(OB_after_upload = 1 AND Interested = 0),
    COUNTIF(OB_after_upload = 1)) * 100, 1) AS pct_ob_bypassing_interested_flag,

  COUNTIF(FT_after_upload = 1) AS total_ft,
  COUNTIF(FT_after_upload = 1 AND Interested = 0) AS ft_without_interested_flag,
  ROUND(SAFE_DIVIDE(
    COUNTIF(FT_after_upload = 1 AND Interested = 0),
    COUNTIF(FT_after_upload = 1)) * 100, 1) AS pct_ft_bypassing_interested_flag
FROM `raw_data`
WHERE candidate_phone IS NOT NULL;


-- ----------------------------------------------------------------------------
-- 9. DATA-QUALITY VALIDATION - HIERARCHY / IMPOSSIBLE-VALUE CHECKS
-- Business question: are the funnel columns internally consistent? 
-- e.g. can someone be Connected without being Attempted, or FT_after_first_attempt without FT_after_upload? 
-- Any row returned here needs investigation before the metric layer is trusted.
-- ----------------------------------------------------------------------------
SELECT 'Connected without Attempted' AS check_name, COUNT(*) AS violation_rows
FROM `raw_data` WHERE Connected = 1 AND Attempted = 0
UNION ALL
SELECT 'tag_filled without Connected', COUNT(*)
FROM `raw_data` WHERE tag_filled = 1 AND Connected = 0
UNION ALL
SELECT 'Interested without Connected', COUNT(*)
FROM `raw_data` WHERE Interested = 1 AND Connected = 0
UNION ALL
SELECT 'FT_after_first_attempt without FT_after_upload', COUNT(*)
FROM `raw_data` WHERE FT_after_first_attempt = 1 AND FT_after_upload = 0
UNION ALL
SELECT 'OB_after_first_attempt without OB_after_upload', COUNT(*)
FROM `raw_data` WHERE OB_after_first_attempt = 1 AND OB_after_upload = 0
UNION ALL
SELECT 'Uploaded Leads <> 1', COUNT(*)
FROM `raw_data` WHERE `Uploaded Leads` != 1
UNION ALL
SELECT 'Missing candidate_phone', COUNT(*)
FROM `raw_data` WHERE candidate_phone IS NULL;


-- ----------------------------------------------------------------------------
-- 10. SANITY CHECK - RECONCILE AGGREGATE TABLE TOTALS BACK TO OVERALL FUNNEL
-- Business question: does SUM of the cohort-level table (Query 4) equal the
-- single-row overall funnel (Query 3)? Required before publishing any number.
-- ----------------------------------------------------------------------------
WITH cohort_totals AS (
  SELECT
    SUM(leads) AS leads, SUM(ft) AS ft
  FROM (
    SELECT lead_source, COUNT(*) AS leads, SUM(FT_after_upload) AS ft
    FROM `raw_data`
    WHERE candidate_phone IS NOT NULL
    GROUP BY lead_source
  )
),
overall AS (
  SELECT COUNT(*) AS leads, SUM(FT_after_upload) AS ft
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
)
SELECT
  cohort_totals.leads AS cohort_sum_leads, overall.leads AS overall_leads,
  cohort_totals.ft AS cohort_sum_ft, overall.ft AS overall_ft,
  (cohort_totals.leads = overall.leads AND cohort_totals.ft = overall.ft) AS totals_match
FROM cohort_totals, overall;


-- ----------------------------------------------------------------------------
-- 11. DUPLICATE-CANDIDATE (RE-TARGETING) CHECK
-- Business question: how many candidates were uploaded into more than one
-- cohort, and does re-targeting a candidate correlate with eventual FT?
-- Informs whether candidate_phone should be de-duplicated before cohort
-- comparison (report concludes: no - cohort performance must be measured
-- at the lead/upload-event grain, not the person grain).
-- ----------------------------------------------------------------------------
WITH phone_cohort_counts AS (
  SELECT candidate_phone, COUNT(DISTINCT lead_source) AS n_cohorts, MAX(FT_after_upload) AS ever_ft
  FROM `raw_data`
  WHERE candidate_phone IS NOT NULL
  GROUP BY candidate_phone
)
SELECT
  CASE WHEN n_cohorts > 1 THEN 'Re-targeted (2+ cohorts)' ELSE 'Single cohort' END AS candidate_group,
  COUNT(*) AS candidates,
  SUM(ever_ft) AS candidates_with_ft,
  ROUND(SAFE_DIVIDE(SUM(ever_ft), COUNT(*)) * 100, 3) AS pct_with_ft
FROM phone_cohort_counts
GROUP BY candidate_group;
