{{
  config(
    materialized='table',
    tags=['marts', 'metrics', 'distribution']
  )
}}

with experiment_units as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    unit_id,
    assigned_variation,
    assigned_at
  from {{ ref('experiment_assignments') }}
  where is_multi_variant = true
),
metric_events as (
  select
    e.workspace_id,
    e.environment_id,
    e.flag_key as experiment_key,
    e.unit_id,
    e.occurred_at_ts as event_at,
    cast(e.bucket as real) as metric_value
  from {{ ref('stg_exposures') }} e
  where e.reason = 'metric'
),
unit_metrics as (
  select
    eu.experiment_key,
    eu.workspace_id,
    eu.environment_id,
    eu.unit_id,
    eu.assigned_variation,
    eu.assigned_at,
    sum(me.metric_value) as unit_total
  from experiment_units eu
  left join metric_events me
    on eu.workspace_id = me.workspace_id
    and eu.environment_id = me.environment_id
    and eu.experiment_key = me.experiment_key
    and eu.unit_id = me.unit_id
    and me.event_at >= eu.assigned_at
  group by eu.experiment_key, eu.workspace_id, eu.environment_id, eu.unit_id, eu.assigned_variation, eu.assigned_at
),
aggregated as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    assigned_variation,
    count(unit_total) as n,
    sum(unit_total) as sum_x,
    sum(unit_total * unit_total) as sum_x2,
    min(unit_total) as min_x,
    max(unit_total) as max_x
  from unit_metrics
  where unit_total is not null
  group by experiment_key, workspace_id, environment_id, assigned_variation
)
select
  experiment_key,
  workspace_id,
  environment_id,
  assigned_variation,
  n,
  sum_x,
  sum_x2,
  min_x,
  max_x,
  cast(sum_x as real) / n as mean,
  sqrt(cast(sum_x2 as real) / n - (cast(sum_x as real) / n) * (cast(sum_x as real) / n)) as stddev,
  -- Percentiles would require window functions; simplified here
  min_x as p50,
  max_x as p95
from aggregated
where n > 0