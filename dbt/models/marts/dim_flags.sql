select distinct
    flag_key,
    workspace_id,
    environment_id
from {{ ref('fct_exposures') }}