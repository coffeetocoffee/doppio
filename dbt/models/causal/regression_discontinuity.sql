-- Regression discontinuity: assignment based on threshold
-- Compare units just above vs just below the cutoff.
with rd as (
    select
        unit_id,
        running_var,
        metric_value,
        case when running_var >= 0 then 1 else 0 end as treated
    from {{ ref('fct_exposures') }}
),
binned as (
    select
        treated,
        avg(metric_value) as mean_metric,
        count(*) as n
    from rd
    where abs(running_var) < 0.1  -- bandwidth
    group by treated
)
select
    max(case when treated = 1 then mean_metric end) -
    max(case when treated = 0 then mean_metric end) as rd_estimate
from binned