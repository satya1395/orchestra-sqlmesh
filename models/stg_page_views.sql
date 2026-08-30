-- Light typed pass over the seed, the shape a real staging model has.
-- Exercises the plain FULL kind: rebuilt in its entirety on every plan/run,
-- no interval tracking. Kept deliberately trivial (a cast, nothing an
-- adapter-specific function could break) so the only thing that can fail
-- here is the platform's clone/connection/config plumbing, not the SQL.
MODEL (
  name staging.stg_page_views,
  kind FULL,
  cron '@daily'
);

select
    event_id,
    user_id,
    page_path,
    event_time,
    cast(event_time as date) as event_date
from raw.raw_page_views
