-- Downstream FULL model reading an incremental model's output. Exercises a
-- dependency edge that crosses kinds (INCREMENTAL_BY_TIME_RANGE -> FULL),
-- the same shape orchestra-smoke's customer_order_summary exercises for
-- dbt on top of two staging models. Rebuilt in full every run from whatever
-- daily_active_users currently holds, so it also proves that a downstream
-- FULL model correctly reflects an upstream incremental model's cumulative
-- state rather than just its latest batch.
MODEL (
  name marts.engagement_summary,
  kind FULL,
  cron '@daily'
);

select
    min(event_date) as first_date,
    max(event_date) as last_date,
    sum(pageviews) as total_pageviews,
    round(avg(active_users), 2) as avg_daily_active_users
from marts.daily_active_users
