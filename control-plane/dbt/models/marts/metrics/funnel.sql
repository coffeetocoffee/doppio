{{
  config(
    materialized='table',
    tags=['marts', 'metrics', 'funnel']
  )
}}

with experiment_units as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    unit_id,
    assigned_variation,
    assigned_at
  from {{ ref('experiment_assignments') }}
  where is_multi_variant = true
),
step_events as (
  select
    e.workspace_id,
    e.environment_id,
    e.flag_key as experiment_key,
    e.unit_id,
    e.occurred_at_ts as event_at,
    e.reason as step_name
  from {{ ref('stg_exposures') }} e
  where e.reason in ('step_1', 'step_2', 'step_3', 'step_4', 'step_5')
),
unit_steps as (
  select
    eu.experiment_key,
    eu.workspace_id,
    eu.environment_id,
    eu.unit_id,
    eu.assigned_variation,
    eu.assigned_at,
    se.step_name,
    min(se.event_at) as step_at
  from experiment_units eu
  left join step_events se
    on eu.workspace_id = se.workspace_id
    and eu.environment_id = se.environment_id
    and eu.experiment_key = se.experiment_key
    and eu.unit_id = se.unit_id
    and se.event_at >= eu.assigned_at
  group by eu.experiment_key, eu.workspace_id, eu.environment_id, eu.unit_id, eu.assigned_variation, eu.assigned_at, se.step_name
),
funnel_agg as (
  select
    experiment_key,
    workspace_id,
    environment_id,
    assigned_variation,
    step_name,
    count(distinct unit_id) as units_reached,
    min(step_at) as first_step_at,
    max(step_at) as last_step_at
  from unit_steps
  where step_name is not null
  group by experiment_key, workspace_id, environment_id, assigned_variation, step_name
)
select
  fa.experiment_key,
  fa.workspace_id,
  fa.environment_id,
  fa.assigned_variation,
  fa.step_name,
  fa.units_reached,
  cast(fa.units_reached as real) / nullif(first_step.units_reached, 0) as conversion_from_start,
  cast(fa.units_reached as real) / nullif(lag(fa.units_reached) over (partition by fa.experiment_key, fa.workspace_id, fa.environment_id, fa.assigned_variation order by fa.step_name), 0) as conversion_from_prev,
  fa.first_step_at,
  fa.last_step_at
from funnel_agg fa
left join funnel_agg first_step
  on fa.experiment_key = first_step.experiment_key
  and fa.workspace_id = first_step.workspace_id
  and fa.environment_id = first_step.environment_id
  and fa.assigned_variation = first_step.assigned_variation
  and first_step.step_name = 'step_1'
order by fa.experiment_key, fa.workspace_id, fa.environment_id, fa.assigned_variation, fa.step_name