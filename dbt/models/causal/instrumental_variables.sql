-- Instrumental variables: two-stage least squares (simplified)
-- Stage 1: regress treatment on instrument.
-- Stage 2: regress outcome on predicted treatment.
-- Here we provide the first-stage residual and a reduced-form estimate.
with stage1 as (
    select
        unit_id,
        instrument,
        treatment,
        (treatment - avg(treatment) over ()) as t_dev
    from {{ ref('fct_exposures') }}
),
iv as (
    select
        covar_samp(metric_value, instrument) / covar_samp(treatment, instrument) as iv_estimate
    from {{ ref('fct_exposures') }}
)
select iv_estimate from iv