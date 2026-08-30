# orchestra-sqlmesh

A deliberately small, deterministic SQLMesh project, used to prove Orchestra's second engine
works. It is the sibling of `orchestra-smoke`/`orchestra-fail`/`orchestra-slow` (dbt fixtures), for
SQLMesh: see `orchestra/docs/SCOPE-runner-sqlmesh.md` (work item 2) and its companion
`orchestra/docs/RECON-sqlmesh.md`, which pins the exact SQLMesh 0.236.1 config/CLI facts this
fixture relies on.

The one thing a dbt fixture can't exercise and this one exists specifically to: **SQLMesh is
stateful between runs.** It tracks, per model, which time intervals have already been processed in
a state database, and `sqlmesh run` only (re)computes intervals that have newly become due. Our
Fargate runner is one-shot and stateless; SQLMesh is not — this repo is the smallest real project
that makes that difference checkable end to end, twice, exactly as
`SCOPE-runner-sqlmesh.md`'s work item 6 requires against the deployed stack.

## Model inventory

```
seeds/page_views.csv (30 rows, 2026-08-20..2026-08-29)
        │
        ▼
raw.raw_page_views        (SEED)
        │
        ▼
staging.stg_page_views    (FULL)
        │
        ▼
marts.daily_active_users  (INCREMENTAL_BY_TIME_RANGE, time_column event_date)  ← the model this repo is for
        │
        ▼
marts.engagement_summary  (FULL)
```

| model                          | kind                       | what it exercises                                                                                                                                                                    |
| ------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `raw.raw_page_views`            | `SEED`                     | SQLMesh's seed kind — a CSV loaded at plan/run time. The SQLMesh analogue of a dbt seed; the only "data source," so the fixture builds against a completely empty warehouse.       |
| `staging.stg_page_views`        | `FULL`                     | A plain full-refresh model with a dependency edge (`raw.raw_page_views` → here). Rebuilt in full on every due run.                                                                  |
| `marts.daily_active_users`      | `INCREMENTAL_BY_TIME_RANGE`| **The point of this repo.** SQLMesh persists, per snapshot, which `[start, end)` calendar-day intervals have been processed, in the `sqlmesh_state` schema. A second `sqlmesh run` reads that state and computes only newly-due days — see "Verified" below for the actual proof. |
| `marts.engagement_summary`      | `FULL`                     | A downstream FULL model reading an incremental model's *cumulative* output — proves a full-refresh model correctly reflects everything an incremental model has accumulated so far, not just its latest batch. |

Every model file carries a comment explaining what it's there to exercise — this repo is a teaching
fixture as much as a test fixture.

Seed dates are fixed (2026-08-20 through 2026-08-29) rather than relative to "today," so the
project's own history is reproducible; the incremental proof below instead uses SQLMesh's
`--execution-time` flag to pretend an earlier "now" for the bootstrap plan, then lets real wall-clock
time supply the "newly due" interval for the first `run`. That is the same technique
`RECON-sqlmesh.md` §6 used, and it is what a real scheduled job does for free (calendar days keep
becoming due) without needing any pretend-time flag at all.

## Local quickstart

Requires a local Postgres reachable with no password by default (override via `PGHOST`/`PGPORT`/
`PGUSER`/`PGPASSWORD`/`PGDATABASE` — see `config.yaml`). Uses your own scratch database; never point
this at `orchestra_app` or any shared warehouse.

```bash
python3.13 -m venv .venv && source .venv/bin/activate
pip install "sqlmesh[postgres]==0.236.1"

createdb sqlmesh_fixture_$$
export PGDATABASE=sqlmesh_fixture_$$

sqlmesh plan --no-prompts --auto-apply prod   # bootstraps state + backfills
sqlmesh run                                   # processes whatever has become due since

# cleanup
dropdb "$PGDATABASE"
deactivate && rm -rf .venv
```

`config.yaml` here is for this local convenience only — see the next section for what production
actually does.

## Production config: your repo still ships `config.yaml` — the platform overrides the connection half

Correction from an earlier draft of this README: **the runner image does not ship a static
`config.yaml`.** The image ships only `entrypoint.sh` and the `sqlmesh_report.py` report emitter —
nothing that could stand in for a project's own config. SQLMesh requires `model_defaults.dialect`
to be set *somewhere*, and nothing in the runner validates or supplies it, so **every SQLMesh
project deployed on Orchestra must carry its own `config.yaml` with `model_defaults` (`dialect` at
minimum) committed in the repo** — exactly like this fixture's own `config.yaml` does.

**Requirements for your repo:** commit a `config.yaml` with at least `model_defaults.dialect` set.
You may also declare `gateways`/`default_gateway` for local development (as this fixture does), but
know that in production those connection-shaped values are overridden, not read — see below.

What the platform *does* override, entirely through SQLMesh's native environment-variable config
layer (no Jinja templating step, no generated `profiles.yml`-equivalent, unlike the dbt path) — per
`SCOPE-runner-sqlmesh.md` decision 1 and `RECON-sqlmesh.md` §4 — is the connection and state half of
the gateway, plus which gateway is authoritative:

```
SQLMESH__DEFAULT_GATEWAY
SQLMESH__GATEWAYS__<gateway>__CONNECTION__*
SQLMESH__GATEWAYS__<gateway>__STATE_CONNECTION__*
SQLMESH__GATEWAYS__<gateway>__STATE_SCHEMA
```

The entrypoint exports `SQLMESH__DEFAULT_GATEWAY` naming the gateway it's about to configure and
maps `ORCHESTRA_WAREHOUSE_*` to the `CONNECTION`/`STATE_CONNECTION`/`STATE_SCHEMA` keys above — this
is what makes the platform's chosen gateway authoritative over whatever `default_gateway` (or
however many other gateways) the repo's own `config.yaml` declares, confirmed live below. SQLMesh
state lives in a dedicated schema (`sqlmesh_state`, per project) of the *customer's own warehouse
database* — never in Orchestra's control plane. The two gateway keys that matter are exactly
`state_connection` and `state_schema` — confirmed real, exact names, in
`sqlmesh/core/config/gateway.py` (`RECON-sqlmesh.md` §4) — and bootstrapping a brand-new, empty
`sqlmesh_state` schema is silent and non-interactive, creating exactly six tables (`_snapshots`,
`_intervals`, `_environments`, `_versions`, `_environment_statements`, `_auto_restatements`).

**Default job commands**: `["sqlmesh run"]`. An earlier draft seeded scheduled jobs with
plan+run on a dbt-parity argument; review reversed it — unattended `plan --auto-apply` promotes
snapshot versions, can rebuild tables on breaking changes, and backfills historical intervals,
which a scheduled `dbt build` never does (the platform's scope doc, decision 2, records the full
reversal). A **new** project therefore needs a one-time bootstrap before its first scheduled run
(see VERIFY 2 below — an unplanned `sqlmesh run` fails with "Environment 'prod' was not found"):

```
sqlmesh plan --no-prompts --auto-apply prod
```

Run it once as a manual job command, then remove it. The platform's job form shows this same
signpost for SQLMesh projects.

## Verified

Run live end-to-end on 2026-08-29/30, against a throwaway local Postgres 14.16 database
(`sqlmesh_fixture_16701`, `createdb`'d for this run and `dropdb`'d immediately after — `orchestra_app`
was never touched, no AWS calls were made), using a Python 3.13 venv with
`sqlmesh[postgres]==0.236.1` (matching `RECON-sqlmesh.md`'s pinned version exactly). Venv and scratch
database were both removed after.

**1. `sqlmesh plan --no-prompts --auto-apply --execution-time "2026-08-28 00:00:00" prod`**
bootstraps state on an empty schema and backfills every model. Pinning `--execution-time` to a
pretend "now" of 2026-08-28 is what leaves 2026-08-28 and 2026-08-29 genuinely undone, so the very
next `run` (below) has real newly-due work rather than none:

```
Initializing new project state...

**`prod` environment will be initialized**

**Models needing backfill:**
* `marts.daily_active_users`: [2026-08-20 - 2026-08-27]
* `marts.engagement_summary`: [full refresh]
* `raw.raw_page_views`: [full refresh]
* `staging.stg_page_views`: [full refresh]

[1/1] raw.raw_page_views         [insert seed file (30 rows)]
[1/1] staging.stg_page_views     [full refresh (30 rows)]
[1/1] marts.daily_active_users   [insert 2026-08-20 - 2026-08-27 (8 rows)]
[1/1] marts.engagement_summary   [full refresh (1 row)]
Virtual layer updated
```

`echo $?` → **0**.

**2. First `sqlmesh run`** (no flags — the actual command a scheduled job issues), at real wall-clock
time (2026-08-30 01:20 UTC, i.e. after both 2026-08-28's and 2026-08-29's daily intervals had
genuinely elapsed):

```
[1/1] staging.stg_page_views     [full refresh (30 rows)]
[1/1] marts.daily_active_users   [insert 2026-08-28 - 2026-08-29 (2 rows)]
[1/1] marts.engagement_summary   [full refresh (1 row)]
Run finished for environment 'prod'
```

`echo $?` → **0**. This is the incremental model processing exactly the two days that were left
undone by step 1's pretend-time plan — not the eight days already backfilled.

**3. Second `sqlmesh run`**, issued immediately after step 2 with no time elapsed, real wall-clock
time again:

```
No models are ready to run. Please wait until a model `cron` interval has
elapsed.

Next run will be ready at 2026-08-30 08:00PM EDT (2026-08-31 12:00AM UTC).
```

`echo $?` → **0**. Nothing was due, so nothing ran — the other half of the same proof: `run` isn't
merely idempotent by accident, it consults state and finds no new interval, exactly as
`RECON-sqlmesh.md` §6 describes for this exact scenario.

**State, read through the Tier-2 `Context`/`Snapshot` API** (`RECON-sqlmesh.md` §1 — never the raw
`_intervals` table for anything but manual inspection), confirming the incremental model's recorded
interval spans the full backfilled+incrementally-extended range after step 2:

```python
from sqlmesh import Context
ctx = Context(paths='.')
snap = ctx.get_snapshot('marts.daily_active_users', raise_if_missing=True)
snap.intervals
# [(1787184000000, 1788048000000)]   # 2026-08-20T00:00Z .. 2026-08-30T00:00Z
```

State bootstrap created exactly the six tables the recon predicted:

```
$ psql -d sqlmesh_fixture_16701 -c '\dt sqlmesh_state.*'
_auto_restatements | _environment_statements | _environments | _intervals | _snapshots | _versions
```

### Where this fixture's own run differed from what the recon documented

One real divergence worth flagging loudly, found only by actually running the second-run proof
end to end rather than trusting the recon's description of it:

**`RECON-sqlmesh.md` §6 shows the raw `sqlmesh_state._intervals` table growing a *second row* with a
distinct, later `created_ts` when a second run adds a newly-due, calendar-adjacent interval, with the
first row's `created_ts` left unchanged.** Querying the same raw table after this fixture's step 2
instead showed **one row per model**, its `start_ts`/`end_ts` already merged to cover the entire
2026-08-20..2026-08-30 span, and its `created_ts` matching the *second* write (the `run`), not the
first (the `plan`) — i.e. the pre-existing row was rewritten/compacted in place rather than a sibling
row being appended next to it:

```
$ psql -d sqlmesh_fixture_16701 -c "select name, start_ts, end_ts, created_ts from sqlmesh_state._intervals where name like '%daily_active_users%';"
                        name                          |   start_ts    |    end_ts     |  created_ts
-------------------------------------------------------+---------------+---------------+---------------
 "sqlmesh_fixture_16701"."marts"."daily_active_users"  | 1787184000000 | 1788048000000 | 1788052832038
(1 row)
```

This does **not** contradict the higher-level claim that matters (a second run only computes
newly-due intervals — the console output in step 2 above, `[insert 2026-08-28 - 2026-08-29 (2
rows)]`, is direct, unambiguous proof of exactly that, and matches recon's console-output findings
exactly). What it does contradict is the specific row-count/compaction detail of the *raw* state
table's shape — SQLMesh appears to merge newly-added, calendar-contiguous intervals into an existing
row rather than always appending a new one, at least in this version/configuration. This is, if
anything, a confirmation of the recon's own caution one layer up: it explicitly warns "do not assert
on row counts in `_intervals` directly (Tier 3, no compatibility guarantee); assert on the
`Snapshot.intervals` value returned by the public-ish `Context` surface" instead — advice this
fixture's own run just validated was necessary, since the raw-table shape it predicted didn't
reproduce here. Anyone writing the report-emitter's "what did this run just do" diff logic should
snapshot `Snapshot.intervals` (or `max_interval_end_per_model`) before/after, per the recon's own
recommendation — not count rows in `_intervals`.

No other divergence from `RECON-sqlmesh.md` was found: exit codes, the plan/run console text shape,
the six bootstrapped state tables, the `state_connection`/`state_schema` config keys, and the
`SQLMESH__GATEWAYS__...` env-var merge behavior all matched exactly as documented.

### Review-round follow-ups, also run live

Two more things a review round flagged as unverified inference rather than checked fact. Both were
run against fresh throwaway Postgres databases (`sqlmesh_fixture_45185`, `_45185_b`, `_45185_c` —
all `createdb`'d and `dropdb`'d for this session only; `orchestra_app` untouched, no AWS calls), same
venv/`sqlmesh[postgres]==0.236.1` pin as above.

**VERIFY 1 — does `SQLMESH__DEFAULT_GATEWAY` actually override a repo `config.yaml` whose
`default_gateway` names a different, working gateway?** This is the load-bearing claim behind "the
platform's chosen gateway wins over the repo's" above, so it needed the adversarial case, not just
the merge-behavior recon already confirmed for leaf keys. Built a throwaway project with **two**
fully-working Postgres gateways in one `config.yaml`:

```yaml
gateways:
  gw_a: { connection: {... database: sqlmesh_fixture_45185 ...}, state_schema: sqlmesh_state_gw_a }
  gw_b: { connection: {... database: sqlmesh_fixture_45185_b ...}, state_schema: sqlmesh_state_gw_b }
default_gateway: gw_a
```

Baseline, no env var — `sqlmesh plan --no-prompts --auto-apply prod` uses `gw_a` as the config
declares:

```
$ sqlmesh plan --no-prompts --auto-apply prod
Initializing new project state...
**`prod` environment will be initialized**
...
Virtual layer updated
$ echo $?
0
```

```
$ psql -d sqlmesh_fixture_45185   -c '\dn'   # gw_a's db: populated
marts | raw | staging | sqlmesh__marts | sqlmesh__raw | sqlmesh__staging | sqlmesh_state_gw_a
$ psql -d sqlmesh_fixture_45185_b -c '\dn'   # gw_b's db: empty (only "public")
public
```

Adversarial case — same project, same `config.yaml` (still `default_gateway: gw_a`), but
`SQLMESH__DEFAULT_GATEWAY=gw_b` exported before the identical command:

```
$ SQLMESH__DEFAULT_GATEWAY=gw_b sqlmesh plan --no-prompts --auto-apply prod
Initializing new project state...
**`prod` environment will be initialized**
...
Virtual layer updated
$ echo $?
0
```

```
$ psql -d sqlmesh_fixture_45185   -c '\dn'   # gw_a's db: UNCHANGED from before
marts | raw | staging | sqlmesh__marts | sqlmesh__raw | sqlmesh__staging | sqlmesh_state_gw_a
$ psql -d sqlmesh_fixture_45185_b -c '\dn'   # gw_b's db: NOW populated
marts | raw | staging | sqlmesh__marts | sqlmesh__raw | sqlmesh__staging | sqlmesh_state_gw_b
```

**Result: confirmed, unambiguously.** `SQLMESH__DEFAULT_GATEWAY=gw_b` won over the repo's
`default_gateway: gw_a` — the entire plan (schemas, tables, state) landed in `gw_b`'s database
(`sqlmesh_fixture_45185_b`, schema `sqlmesh_state_gw_b`) instead of `gw_a`'s, and `gw_a`'s database
from the baseline run was left completely untouched by the second invocation. This is exactly what
lets the platform's `ORCHESTRA_WAREHOUSE_*`-derived gateway be authoritative regardless of what a
repo's own `config.yaml` declares as its default — no divergence from expectation here.

**VERIFY 2 — what does `sqlmesh run prod` do against a project whose state schema has never had
`plan` applied?** This decides how the platform's very-first-run failure reads if a job's `run` step
somehow executes before its `plan` step (misconfiguration, race, or a `plan` that errored out
without the operator noticing). Fresh scratch database (`sqlmesh_fixture_45185_c`), this fixture's
real single-gateway `config.yaml`, **no prior `plan` invocation of any kind**:

```
$ sqlmesh run prod
Initializing new project state...
Error: Environment 'prod' was not found.
$ echo $?
1
```

**Result: exit 1, message `Error: Environment 'prod' was not found.`** — a clean, immediate,
human-readable failure naming the actual problem (no environment has ever been promoted), not a
hang, a silent no-op, or a stack trace. One nuance worth carrying into the entrypoint/ingest design:
SQLMesh still bootstraps the **state schema itself** before hitting that error —

```
$ psql -d sqlmesh_fixture_45185_c -c '\dt sqlmesh_state.*'
_auto_restatements | _environment_statements | _environments | _intervals | _snapshots | _versions
```

— all six tables exist, empty, even though the command failed. So "state schema exists" is not
proof a project was ever successfully planned; only a promoted environment is. This matches the
"`run` never silently does the `plan`'s job" behavior `RECON-sqlmesh.md` §2 already established
(editing a model and calling `run` without an intervening `plan` has zero effect) — here extended to
the more extreme case of *no* environment existing at all — so no divergence from what the recon's
overall model of `run` would predict, just a fact the recon didn't explicitly execute.
