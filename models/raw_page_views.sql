-- The only "data source" this fixture has. Exercises SQLMesh's SEED model
-- kind: rows come from the CSV at plan/run time, the SQLMesh analogue of a
-- dbt seed (see orchestra-smoke's customers.csv/orders.csv for the same
-- idea on the dbt side). No external system, no network call, fully
-- deterministic — event_time values are hand-picked to span exactly
-- 2026-08-20 through 2026-08-29 so the incremental model downstream has ten
-- distinct daily intervals to prove state persistence against.
MODEL (
  name raw.raw_page_views,
  kind SEED (
    path '../seeds/page_views.csv'
  ),
  columns (
    event_id INT,
    user_id VARCHAR,
    page_path VARCHAR,
    event_time TIMESTAMP
  )
);
