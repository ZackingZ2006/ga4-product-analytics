-- OPTIONAL: append this block to the END of 01_ga4_funnel.sql when executing.
-- Substitute YOUR_PROJECT with your project ID and choose a NEW table name.
-- The destination must be in the same location as the public dataset (US).
-- CREATE TABLE intentionally fails if that name already exists: it never overwrites.
-- In BigQuery Sandbox, persisted tables have the Sandbox expiration limitations.
CREATE SCHEMA IF NOT EXISTS `YOUR_PROJECT.ga4_funnel` OPTIONS (location = 'US');
CREATE TABLE `YOUR_PROJECT.ga4_funnel.mart_session_funnel_run_001` AS
SELECT * FROM mart_session_funnel;
