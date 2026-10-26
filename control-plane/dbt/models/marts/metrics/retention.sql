{{
  config(
    materialized='table',
    tags=['marts', 'metrics', 'retention']
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
activity_events as (
  select
    e.workspace_id,
    e.environment_id,
    e.unit_id,
    e.occurred_at_ts as event_at
  from {{ ref('stg_exposures') }} e
  where e.reason in ('default', 'targeting', 'rollout', 'experiment')
),
unit_activity as (
  select
    eu.experiment_key,
    eu.workspace_id,
    eu.environment_id,
    eu.unit_id,
    eu.assigned_variation,
    eu.assigned_at,
    count(distinct date(ae.event_at)) as active_days,
    min(ae.event_at) as first_activity,
    max(ae.event_at) as last_activity
  from experiment_units eu
  left join activity_events ae
    on eu.workspace_id = ae.workspace_id
    and eu.environment_id = ae.environment_id
    and eu.unit_id = ae.unit_id
    and ae.event_at >= eu.assigned_at
  group by eu.experiment_key, eu.workspace_id, eu.environment_id, eu.unit_id, eu.assigned_variation, eu.assigned_at
),
retention_windows as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    assigned_variation,
    -- Day 1 retention
    sum(case when julianday(last_activity) - julianday(assigned_at) >= 1 then 1 else 0 end) as retained_d1,
    -- Day 7 retention
    sum(case when julianday(last_activity) - julianday(assigned_at) >= 7 then 1 else 0 end) as retained_d7,
    -- Day 30 retention
    sum(case when julianday(last_activity) - julianday(assigned_at) >= 30 then 1 else 0 end) as retained_d30,
    count(*) as total_units
  from unit_activity
  group by experiment_key, workspace_id, environment_id, assigned_variation
)
select
  experiment_key,
  workspace_id,
  environment_id,
  assigned_variation,
  total_units,
  retained_d1,
  cast(retained_d1 as real) / nullif(total_units, 0) as retention_d1,
  retained_d7,
  cast(retained_d7 as real) / nullif(total_units, 0) as retention_d7,
  retained_d30,
  cast(retained_d30 as real) / nullif(total_units, 0) as retention_d30
from retention_windows