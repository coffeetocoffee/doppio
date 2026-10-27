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
from {{ source('doppio', 'exposures') }}