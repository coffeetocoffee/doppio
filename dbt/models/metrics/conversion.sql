select
    flag_key,
    variation,
    count(*) as exposures,
    sum(case when reason = 'TARGET_MATCH' then 1 else 0 end) as conversions
from {{ ref('fct_exposures') }}
group by flag_key, variation