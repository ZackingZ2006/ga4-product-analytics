-- SQLite translation of the ordered-funnel core for local behavioral tests.
-- This file does NOT validate the BigQuery dialect or the public dataset.
WITH v AS (
  SELECT session_key,
    MIN(CASE WHEN event_name='view_item' THEN ts END) AS view_ts
  FROM events WHERE session_key IS NOT NULL GROUP BY session_key
), c AS (
  SELECT v.session_key,v.view_ts,
    MIN(CASE WHEN e.event_name='add_to_cart'
          AND (e.ts>v.view_ts OR (:strict_order=0 AND e.ts=v.view_ts))
        THEN e.ts END) AS cart_ts
  FROM v LEFT JOIN events e USING(session_key)
  GROUP BY v.session_key,v.view_ts
), k AS (
  SELECT c.session_key,c.view_ts,c.cart_ts,
    MIN(CASE WHEN e.event_name='begin_checkout'
          AND (e.ts>c.cart_ts OR (:strict_order=0 AND e.ts=c.cart_ts))
        THEN e.ts END) AS checkout_ts
  FROM c LEFT JOIN events e USING(session_key)
  GROUP BY c.session_key,c.view_ts,c.cart_ts
), p AS (
  SELECT k.session_key,k.view_ts,k.cart_ts,k.checkout_ts,
    MIN(CASE WHEN e.event_name='purchase'
          AND (e.ts>k.checkout_ts OR (:strict_order=0 AND e.ts=k.checkout_ts))
        THEN e.ts END) AS purchase_ts
  FROM k LEFT JOIN events e USING(session_key)
  GROUP BY k.session_key,k.view_ts,k.cart_ts,k.checkout_ts
)
SELECT * FROM p ORDER BY session_key;
