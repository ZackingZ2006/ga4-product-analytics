-- GA4 Product Analytics | GoogleSQL / BigQuery
-- Run as ONE multi-statement script. TEMP tables do not modify source data.
-- Run 00_profile.sql first. This main script scans all 92 source shards once.
-- Changing cohort_start/end does NOT reduce that scan; inspect bytes before run.
-- Source: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*

DECLARE cohort_start DATE DEFAULT DATE '2020-11-02';
DECLARE cohort_end DATE DEFAULT DATE '2021-01-30';
DECLARE strict_order BOOL DEFAULT TRUE;
ASSERT cohort_start >= DATE '2020-11-02'
   AND cohort_end <= DATE '2021-01-30'
   AND cohort_start <= cohort_end AS 'Cohort outside guarded source window';

-- 01. STAGING: keep event rows, including repeats. There is no reliable event_id.
-- Extract scalar parameters before UNNEST(items); never cross-join two arrays.
-- Duplicate ga_session_id keys are quarantined, not resolved arbitrarily.
CREATE TEMP TABLE stg_events AS
WITH extracted AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS property_event_date,
    event_timestamp AS event_ts_us,
    event_name,
    NULLIF(TRIM(user_pseudo_id), '') AS user_pseudo_id,
    (SELECT MAX(value.int_value) FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS ga_session_id,
    (SELECT COUNT(*) FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS session_param_count,
    COALESCE(NULLIF(device.category, ''), 'Unknown') AS device_category,
    COALESCE(NULLIF(geo.country, ''), 'Unknown') AS country,
    COALESCE(NULLIF(traffic_source.source, ''), 'Unknown') AS first_user_source,
    COALESCE(NULLIF(traffic_source.medium, ''), 'Unknown') AS first_user_medium,
    CASE WHEN TRIM(ecommerce.transaction_id) IN ('', '(not set)', '<Other>')
         THEN NULL ELSE TRIM(ecommerce.transaction_id) END AS transaction_id,
    ecommerce.purchase_revenue_in_usd AS purchase_revenue_usd,
    items
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  -- Constant suffix bounds prune daily shards. Both edges are observation buffers.
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
)
SELECT *,
  CASE WHEN user_pseudo_id IS NOT NULL
         AND user_pseudo_id NOT IN ('(not set)', '<Other>')
         AND session_param_count = 1 AND ga_session_id > 0
       THEN TO_JSON_STRING(STRUCT(user_pseudo_id AS uid, ga_session_id AS sid))
       ELSE NULL END AS session_key
FROM extracted;

-- 02. DATA QUALITY: report excluded events, duplicate parameter keys and amounts.
SELECT '02_data_quality' AS result_set,
  COUNT(*) AS source_event_rows,
  COUNTIF(session_key IS NULL) AS events_without_usable_session,
  COUNTIF(session_param_count > 1) AS events_with_duplicate_session_parameter,
  COUNTIF(event_name = 'purchase') AS recorded_purchase_events,
  COUNTIF(event_name = 'purchase' AND transaction_id IS NULL) AS purchases_without_transaction_id,
  COUNTIF(event_name = 'purchase' AND purchase_revenue_usd IS NULL) AS purchases_without_usd_amount,
  COUNTIF(event_name = 'purchase' AND purchase_revenue_usd < 0) AS purchases_with_negative_amount,
  COUNTIF(purchase_revenue_usd IS NOT NULL
          AND (IS_NAN(purchase_revenue_usd) OR IS_INF(purchase_revenue_usd))) AS nonfinite_amounts
FROM stg_events;

CREATE TEMP TABLE valid_events AS
SELECT * FROM stg_events WHERE session_key IS NOT NULL;

-- 03. SESSION MART: grain = (user_pseudo_id, ga_session_id), not session_id alone.
-- event_date uses the property's registered timezone; timestamp ordering uses UTC.
CREATE TEMP TABLE session_candidates AS
SELECT
  session_key,
  ANY_VALUE(user_pseudo_id) AS user_pseudo_id,
  ANY_VALUE(ga_session_id) AS ga_session_id,
  MIN(property_event_date) AS cohort_date,
  MIN(event_ts_us) AS first_observed_ts_us,
  MAX(event_ts_us) AS last_observed_ts_us,
  COUNT(*) AS event_rows,
  COUNTIF(event_name = 'purchase') > 0 AS has_purchase_event,
  COUNTIF(property_event_date IN (DATE '2020-11-01', DATE '2021-01-31')) > 0 AS touches_source_edge,
  COUNTIF(event_name = 'session_start') > 0 AS has_session_start_event,
  COUNT(DISTINCT device_category) > 1 AS device_conflict,
  COUNT(DISTINCT country) > 1 AS country_conflict,
  COUNT(DISTINCT first_user_source) > 1 AS first_user_source_conflict,
  CASE WHEN COUNT(DISTINCT device_category) = 1
       THEN MIN(device_category) ELSE 'Mixed' END AS device_category,
  CASE WHEN COUNT(DISTINCT country) = 1
       THEN MIN(country) ELSE 'Mixed' END AS country,
  CASE WHEN COUNT(DISTINCT first_user_source) = 1
       THEN MIN(first_user_source) ELSE 'Mixed' END AS first_user_source,
  CASE WHEN COUNT(DISTINCT first_user_medium) = 1
       THEN MIN(first_user_medium) ELSE 'Mixed' END AS first_user_medium
FROM valid_events
GROUP BY session_key;

CREATE TEMP TABLE fct_sessions AS
SELECT * FROM session_candidates
WHERE cohort_date BETWEEN cohort_start AND cohort_end
  AND NOT touches_source_edge;

SELECT '03_session_scope' AS result_set,
  COUNT(*) AS candidate_sessions,
  COUNTIF(touches_source_edge) AS sessions_touching_source_boundary,
  COUNTIF(cohort_date BETWEEN cohort_start AND cohort_end
          AND NOT touches_source_edge) AS included_sessions,
  COUNTIF(NOT has_session_start_event) AS candidates_missing_session_start,
  COUNTIF(device_conflict OR country_conflict OR first_user_source_conflict) AS candidates_with_dimension_conflict
FROM session_candidates;

-- 04. ORDER MART: transaction_id is assumed globally unique for this one store.
-- A repeated transaction is not a second order. Conflicting user/amount -> quarantine.
-- Missing amount does not become 0; missing-id purchases stay in funnel quality stats.
CREATE TEMP TABLE order_quality AS
SELECT transaction_id,
  COUNT(*) AS purchase_event_rows,
  COUNT(DISTINCT user_pseudo_id) AS observed_users,
  COUNT(DISTINCT ROUND(purchase_revenue_usd, 2)) AS observed_usd_amounts,
  COUNTIF(purchase_revenue_usd < 0) AS negative_amount_rows,
  COUNTIF(purchase_revenue_usd IS NOT NULL
          AND (IS_NAN(purchase_revenue_usd) OR IS_INF(purchase_revenue_usd))) AS nonfinite_amount_rows
FROM stg_events
WHERE event_name = 'purchase' AND transaction_id IS NOT NULL
GROUP BY transaction_id;

CREATE TEMP TABLE canonical_orders AS
SELECT e.*, q.purchase_event_rows,
  q.observed_users > 1 OR q.observed_usd_amounts > 1
    OR q.negative_amount_rows > 0 OR q.nonfinite_amount_rows > 0 AS quarantined
FROM stg_events AS e
JOIN order_quality AS q USING (transaction_id)
WHERE e.event_name = 'purchase'
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY transaction_id
  ORDER BY event_ts_us, COALESCE(session_key, ''),
           COALESCE(user_pseudo_id, ''), purchase_revenue_usd
) = 1;

CREATE TEMP TABLE fct_orders AS
SELECT * FROM canonical_orders WHERE NOT quarantined;

CREATE TEMP TABLE orders_by_session AS
SELECT session_key,
  COUNT(*) AS verified_orders,
  COUNTIF(purchase_revenue_usd IS NOT NULL) AS orders_with_amount,
  SUM(purchase_revenue_usd) AS recorded_revenue_usd
FROM fct_orders
WHERE session_key IS NOT NULL
GROUP BY session_key;

SELECT '04_order_quality' AS result_set,
  COUNT(*) AS distinct_transaction_ids,
  COUNTIF(purchase_event_rows > 1) AS repeated_transaction_ids,
  SUM(purchase_event_rows - 1) AS repeated_purchase_rows,
  COUNTIF(quarantined) AS quarantined_transactions,
  COUNTIF(NOT quarantined AND session_key IS NULL) AS unassigned_valid_transactions,
  COUNTIF(NOT quarantined AND purchase_revenue_usd IS NULL) AS valid_transactions_missing_amount
FROM canonical_orders;

-- 05. ORDERED FUNNEL. Open between intermediate events; closed at view_item entry.
-- Grain = one session, not one user, item or order. Different products may occur.
-- Strict mode uses >. Equal timestamps have unknown order in this old sample.
-- This sample lacks batch_page_id / batch_ordering_id / batch_event_index.
CREATE TEMP TABLE step_view AS
SELECT s.session_key, MIN(IF(e.event_name = 'view_item', e.event_ts_us, NULL)) AS view_ts
FROM fct_sessions AS s
JOIN valid_events AS e USING (session_key)
GROUP BY s.session_key;

CREATE TEMP TABLE step_cart AS
SELECT v.session_key, v.view_ts,
  MIN(IF(e.event_name = 'add_to_cart'
         AND (e.event_ts_us > v.view_ts OR (NOT strict_order AND e.event_ts_us = v.view_ts)),
         e.event_ts_us, NULL)) AS cart_ts
FROM step_view AS v
LEFT JOIN valid_events AS e USING (session_key)
GROUP BY v.session_key, v.view_ts;

CREATE TEMP TABLE step_checkout AS
SELECT c.session_key, c.view_ts, c.cart_ts,
  MIN(IF(e.event_name = 'begin_checkout'
         AND (e.event_ts_us > c.cart_ts OR (NOT strict_order AND e.event_ts_us = c.cart_ts)),
         e.event_ts_us, NULL)) AS checkout_ts
FROM step_cart AS c
LEFT JOIN valid_events AS e USING (session_key)
GROUP BY c.session_key, c.view_ts, c.cart_ts;

CREATE TEMP TABLE step_purchase AS
SELECT c.session_key, c.view_ts, c.cart_ts, c.checkout_ts,
  MIN(IF(e.event_name = 'purchase'
         AND (e.event_ts_us > c.checkout_ts OR (NOT strict_order AND e.event_ts_us = c.checkout_ts)),
         e.event_ts_us, NULL)) AS purchase_ts
FROM step_checkout AS c
LEFT JOIN valid_events AS e USING (session_key)
GROUP BY c.session_key, c.view_ts, c.cart_ts, c.checkout_ts;

CREATE TEMP TABLE mart_session_funnel AS
SELECT s.*,
  p.view_ts, p.cart_ts, p.checkout_ts, p.purchase_ts,
  p.view_ts IS NOT NULL AS viewed,
  p.cart_ts IS NOT NULL AS carted_after_view,
  p.checkout_ts IS NOT NULL AS checked_out_after_cart,
  p.purchase_ts IS NOT NULL AS purchased_in_order,
  COALESCE(o.verified_orders, 0) AS verified_orders,
  COALESCE(o.orders_with_amount, 0) AS orders_with_amount,
  o.recorded_revenue_usd,
  SAFE_DIVIDE(p.purchase_ts - p.view_ts, 1000000.0) AS view_to_purchase_seconds
FROM fct_sessions AS s
JOIN step_purchase AS p USING (session_key)
LEFT JOIN orders_by_session AS o USING (session_key);

-- 06. EXECUTABLE QUALITY CONTRACTS: fail before exporting misleading KPIs.
ASSERT (SELECT COUNT(*) > 0 FROM fct_sessions) AS 'No eligible sessions';
ASSERT (SELECT COUNTIF(viewed) > 0 FROM mart_session_funnel) AS 'No funnel entrants';
ASSERT (SELECT COUNT(*) = COUNT(DISTINCT session_key) FROM fct_sessions)
  AS 'Duplicate session keys';
ASSERT (SELECT COUNT(*) FROM mart_session_funnel) = (SELECT COUNT(*) FROM fct_sessions)
  AS 'Session mart fan-out';
ASSERT (SELECT COUNT(*) = COUNT(DISTINCT transaction_id) FROM fct_orders)
  AS 'Duplicate transaction IDs after canonicalization';
ASSERT (SELECT COUNTIF(carted_after_view AND NOT viewed) = 0 FROM mart_session_funnel)
  AS 'Cart without funnel entry';
ASSERT (SELECT COUNTIF(checked_out_after_cart AND NOT carted_after_view) = 0 FROM mart_session_funnel)
  AS 'Checkout without eligible cart';
ASSERT (SELECT COUNTIF(purchased_in_order AND NOT checked_out_after_cart) = 0 FROM mart_session_funnel)
  AS 'Purchase without eligible checkout';
ASSERT (SELECT COUNTIF(purchased_in_order AND NOT has_purchase_event) = 0 FROM mart_session_funnel)
  AS 'Funnel purchase not observed';
ASSERT (SELECT COALESCE(SUM(verified_orders), 0) FROM mart_session_funnel)
     = (SELECT COUNT(*) FROM fct_orders AS o JOIN fct_sessions AS s USING (session_key))
  AS 'Order reconciliation failed';
ASSERT ABS(
  (SELECT COALESCE(SUM(recorded_revenue_usd), 0) FROM mart_session_funnel)
  - (SELECT COALESCE(SUM(o.purchase_revenue_usd), 0)
     FROM fct_orders AS o JOIN fct_sessions AS s USING (session_key))
) < 0.01 AS 'Revenue reconciliation failed';

-- 07. KPI OVERVIEW. Source amount is gross recorded purchase revenue, not profit.
SELECT '07_kpi_overview' AS result_set,
  COUNT(*) AS eligible_sessions,
  COUNT(DISTINCT user_pseudo_id) AS pseudonymous_users,
  COUNTIF(has_purchase_event) AS sessions_with_purchase_event,
  COUNTIF(verified_orders > 0) AS sessions_with_verified_order,
  COUNTIF(purchased_in_order) AS strict_funnel_purchase_sessions,
  SAFE_DIVIDE(COUNTIF(verified_orders > 0), COUNT(*)) AS verified_order_session_rate,
  SAFE_DIVIDE(COUNTIF(purchased_in_order), COUNTIF(viewed)) AS view_to_purchase_rate,
  SUM(verified_orders) AS verified_orders,
  SUM(orders_with_amount) AS orders_with_known_amount,
  SUM(recorded_revenue_usd) AS recorded_revenue_usd,
  SAFE_DIVIDE(SUM(recorded_revenue_usd), SUM(orders_with_amount)) AS aov_known_amount_usd,
  SAFE_DIVIDE(SUM(orders_with_amount), SUM(verified_orders)) AS amount_completeness_rate
FROM mart_session_funnel;

-- 08. FUNNEL TABLE: ratios are 0..1; display as percentages downstream.
WITH counts AS (
  SELECT COUNTIF(viewed) AS n1, COUNTIF(carted_after_view) AS n2,
         COUNTIF(checked_out_after_cart) AS n3, COUNTIF(purchased_in_order) AS n4
  FROM mart_session_funnel
), steps AS (
  SELECT 1 AS step, 'view_item' AS event, n1 AS sessions, n1 AS previous_sessions, n1 AS entrants FROM counts
  UNION ALL SELECT 2, 'add_to_cart', n2, n1, n1 FROM counts
  UNION ALL SELECT 3, 'begin_checkout', n3, n2, n1 FROM counts
  UNION ALL SELECT 4, 'purchase', n4, n3, n1 FROM counts
)
SELECT '08_funnel_steps' AS result_set, *,
  SAFE_DIVIDE(sessions, previous_sessions) AS step_conversion_rate,
  SAFE_DIVIDE(sessions, entrants) AS entry_conversion_rate,
  IF(step = 1, NULL, previous_sessions - sessions) AS dropoff_sessions,
  IF(step = 1, NULL, 1 - SAFE_DIVIDE(sessions, previous_sessions)) AS dropoff_rate
FROM steps ORDER BY step;

-- 08b. FUNNEL BY DEVICE: which step loses sessions on each device?
-- Same session grain as 08. Mixed / Unknown stay visible; never reassigned.
-- Devices with < 100 entrants are hidden: rates on tiny samples mislead.
WITH d AS (
  SELECT device_category,
    COUNTIF(viewed) AS n1, COUNTIF(carted_after_view) AS n2,
    COUNTIF(checked_out_after_cart) AS n3, COUNTIF(purchased_in_order) AS n4
  FROM mart_session_funnel
  GROUP BY device_category
  HAVING COUNTIF(viewed) >= 100
)
SELECT '08b_funnel_by_device' AS result_set, device_category,
  n1 AS view_sessions, n2 AS cart_sessions, n3 AS checkout_sessions, n4 AS purchase_sessions,
  SAFE_DIVIDE(n2, n1) AS view_to_cart_rate,
  SAFE_DIVIDE(n3, n2) AS cart_to_checkout_rate,
  SAFE_DIVIDE(n4, n3) AS checkout_to_purchase_rate,
  SAFE_DIVIDE(n4, n1) AS view_to_purchase_rate
FROM d
ORDER BY n1 DESC;

-- 09. DEVICE COMPARISON: Wilson interval describes binomial uncertainty only.
-- Repeated sessions from the same user are dependent; this is not an A/B result.
WITH g AS (
  SELECT device_category, COUNT(*) AS sessions,
    COUNTIF(viewed) AS entrants, COUNTIF(purchased_in_order) AS completions,
    COUNTIF(verified_orders > 0) AS verified_buying_sessions
  FROM mart_session_funnel GROUP BY device_category
), rates AS (
  SELECT *, SAFE_DIVIDE(completions, entrants) AS rate,
    SAFE_DIVIDE(verified_buying_sessions, sessions) AS verified_order_session_rate
  FROM g
)
SELECT '09_device_conversion' AS result_set, *,
  SAFE_DIVIDE(rate + 3.8416 / (2*entrants)
    - 1.96*SQRT(SAFE_DIVIDE(rate*(1-rate), entrants) + SAFE_DIVIDE(3.8416, 4*entrants*entrants)),
    1 + SAFE_DIVIDE(3.8416, entrants)) AS wilson_lower_95,
  SAFE_DIVIDE(rate + 3.8416 / (2*entrants)
    + 1.96*SQRT(SAFE_DIVIDE(rate*(1-rate), entrants) + SAFE_DIVIDE(3.8416, 4*entrants*entrants)),
    1 + SAFE_DIVIDE(3.8416, entrants)) AS wilson_upper_95
FROM rates
WHERE entrants >= 100
ORDER BY entrants DESC;

-- 10. ACQUISITION SOURCE: traffic_source is FIRST-USER source, not session attribution.
SELECT '10_first_user_acquisition' AS result_set,
  first_user_source, first_user_medium, COUNT(*) AS sessions,
  COUNTIF(viewed) AS entrants, COUNTIF(purchased_in_order) AS funnel_completions,
  SAFE_DIVIDE(COUNTIF(purchased_in_order), COUNTIF(viewed)) AS entry_conversion_rate,
  SUM(verified_orders) AS verified_orders, SUM(recorded_revenue_usd) AS recorded_revenue_usd
FROM mart_session_funnel
GROUP BY first_user_source, first_user_medium
HAVING COUNTIF(viewed) >= 100
ORDER BY entrants DESC;

-- 11. DAILY TREND: cohort date = first observed event_date, not purchase date.
WITH daily AS (
  SELECT cohort_date, COUNT(*) AS sessions, COUNTIF(viewed) AS entrants,
    COUNTIF(purchased_in_order) AS completions, SUM(recorded_revenue_usd) AS recorded_revenue_usd
  FROM mart_session_funnel GROUP BY cohort_date
), calendar AS (
  SELECT day AS cohort_date FROM UNNEST(GENERATE_DATE_ARRAY(cohort_start, cohort_end)) AS day
), filled AS (
  SELECT c.cohort_date, COALESCE(d.sessions,0) AS sessions,
    COALESCE(d.entrants,0) AS entrants, COALESCE(d.completions,0) AS completions,
    d.recorded_revenue_usd
  FROM calendar AS c LEFT JOIN daily AS d USING (cohort_date)
)
SELECT '11_daily_trend' AS result_set, *,
  COUNT(*) OVER (ORDER BY cohort_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS calendar_days_in_window,
  SAFE_DIVIDE(completions, entrants) AS daily_conversion,
  SAFE_DIVIDE(
    SUM(completions) OVER (ORDER BY cohort_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
    SUM(entrants) OVER (ORDER BY cohort_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
  ) AS trailing_7d_weighted_conversion,
  LAG(SAFE_DIVIDE(completions, entrants), 7) OVER (ORDER BY cohort_date) AS prior_week_daily_conversion
FROM filled ORDER BY cohort_date;

-- 12. TIME TO PURCHASE: successful ordered sessions only (selection explicitly stated).
SELECT '12_time_to_purchase' AS result_set,
  APPROX_QUANTILES(view_to_purchase_seconds,100)[OFFSET(50)] AS median_seconds,
  APPROX_QUANTILES(view_to_purchase_seconds,100)[OFFSET(90)] AS p90_seconds,
  COUNT(*) AS completed_funnel_sessions
FROM mart_session_funnel WHERE purchased_in_order;

-- 13. PRODUCT EXPOSURE: observational event/item statistics, not a same-item funnel.
-- Deduplicate membership at session x item x event_name after UNNEST(items).
WITH memberships AS (
  SELECT DISTINCT e.session_key, i.item_id, e.event_name
  FROM valid_events AS e
  JOIN fct_sessions AS s USING (session_key)
  CROSS JOIN UNNEST(e.items) AS i
  WHERE e.event_name IN ('view_item','add_to_cart')
    AND i.item_id IS NOT NULL AND i.item_id NOT IN ('','(not set)','<Other>')
)
SELECT '13_product_exposure' AS result_set, item_id,
  COUNTIF(event_name = 'view_item') AS viewing_sessions,
  COUNTIF(event_name = 'add_to_cart') AS adding_sessions
FROM memberships GROUP BY item_id
HAVING COUNTIF(event_name = 'view_item') >= 100
ORDER BY viewing_sessions DESC;

-- 14. SAME-TIMESTAMP QUALITY: do not invent within-batch ordering.
SELECT '14_timestamp_ties' AS result_set,
  COUNT(*) AS session_timestamp_groups,
  COUNTIF(step_names > 1) AS groups_with_multiple_funnel_steps
FROM (
  SELECT session_key, event_ts_us, COUNT(DISTINCT event_name) AS step_names
  FROM valid_events JOIN fct_sessions USING (session_key)
  WHERE event_name IN ('view_item','add_to_cart','begin_checkout','purchase')
  GROUP BY session_key, event_ts_us
);

-- 15. EXPORT: use this cohort/session table for downstream plots and audit.
SELECT '15_session_funnel_export' AS result_set, * FROM mart_session_funnel;

-- Sensitivity: rerun the full script with strict_order = FALSE; compare section 08.
-- Do not treat the difference as proven recovered conversions; order is ambiguous.
