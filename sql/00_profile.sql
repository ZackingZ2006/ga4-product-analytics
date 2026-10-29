-- GoogleSQL / BigQuery | Read-only preflight.
-- A two-day source sample avoids a blind full-range scan during initial checks.
SELECT table_name, field_path, data_type
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
WHERE table_name = 'events_20201101'
  AND (field_path IN ('event_date','event_timestamp','event_name','user_pseudo_id',
                     'event_params.key','event_params.value.int_value',
                     'device.category','geo.country','traffic_source.source',
                     'traffic_source.medium','ecommerce.transaction_id',
                     'ecommerce.purchase_revenue_in_usd','items.item_id'))
ORDER BY field_path;

SELECT event_name, COUNT(*) AS event_rows,
  COUNT(DISTINCT user_pseudo_id) AS pseudonymous_users,
  COUNTIF(user_pseudo_id IS NULL) AS rows_without_user
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201102' AND '20201103'
GROUP BY event_name ORDER BY event_rows DESC;

-- Keys that repeat inside one event need investigation before scalar extraction.
SELECT COUNT(*) AS rows_with_duplicate_session_key
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201102' AND '20201103'
  AND (SELECT COUNT(*) FROM UNNEST(event_params) WHERE key='ga_session_id') > 1;
