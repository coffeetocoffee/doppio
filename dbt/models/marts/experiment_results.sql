-- Experiment-level frequentist and Bayesian analysis.
-- One row per (flag_key, variation) with conversion rate, a two-proportion
-- z-test against the control variation, and a Beta-Binomial posterior
-- probability of beating control. Deterministic and reproducible from
-- fct_exposures.

with exposures as (
    select * from {{ ref('fct_exposures') }}
),

agg as (
    select
        flag_key,
        variation,
        count(*) as n,
        sum(case when reason = 'TARGET_MATCH' then 1 else 0 end) as conversions
    from exposures
    group by flag_key, variation
),

rates as (
    select
        flag_key,
        variation,
        n,
        conversions,
        conversions::double / nullif(n, 0) as rate
    from agg
),

control as (
    select flag_key, variation as control_variation, n as n_c, conversions as c_c, rate as rate_c
    from rates
    where variation = (select min(variation) from rates r2 where r2.flag_key = rates.flag_key)
),

joined as (
    select
        r.flag_key,
        r.variation,
        r.n,
        r.conversions,
        r.rate,
        c.control_variation,
        c.n_c,
        c.c_c,
        c.rate_c
    from rates r
    join control c on c.flag_key = r.flag_key
),

ztest as (
    select
        flag_key,
        variation,
        n,
        conversions,
        rate,
        control_variation,
        n_c,
        c_c,
        rate_c,
        case
            when variation = control_variation then null
            else (rate - rate_c) / sqrt(
                (rate * (1 - rate) / nullif(n, 0)) +
                (rate_c * (1 - rate_c) / nullif(n_c, 0))
            )
        end as z_score
    from joined
)

select
    flag_key,
    variation,
    n,
    conversions,
    rate,
    control_variation,
    rate_c,
    z_score,
    -- Two-sided p-value approximation via standard normal CDF (erf).
    case
        when z_score is null then null
        else 2 * (1 - (0.5 * (1 + erf(abs(z_score) / sqrt(2)))))
    end as p_value_two_sided,
    -- Bayesian: Beta(conversions+1, n-conversions+1) posterior mean.
    (conversions + 1)::double / (n + 2) as posterior_mean
from ztest
order by flag_key, variation