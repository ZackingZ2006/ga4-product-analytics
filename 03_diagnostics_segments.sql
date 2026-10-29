-- GA4 Product Analytics | GoogleSQL / BigQuery
-- STATUS: executed successfully on BigQuery Sandbox on 2026-10-29.
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


-- Supplemental: first acquisition source is not session attribution.
WITH dimensions AS (
  SELECT 'device' AS kind, device_category AS segment, * FROM mart_session_funnel
  UNION ALL
  SELECT 'first_source_medium', CONCAT(first_user_source, ' / ', first_user_medium), * FROM mart_session_funnel
), funnel_groups AS (
  SELECT kind, segment, COUNTIF(viewed) AS views, COUNTIF(carted_after_view) AS carts,
    COUNTIF(checked_out_after_cart) AS checkouts, COUNTIF(purchased_in_order) AS purchases,
    ROUND(100 * SAFE_DIVIDE(COUNTIF(checked_out_after_cart), COUNTIF(carted_after_view)), 2) AS cart_checkout_pct
  FROM dimensions GROUP BY kind, segment HAVING carts >= 100
), flags AS (
  SELECT e.session_key, COUNTIF(event_name = 'begin_checkout') > 0 AS has_checkout,
    COUNTIF(event_name = 'purchase') > 0 AS has_purchase
  FROM valid_events e JOIN fct_sessions s USING (session_key) GROUP BY e.session_key
), tracking AS (
  SELECT COUNTIF(has_purchase) AS purchases_any, COUNTIF(has_purchase AND NOT has_checkout) AS purchase_no_checkout,
    COUNTIF(m.carted_after_view AND NOT m.checked_out_after_cart AND f.has_checkout) AS cart_without_ordered_checkout_but_any_checkout
  FROM flags f JOIN mart_session_funnel m USING(session_key)
)
SELECT kind, segment, views, carts, checkouts, purchases, cart_checkout_pct,
  (SELECT purchases_any FROM tracking) AS purchase_sessions_any,
  (SELECT purchase_no_checkout FROM tracking) AS purchase_sessions_without_any_checkout,
  (SELECT cart_without_ordered_checkout_but_any_checkout FROM tracking) AS cart_without_ordered_but_any_checkout
FROM funnel_groups ORDER BY kind, carts DESC;
