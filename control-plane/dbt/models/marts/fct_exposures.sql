{{
  config(
    materialized='table',
    tags=['marts']
  )
}}

with exposures as (
  select
    e.id as exposure_id,
    e.workspace_id,
    e.environment_id,
    e.flag_key,
    e.unit_id,
    e.enabled,
    e.variation,
    e.bucket,
    e.reason,
    e.occurred_at_ts,
    e.received_at_ts,
    e.idempotency_key,
    f.traffic_tier
  from {{ ref('stg_exposures') }} e
  left join {{ ref('dim_flags') }} f
    on e.flag_key = f.flag_key
    and e.workspace_id = f.workspace_id
    and e.environment_id = f.environment_id
),
experiment_assignments as (
  select
    exposure_id,
    case
      when reason = 'experiment' then variation
      else null
    end as experiment_variation,
    case
      when reason = 'experiment' then flag_key
      else null
    end as experiment_key
  from exposures
)
select
  e.*,
  ea.experiment_variation,
  ea.experiment_key
from exposures e
left join experiment_assignments ea
  on e.exposure_id = ea.exposure_id