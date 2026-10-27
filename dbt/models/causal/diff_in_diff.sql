-- Difference-in-differences: staggered rollouts / policy changes
-- Compares change in outcome for treated vs control over time.
with panel as (
    select
        unit_id,
        treatment_group,
        time_period,
        metric_value
    from {{ ref('fct_exposures') }}
),
means as (
    select
        treatment_group,
        time_period,
        avg(metric_value) as mean_metric
    from panel
    group by treatment_group, time_period
),
did as (
    select
        (m1.mean_metric - m0.mean_metric) - (m1b.mean_metric - m0b.mean_metric) as did_estimate
    from means m1, means m0, means m1b, means m0b
    where m1.treatment_group = 1 and m1.time_period = 1
      and m0.treatment_group = 0 and m0.time_period = 1
      and m1b.treatment_group = 1 and m1b.time_period = 0
      and m0b.treatment_group = 0 and m0b.time_period = 0
)
select did_estimate from did