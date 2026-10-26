{{
  config(
    materialized='view',
    tags=['marts', 'experiment']
  )
}}

with experiment_exposures as (
  select
    flag_key as experiment_key,
    workspace_id,
    environment_id,
    variation as experiment_variation,
    unit_id,
    enabled,
    occurred_at_ts,
    idempotency_key
  from {{ ref('stg_exposures') }}
  where reason = 'experiment'
),
unit_assignment as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    unit_id,
    min(occurred_at_ts) as assigned_at,
    max(case when experiment_variation is not null then experiment_variation end) as assigned_variation,
    count(*) as exposure_count
  from experiment_exposures
  group by experiment_key, workspace_id, environment_id, unit_id
),
variant_counts as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    count(distinct assigned_variation) as variant_count
  from unit_assignment
  group by experiment_key, workspace_id, environment_id
)
select
  ua.experiment_key,
  ua.workspace_id,
  ua.environment_id,
  ua.unit_id,
  ua.assigned_at,
  ua.assigned_variation,
  ua.exposure_count,
  case
    when vc.variant_count > 1 then true
    else false
  end as is_multi_variant
from unit_assignment ua
join variant_counts vc
  on ua.experiment_key = vc.experiment_key
  and ua.workspace_id = vc.workspace_id
  and ua.environment_id = vc.environment_id