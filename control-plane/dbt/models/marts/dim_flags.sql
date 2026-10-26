{{
  config(
    materialized='table',
    tags=['marts']
  )
}}

with flag_events as (
  select
    flag_key,
    workspace_id,
    environment_id,
    min(occurred_at_ts) as first_seen_at,
    max(occurred_at_ts) as last_seen_at,
    count(*) as exposure_count,
    count(distinct unit_id) as unique_units
  from {{ ref('stg_exposures') }}
  group by flag_key, workspace_id, environment_id
),
flag_config as (
  -- This would ideally join to a flags configuration table
  -- For now, we derive from exposure data
  select
    flag_key,
    workspace_id,
    environment_id,
    first_seen_at,
    last_seen_at,
    exposure_count,
    unique_units,
    case
      when exposure_count > 10000 then 'high'
      when exposure_count > 1000 then 'medium'
      else 'low'
    end as traffic_tier
  from flag_events
)
select *
from flag_config