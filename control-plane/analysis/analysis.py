"""
Doppio Analysis Module

Statistical analysis layer for experimentation results.
All methods are deterministic and reproducible from stored exposures.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional
from scipy import stats
import numpy as np


@dataclass
class FrequentistResult:
    """Result of a frequentist hypothesis test."""
    statistic: float
    p_value: float
    ci_lower: float
    ci_upper: float
    significant: bool
    method: str


@dataclass
class BayesianResult:
    """Result of a Bayesian analysis."""
    posterior_mean: float
    posterior_std: float
    hdi_lower: float
    hdi_upper: float
    prob_superior: float
    method: str


@dataclass
class PowerAnalysisResult:
    """Result of a power analysis."""
    required_sample_size: int
    minimum_detectable_effect: float
    achieved_power: float
    method: str


@dataclass
class GuardrailResult:
    """Result of a guardrail metric check."""
    metric_name: str
    control_value: float
    treatment_value: float
    relative_change: float
    threshold: float
    passed: bool
    direction: str  # "increase" or "decrease"


def proportion_ztest(
    conversions_a: int,
    n_a: int,
    conversions_b: int,
    n_b: int,
    alpha: float = 0.05,
    alternative: str = "two-sided"
) -> FrequentistResult:
    """
    Two-proportion z-test for conversion rates.
    
    H0: p_a = p_b
    H1: p_a != p_b (or >, < depending on alternative)
    """
    p_a = conversions_a / n_a if n_a > 0 else 0
    p_b = conversions_b / n_b if n_b > 0 else 0
    p_pool = (conversions_a + conversions_b) / (n_a + n_b) if (n_a + n_b) > 0 else 0
    
    if p_pool == 0 or p_pool == 1:
        return FrequentistResult(
            statistic=0.0,
            p_value=1.0,
            ci_lower=0.0,
            ci_upper=0.0,
            significant=False,
            method="proportion_ztest"
        )
    
    se = math.sqrt(p_pool * (1 - p_pool) * (1/n_a + 1/n_b))
    z = (p_a - p_b) / se if se > 0 else 0
    
    if alternative == "two-sided":
        p = 2 * (1 - stats.norm.cdf(abs(z)))
    elif alternative == "greater":
        p = 1 - stats.norm.cdf(z)
    else:  # less
        p = stats.norm.cdf(z)
    
    # Wald confidence interval for difference
    diff = p_a - p_b
    se_diff = math.sqrt(p_a*(1-p_a)/n_a + p_b*(1-p_b)/n_b)
    z_alpha = stats.norm.ppf(1 - alpha/2)
    ci_lower = diff - z_alpha * se_diff
    ci_upper = diff + z_alpha * se_diff
    
    return FrequentistResult(
        statistic=z,
        p_value=p,
        ci_lower=ci_lower,
        ci_upper=ci_upper,
        significant=p < alpha,
        method="proportion_ztest"
    )


def ttest_independent(
    values_a: list[float],
    values_b: list[float],
    alpha: float = 0.05,
    equal_var: bool = False,
    alternative: str = "two-sided"
) -> FrequentistResult:
    """
    Independent t-test for continuous metrics (ratio/distribution).
    
    Uses Welch's t-test by default (equal_var=False).
    """
    if len(values_a) < 2 or len(values_b) < 2:
        return FrequentistResult(
            statistic=0.0,
            p_value=1.0,
            ci_lower=0.0,
            ci_upper=0.0,
            significant=False,
            method="ttest_independent"
        )
    
    var_a = np.var(values_a, ddof=1)
    var_b = np.var(values_b, ddof=1)
    
    # Handle zero variance case
    if var_a == 0 and var_b == 0:
        # All values identical in both groups
        diff = np.mean(values_a) - np.mean(values_b)
        return FrequentistResult(
            statistic=0.0 if diff == 0 else float('inf'),
            p_value=1.0 if diff == 0 else 0.0,
            ci_lower=diff,
            ci_upper=diff,
            significant=diff != 0,
            method="ttest_independent"
        )
    
    t_stat, p_val = stats.ttest_ind(
        values_a, values_b, equal_var=equal_var, alternative=alternative
    )
    
    # Confidence interval for mean difference
    mean_a = np.mean(values_a)
    mean_b = np.mean(values_b)
    diff = mean_a - mean_b
    
    if equal_var:
        # Pooled standard error
        n_a, n_b = len(values_a), len(values_b)
        pooled_var = ((n_a - 1) * var_a + (n_b - 1) * var_b) / (n_a + n_b - 2)
        se = math.sqrt(pooled_var * (1/n_a + 1/n_b))
    else:
        # Welch-Satterthwaite
        se = math.sqrt(var_a/len(values_a) + var_b/len(values_b))
    
    t_alpha = stats.t.ppf(1 - alpha/2, len(values_a) + len(values_b) - 2)
    ci_lower = diff - t_alpha * se
    ci_upper = diff + t_alpha * se
    
    return FrequentistResult(
        statistic=t_stat,
        p_value=p_val,
        ci_lower=ci_lower,
        ci_upper=ci_upper,
        significant=p_val < alpha,
        method="ttest_independent"
    )


def chi_square_test(
    observed: list[list[int]],
    alpha: float = 0.05
) -> FrequentistResult:
    """
    Chi-square test of independence for categorical outcomes.
    
    observed: 2D contingency table (e.g., [[success_a, fail_a], [success_b, fail_b]])
    """
    chi2, p, dof, expected = stats.chi2_contingency(observed)
    
    return FrequentistResult(
        statistic=chi2,
        p_value=p,
        ci_lower=0.0,  # Not applicable for chi-square
        ci_upper=0.0,
        significant=p < alpha,
        method="chi_square"
    )


def sequential_test_alpha_spending(
    alpha_total: float = 0.05,
    looks: int = 1,
    spending_function: str = "obrien_fleming"
) -> list[float]:
    """
    Alpha spending for sequential testing (group sequential design).
    
    Returns alpha spent at each look.
    O'Brien-Fleming: conservative early, more alpha at final look.
    Pocock: equal alpha at each look.
    """
    if spending_function == "obrien_fleming":
        # O'Brien-Fleming: alpha_k = 2 - 2*Phi(z_alpha/2 / sqrt(k/K))
        z_total = stats.norm.ppf(1 - alpha_total/2)
        alphas = []
        for k in range(1, looks + 1):
            z_k = z_total / math.sqrt(k / looks)
            alpha_k = 2 * (1 - stats.norm.cdf(z_k))
            alphas.append(alpha_k)
        return alphas
    elif spending_function == "pocock":
        # Equal alpha at each look
        alpha_per_look = 1 - (1 - alpha_total) ** (1 / looks)
        return [alpha_per_look] * looks
    else:
        raise ValueError(f"Unknown spending function: {spending_function}")


def bayesian_beta_binomial(
    conversions_a: int,
    n_a: int,
    conversions_b: int,
    n_b: int,
    prior_alpha: float = 1.0,
    prior_beta: float = 1.0,
    n_samples: int = 100000
) -> BayesianResult:
    """
    Bayesian Beta-Binomial analysis for conversion rates.
    
    Prior: Beta(alpha, beta) - default uniform Beta(1,1)
    Posterior: Beta(alpha + conversions, beta + n - conversions)
    """
    # Posterior parameters
    post_alpha_a = prior_alpha + conversions_a
    post_beta_a = prior_beta + n_a - conversions_a
    post_alpha_b = prior_alpha + conversions_b
    post_beta_b = prior_beta + n_b - conversions_b
    
    # Sample from posteriors
    samples_a = np.random.beta(post_alpha_a, post_beta_a, n_samples)
    samples_b = np.random.beta(post_alpha_b, post_beta_b, n_samples)
    
    diff_samples = samples_a - samples_b
    
    posterior_mean = float(np.mean(diff_samples))
    posterior_std = float(np.std(diff_samples))
    
    # Highest Density Interval (95%)
    hdi_lower = float(np.percentile(diff_samples, 2.5))
    hdi_upper = float(np.percentile(diff_samples, 97.5))
    
    # Probability that A > B
    prob_superior = float(np.mean(diff_samples > 0))
    
    return BayesianResult(
        posterior_mean=posterior_mean,
        posterior_std=posterior_std,
        hdi_lower=hdi_lower,
        hdi_upper=hdi_upper,
        prob_superior=prob_superior,
        method="bayesian_beta_binomial"
    )


def bayesian_gaussian(
    values_a: list[float],
    values_b: list[float],
    prior_mu: float = 0.0,
    prior_sigma: float = 10.0,
    n_samples: int = 100000
) -> BayesianResult:
    """
    Bayesian Gaussian analysis for continuous metrics.
    
    Assumes known variance (uses sample variance), normal prior on mean.
    """
    if len(values_a) < 2 or len(values_b) < 2:
        return BayesianResult(
            posterior_mean=0.0,
            posterior_std=0.0,
            hdi_lower=0.0,
            hdi_upper=0.0,
            prob_superior=0.5,
            method="bayesian_gaussian"
        )
    
    mean_a, mean_b = np.mean(values_a), np.mean(values_b)
    var_a, var_b = np.var(values_a, ddof=1), np.var(values_b, ddof=1)
    n_a, n_b = len(values_a), len(values_b)
    
    # Posterior precision (inverse variance)
    prec_a = n_a / var_a if var_a > 0 else 0
    prec_b = n_b / var_b if var_b > 0 else 0
    prior_prec = 1 / (prior_sigma ** 2)
    
    post_prec_a = prec_a + prior_prec
    post_prec_b = prec_b + prior_prec
    
    post_mu_a = (prec_a * mean_a + prior_prec * prior_mu) / post_prec_a
    post_mu_b = (prec_b * mean_b + prior_prec * prior_mu) / post_prec_b
    
    post_sigma_a = math.sqrt(1 / post_prec_a)
    post_sigma_b = math.sqrt(1 / post_prec_b)
    
    # Sample from posteriors
    samples_a = np.random.normal(post_mu_a, post_sigma_a, n_samples)
    samples_b = np.random.normal(post_mu_b, post_sigma_b, n_samples)
    diff_samples = samples_a - samples_b
    
    posterior_mean = float(np.mean(diff_samples))
    posterior_std = float(np.std(diff_samples))
    hdi_lower = float(np.percentile(diff_samples, 2.5))
    hdi_upper = float(np.percentile(diff_samples, 97.5))
    prob_superior = float(np.mean(diff_samples > 0))
    
    return BayesianResult(
        posterior_mean=posterior_mean,
        posterior_std=posterior_std,
        hdi_lower=hdi_lower,
        hdi_upper=hdi_upper,
        prob_superior=prob_superior,
        method="bayesian_gaussian"
    )


def power_analysis_proportion(
    baseline_rate: float,
    min_detectable_effect: float,
    alpha: float = 0.05,
    power: float = 0.8,
    ratio: float = 1.0
) -> PowerAnalysisResult:
    """
    Power analysis for proportion test.
    
    Returns required sample size per group.
    """
    from statsmodels.stats.proportion import proportion_effectsize
    from statsmodels.stats.power import NormalIndPower
    
    if min_detectable_effect <= 0:
        return PowerAnalysisResult(
            required_sample_size=0,
            minimum_detectable_effect=min_detectable_effect,
            achieved_power=0.0,
            method="power_analysis_proportion"
        )
    
    effect_size = proportion_effectsize(
        baseline_rate, 
        baseline_rate + min_detectable_effect
    )
    
    analysis = NormalIndPower()
    n_per_group = analysis.solve_power(
        effect_size=effect_size,
        nobs1=None,
        alpha=alpha,
        power=power,
        ratio=ratio,
        alternative='two-sided'
    )
    
    n_per_group = int(math.ceil(n_per_group))
    
    # Achieved power with this sample size
    achieved = analysis.solve_power(
        effect_size=effect_size,
        nobs1=n_per_group,
        alpha=alpha,
        power=None,
        ratio=ratio,
        alternative='two-sided'
    )
    
    return PowerAnalysisResult(
        required_sample_size=n_per_group,
        minimum_detectable_effect=min_detectable_effect,
        achieved_power=achieved,
        method="power_analysis_proportion"
    )


def power_analysis_mean(
    effect_size: float,
    alpha: float = 0.05,
    power: float = 0.8,
    ratio: float = 1.0
) -> PowerAnalysisResult:
    """
    Power analysis for t-test (continuous metrics).
    
    effect_size: Cohen's d
    """
    from statsmodels.stats.power import TTestIndPower
    
    if effect_size <= 0:
        return PowerAnalysisResult(
            required_sample_size=0,
            minimum_detectable_effect=effect_size,
            achieved_power=0.0,
            method="power_analysis_mean"
        )
    
    analysis = TTestIndPower()
    n_per_group = analysis.solve_power(
        effect_size=effect_size,
        nobs1=None,
        alpha=alpha,
        power=power,
        ratio=ratio,
        alternative='two-sided'
    )
    
    n_per_group = int(math.ceil(n_per_group))
    
    achieved = analysis.solve_power(
        effect_size=effect_size,
        nobs1=n_per_group,
        alpha=alpha,
        power=None,
        ratio=ratio,
        alternative='two-sided'
    )
    
    return PowerAnalysisResult(
        required_sample_size=n_per_group,
        minimum_detectable_effect=effect_size,
        achieved_power=achieved,
        method="power_analysis_mean"
    )


def check_guardrail(
    metric_name: str,
    control_value: float,
    treatment_value: float,
    threshold: float,
    direction: str = "decrease"
) -> GuardrailResult:
    """
    Check if a guardrail metric regressed.
    
    direction: "decrease" = treatment must not decrease below threshold
               "increase" = treatment must not increase above threshold
    """
    if control_value == 0:
        relative_change = float('inf') if treatment_value > 0 else 0
    else:
        relative_change = (treatment_value - control_value) / control_value
    
    if direction == "decrease":
        # Guardrail: metric should not decrease more than threshold
        # e.g., revenue per user should not drop more than 5%
        passed = relative_change >= -threshold
    else:  # increase
        # Guardrail: metric should not increase more than threshold
        # e.g., error rate should not increase more than 10%
        passed = relative_change <= threshold
    
    return GuardrailResult(
        metric_name=metric_name,
        control_value=control_value,
        treatment_value=treatment_value,
        relative_change=relative_change,
        threshold=threshold,
        passed=passed,
        direction=direction
    )


def evaluate_experiment(
    # Conversion data
    conv_a: int = 0, n_a: int = 0,
    conv_b: int = 0, n_b: int = 0,
    # Continuous metric data
    values_a: Optional[list[float]] = None,
    values_b: Optional[list[float]] = None,
    # Guardrails
    guardrails: Optional[list[dict]] = None,
    # Settings
    alpha: float = 0.05,
    bayesian_samples: int = 100000
) -> dict:
    """
    Full experiment evaluation combining all methods.
    
    Returns dict with frequentist, bayesian, power, and guardrail results.
    """
    results = {}
    
    # Frequentist: conversion
    if n_a > 0 and n_b > 0:
        results['conversion_frequentist'] = proportion_ztest(conv_a, n_a, conv_b, n_b, alpha)
        results['conversion_bayesian'] = bayesian_beta_binomial(conv_a, n_a, conv_b, n_b, n_samples=bayesian_samples)
    
    # Frequentist: continuous
    if values_a is not None and values_b is not None and len(values_a) > 1 and len(values_b) > 1:
        results['continuous_frequentist'] = ttest_independent(values_a, values_b, alpha)
        results['continuous_bayesian'] = bayesian_gaussian(values_a, values_b, n_samples=bayesian_samples)
    
    # Power analysis
    if n_a > 0 and n_b > 0:
        # Post-hoc power
        p_a = conv_a / n_a
        p_b = conv_b / n_b
        mde = abs(p_a - p_b)
        results['power_posthoc'] = power_analysis_proportion(min(p_a, p_b), mde, alpha, power=0.8)
    
    if values_a is not None and values_b is not None and len(values_a) > 1 and len(values_b) > 1:
        # Cohen's d
        pooled_std = math.sqrt((np.var(values_a, ddof=1) + np.var(values_b, ddof=1)) / 2)
        if pooled_std > 0:
            d = abs(np.mean(values_a) - np.mean(values_b)) / pooled_std
            results['power_continuous'] = power_analysis_mean(d, alpha, power=0.8)
    
    # Guardrails
    if guardrails:
        results['guardrails'] = []
        for g in guardrails:
            results['guardrails'].append(check_guardrail(**g))
    
    return results