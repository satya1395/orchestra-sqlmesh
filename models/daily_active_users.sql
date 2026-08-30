-- THE model this fixture exists for: INCREMENTAL_BY_TIME_RANGE.
--
-- SQLMesh tracks, per model snapshot, which [start, end) calendar intervals
-- have already been processed, in its own state database (six tables under
-- the `sqlmesh_state` schema — see README). `sqlmesh run` asks that state
-- "which intervals are due?" and only ever (re)computes those. A second
-- `sqlmesh run`, once a new daily interval has become due, must process only
-- that new day — not the whole 2026-08-20..2026-08-29 history again. That
-- before/after behavior, with real captured output, is what work item 6 of
-- SCOPE-runner-sqlmesh.md needs to prove twice against the deployed stack,
-- and what this repo's README "Verified" section proves once here.
--
-- @start_ds / @end_ds are SQLMesh's built-in macros for the interval
-- currently being evaluated; using them (rather than reading the whole
-- source table) is what makes this genuinely incremental rather than a FULL
-- model that merely happens to have a time column.
MODEL (
  name marts.daily_active_users,
  kind INCREMENTAL_BY_TIME_RANGE (
    time_column event_date
  ),
  start '2026-08-20',
  cron '@daily'
);

select
    event_date,
    count(distinct user_id) as active_users,
    count(*) as pageviews
from staging.stg_page_views
where event_date between @start_ds and @end_ds
group by event_date
