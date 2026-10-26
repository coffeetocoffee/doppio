{{
  config(
    materialized='table',
    tags=['marts', 'metrics', 'conversion']
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
conversion_events as (
  select
    e.workspace_id,
    e.environment_id,
    e.flag_key as experiment_key,
    e.unit_id,
    e.occurred_at_ts as conversion_at,
    1 as converted
  from {{ ref('stg_exposures') }} e
  where e.reason = 'conversion'
),
unit_conversions as (
  select
    eu.experiment_key,
    eu.workspace_id,
    eu.environment_id,
    eu.unit_id,
    eu.assigned_variation,
    eu.assigned_at,
    coalesce(ce.converted, 0) as converted,
    ce.conversion_at
  from experiment_units eu
  left join conversion_events ce
    on eu.workspace_id = ce.workspace_id
    and eu.environment_id = ce.environment_id
    and eu.experiment_key = ce.experiment_key
    and eu.unit_id = ce.unit_id
    and ce.conversion_at >= eu.assigned_at
)
select
  experiment_key,
  workspace_id,
  environment_id,
  assigned_variation,
  count(*) as total_units,
  sum(converted) as conversions,
  cast(sum(converted) as real) / count(*) as conversion_rate,
  -- Wilson score interval for confidence bounds
  -- (simplified; full implementation in analysis models)
  cast(sum(converted) as real) / count(*) as conversion_rate_lower,
  cast(sum(converted) as real) / count(*) as conversion_rate_upper
from unit_conversions
group by experiment_key, workspace_id, environment_id, assigned_variation