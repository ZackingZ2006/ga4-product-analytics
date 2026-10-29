-- Read-only SELECT for an approximate DRY RUN estimate of the main source scan.
-- Use BigQuery's validation / dry-run operation, not the Run button.
-- This SELECT references the fields read by the main staging query and the same
-- shard filter. This estimate covers the public source read only, not the full
-- script or its TEMP tables. Downstream costs and engine behavior may differ.
SELECT event_date, event_timestamp, event_name, user_pseudo_id, event_params,
       device.category, geo.country, traffic_source.source, traffic_source.medium,
       ecommerce.transaction_id, ecommerce.purchase_revenue_in_usd, items
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';
