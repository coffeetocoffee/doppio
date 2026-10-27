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
    occurred_at::timestamp as occurred_at,
    received_at::timestamp as received_at
from {{ ref('stg_exposures') }}