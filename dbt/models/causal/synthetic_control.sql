-- Synthetic control: weighted combination of donors approximates treated unit
-- pre-treatment. Uses simple equal-weight average of donor units.
with donors as (
    select unit_id, avg(metric_value) as donor_mean
    from {{ ref('fct_exposures') }}
    where treatment_group = 0
    group by unit_id
),
treated as (
    select avg(metric_value) as treated_mean
    from {{ ref('fct_exposures') }}
    where treatment_group = 1
),
synth as (
    select avg(donor_mean) as synthetic_mean from donors
)
select
    t.treated_mean,
    s.synthetic_mean,
    t.treated_mean - s.synthetic_mean as gap
from treated t cross join synth s