{{
  config(
    materialized='view',
    tags=['staging']
  )
}}

with raw as (
  select
    id,
    workspace_id,
    environment_id,
    flag_key,
    unit_id,
    enabled,
    variation,
    bucket,
    reason,
    occurred_at,
    received_at,
    idempotency_key
  from {{ source('raw', 'exposures') }}
),
cleaned as (
  select
    id,
    workspace_id,
    environment_id,
    flag_key,
    unit_id,
    cast(enabled as boolean) as enabled,
    nullif(variation, '') as variation,
    cast(bucket as integer) as bucket,
    nullif(reason, '') as reason,
    -- Convert unix milliseconds to timestamp
    datetime(occurred_at / 1000.0, 'unixepoch') as occurred_at_ts,
    datetime(received_at / 1000.0, 'unixepoch') as received_at_ts,
    nullif(idempotency_key, '') as idempotency_key
  from raw
)
select *
from cleaned