-- CUPED: variance reduction using pre-experiment covariate
-- Adjusts treatment effect estimate using pre-experiment metric values.
with base as (
    select
        unit_id,
        variant,
        metric_value,
        pre_metric_value
    from {{ ref('fct_exposures') }}
),
stats as (
    select
        avg(pre_metric_value) as theta_cov_mean,
        (covar_samp(metric_value, pre_metric_value) / var_samp(pre_metric_value)) as theta
    from base
),
adjusted as (
    select
        b.unit_id,
        b.variant,
        b.metric_value - (s.theta * (b.pre_metric_value - s.theta_cov_mean)) as adjusted_metric
    from base b cross join stats s
)
select
    variant,
    avg(adjusted_metric) as cuped_mean,
    var_samp(adjusted_metric) as cuped_variance
from adjusted
group by variant