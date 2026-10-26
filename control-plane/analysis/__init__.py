"""Doppio Analysis Package"""

from .analysis import (
    proportion_ztest,
    ttest_independent,
    chi_square_test,
    sequential_test_alpha_spending,
    bayesian_beta_binomial,
    bayesian_gaussian,
    power_analysis_proportion,
    power_analysis_mean,
    check_guardrail,
    evaluate_experiment,
    FrequentistResult,
    BayesianResult,
    PowerAnalysisResult,
    GuardrailResult,
)

from .db import (
    fetch_experiment_data,
    run_analysis,
    format_result,
    ExperimentData,
)

__all__ = [
    # Analysis functions
    "proportion_ztest",
    "ttest_independent",
    "chi_square_test",
    "sequential_test_alpha_spending",
    "bayesian_beta_binomial",
    "bayesian_gaussian",
    "power_analysis_proportion",
    "power_analysis_mean",
    "check_guardrail",
    "evaluate_experiment",
    # Result types
    "FrequentistResult",
    "BayesianResult",
    "PowerAnalysisResult",
    "GuardrailResult",
    # DB functions
    "fetch_experiment_data",
    "run_analysis",
    "format_result",
    "ExperimentData",
]

__version__ = "1.0.0"