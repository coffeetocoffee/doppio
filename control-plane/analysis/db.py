"""
Database query layer for Doppio Analysis.

Queries the SQLite database directly (bypassing dbt) for analysis.
In production, this would query the dbt materialized tables.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Optional
from pathlib import Path

from .analysis import (
    evaluate_experiment,
    FrequentistResult,
    BayesianResult,
    PowerAnalysisResult,
    GuardrailResult,
)


@dataclass
class ExperimentData:
    """Raw experiment data pulled from database."""
    experiment_key: str
    workspace_id: str
    environment_id: str
    # Conversion data
    control_conversions: int
    control_units: int
    treatment_conversions: int
    treatment_units: int
    # Continuous metric data
    control_values: list[float]
    treatment_values: list[float]
    # Guardrails
    guardrails: list[dict]


def fetch_experiment_data(
    db_path: str,
    experiment_key: str,
    workspace_id: str = "default",
    environment_id: str = "default"
) -> ExperimentData:
    """
    Fetch experiment data from SQLite database.
    
    Queries the raw exposures table directly.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    # Get experiment assignments (units assigned to variations)
    cursor.execute("""
        SELECT unit_id, assigned_variation
        FROM experiment_assignments
        WHERE experiment_key = ? AND workspace_id = ? AND environment_id = ?
        AND is_multi_variant = 1
    """, (experiment_key, workspace_id, environment_id))
    
    assignments = cursor.fetchall()
    if not assignments:
        conn.close()
        raise ValueError(f"No experiment assignments found for {experiment_key}")
    
    # Group units by variation
    control_units = []
    treatment_units = []
    for row in assignments:
        if row['assigned_variation'] == 'control':
            control_units.append(row['unit_id'])
        else:
            treatment_units.append(row['unit_id'])
    
    control_unit_list = ','.join('?' * len(control_units)) if control_units else "''"
    treatment_unit_list = ','.join('?' * len(treatment_units)) if treatment_units else "''"
    
    # Get conversion events
    control_conversions = 0
    treatment_conversions = 0
    
    if control_units:
        cursor.execute(f"""
            SELECT COUNT(DISTINCT unit_id) as cnt
            FROM exposures
            WHERE workspace_id = ? AND environment_id = ? AND flag_key = ?
            AND reason = 'conversion' AND unit_id IN ({control_unit_list})
        """, [workspace_id, environment_id, experiment_key] + control_units)
        control_conversions = cursor.fetchone()['cnt']
    
    if treatment_units:
        cursor.execute(f"""
            SELECT COUNT(DISTINCT unit_id) as cnt
            FROM exposures
            WHERE workspace_id = ? AND environment_id = ? AND flag_key = ?
            AND reason = 'conversion' AND unit_id IN ({treatment_unit_list})
        """, [workspace_id, environment_id, experiment_key] + treatment_units)
        treatment_conversions = cursor.fetchone()['cnt']
    
    # Get continuous metric values
    control_values = []
    treatment_values = []
    
    if control_units:
        cursor.execute(f"""
            SELECT bucket as metric_value
            FROM exposures
            WHERE workspace_id = ? AND environment_id = ? AND flag_key = ?
            AND reason = 'metric' AND unit_id IN ({control_unit_list})
        """, [workspace_id, environment_id, experiment_key] + control_units)
        control_values = [row['metric_value'] for row in cursor.fetchall()]
    
    if treatment_units:
        cursor.execute(f"""
            SELECT bucket as metric_value
            FROM exposures
            WHERE workspace_id = ? AND environment_id = ? AND flag_key = ?
            AND reason = 'metric' AND unit_id IN ({treatment_unit_list})
        """, [workspace_id, environment_id, experiment_key] + treatment_units)
        treatment_values = [row['metric_value'] for row in cursor.fetchall()]
    
    conn.close()
    
    return ExperimentData(
        experiment_key=experiment_key,
        workspace_id=workspace_id,
        environment_id=environment_id,
        control_conversions=control_conversions,
        control_units=len(control_units),
        treatment_conversions=treatment_conversions,
        treatment_units=len(treatment_units),
        control_values=control_values,
        treatment_values=treatment_values,
        guardrails=[]
    )


def run_analysis(
    db_path: str,
    experiment_key: str,
    workspace_id: str = "default",
    environment_id: str = "default",
    guardrails: Optional[list[dict]] = None,
    alpha: float = 0.05
) -> dict:
    """
    Run full statistical analysis for an experiment.
    
    Returns dict with all analysis results.
    """
    data = fetch_experiment_data(db_path, experiment_key, workspace_id, environment_id)
    
    results = evaluate_experiment(
        conv_a=data.control_conversions,
        n_a=data.control_units,
        conv_b=data.treatment_conversions,
        n_b=data.treatment_units,
        values_a=data.control_values if data.control_values else None,
        values_b=data.treatment_values if data.treatment_values else None,
        guardrails=guardrails,
        alpha=alpha
    )
    
    # Add metadata
    results['metadata'] = {
        'experiment_key': experiment_key,
        'workspace_id': workspace_id,
        'environment_id': environment_id,
        'control_units': data.control_units,
        'treatment_units': data.treatment_units,
        'control_conversions': data.control_conversions,
        'treatment_conversions': data.treatment_conversions,
        'control_metric_count': len(data.control_values),
        'treatment_metric_count': len(data.treatment_values),
    }
    
    return results


def format_result(result: dict) -> str:
    """Format analysis results for human-readable output."""
    lines = []
    meta = result.get('metadata', {})
    lines.append(f"=== Experiment Analysis: {meta.get('experiment_key', 'unknown')} ===")
    lines.append(f"Workspace: {meta.get('workspace_id')}, Environment: {meta.get('environment_id')}")
    lines.append(f"Control: {meta.get('control_units')} units, {meta.get('control_conversions')} conversions")
    lines.append(f"Treatment: {meta.get('treatment_units')} units, {meta.get('treatment_conversions')} conversions")
    lines.append("")
    
    # Conversion frequentist
    if 'conversion_frequentist' in result:
        r = result['conversion_frequentist']
        lines.append("CONVERSION (Frequentist - Two-Proportion Z-Test):")
        lines.append(f"  z = {r.statistic:.4f}, p = {r.p_value:.6f}")
        lines.append(f"  95% CI for diff: [{r.ci_lower:.4f}, {r.ci_upper:.4f}]")
        lines.append(f"  Significant: {'YES' if r.significant else 'NO'}")
        lines.append("")
    
    # Conversion bayesian
    if 'conversion_bayesian' in result:
        r = result['conversion_bayesian']
        lines.append("CONVERSION (Bayesian - Beta-Binomial):")
        lines.append(f"  Posterior mean diff: {r.posterior_mean:.4f}")
        lines.append(f"  95% HDI: [{r.hdi_lower:.4f}, {r.hdi_upper:.4f}]")
        lines.append(f"  P(A > B): {r.prob_superior:.4f}")
        lines.append("")
    
    # Continuous frequentist
    if 'continuous_frequentist' in result:
        r = result['continuous_frequentist']
        lines.append("CONTINUOUS METRIC (Frequentist - Welch's t-test):")
        lines.append(f"  t = {r.statistic:.4f}, p = {r.p_value:.6f}")
        lines.append(f"  95% CI for mean diff: [{r.ci_lower:.4f}, {r.ci_upper:.4f}]")
        lines.append(f"  Significant: {'YES' if r.significant else 'NO'}")
        lines.append("")
    
    # Continuous bayesian
    if 'continuous_bayesian' in result:
        r = result['continuous_bayesian']
        lines.append("CONTINUOUS METRIC (Bayesian - Gaussian):")
        lines.append(f"  Posterior mean diff: {r.posterior_mean:.4f}")
        lines.append(f"  95% HDI: [{r.hdi_lower:.4f}, {r.hdi_upper:.4f}]")
        lines.append(f"  P(A > B): {r.prob_superior:.4f}")
        lines.append("")
    
    # Power analysis
    if 'power_posthoc' in result:
        r = result['power_posthoc']
        lines.append("POWER ANALYSIS (Post-hoc - Conversion):")
        lines.append(f"  Required n per group: {r.required_sample_size}")
        lines.append(f"  MDE: {r.minimum_detectable_effect:.4f}")
        lines.append(f"  Achieved power: {r.achieved_power:.4f}")
        lines.append("")
    
    if 'power_continuous' in result:
        r = result['power_continuous']
        lines.append("POWER ANALYSIS (Post-hoc - Continuous):")
        lines.append(f"  Required n per group: {r.required_sample_size}")
        lines.append(f"  Effect size (Cohen's d): {r.minimum_detectable_effect:.4f}")
        lines.append(f"  Achieved power: {r.achieved_power:.4f}")
        lines.append("")
    
    # Guardrails
    if 'guardrails' in result and result['guardrails']:
        lines.append("GUARDRAILS:")
        for g in result['guardrails']:
            status = "PASS" if g.passed else "FAIL"
            lines.append(f"  {g.metric_name}: {status} (change={g.relative_change:.2%}, threshold={g.threshold:.2%}, dir={g.direction})")
        lines.append("")
    
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 3:
        print("Usage: python -m doppio_analysis.db <db_path> <experiment_key> [workspace] [environment]")
        sys.exit(1)
    
    db_path = sys.argv[1]
    experiment_key = sys.argv[2]
    workspace_id = sys.argv[3] if len(sys.argv) > 3 else "default"
    environment_id = sys.argv[4] if len(sys.argv) > 4 else "default"
    
    if not Path(db_path).exists():
        print(f"Database not found: {db_path}")
        sys.exit(1)
    
    try:
        results = run_analysis(db_path, experiment_key, workspace_id, environment_id)
        print(format_result(results))
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)