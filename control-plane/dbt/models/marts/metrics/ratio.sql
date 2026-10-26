{{
  config(
    materialized='table',
    tags=['marts', 'metrics', 'ratio']
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
    coalesce(sum(me.metric_value), 0) as total_value,
    count(me.metric_value) as event_count
  from experiment_units eu
  left join metric_events me
    on eu.workspace_id = me.workspace_id
    and eu.environment_id = me.environment_id
    and eu.experiment_key = me.experiment_key
    and eu.unit_id = me.unit_id
    and me.event_at >= eu.assigned_at
  group by eu.experiment_key, eu.workspace_id, eu.environment_id, eu.unit_id, eu.assigned_variation, eu.assigned_at
)
select
  experiment_key,
  workspace_id,
  environment_id,
  assigned_variation,
  count(*) as units,
  sum(total_value) as total_value,
  sum(event_count) as total_events,
  cast(sum(total_value) as real) / nullif(sum(event_count), 0) as mean_per_event,
  cast(sum(total_value) as real) / count(*) as mean_per_unit
from unit_metrics
group by experiment_key, workspace_id, environment_id, assigned_variation