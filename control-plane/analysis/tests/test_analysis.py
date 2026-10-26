"""Tests for Doppio Analysis module."""

import sys
sys.path.insert(0, 'C:/Users/Rizqi/Documents/Default Project/doppio/control-plane')

import numpy as np
from analysis import (
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


def test_proportion_ztest():
    """Test two-proportion z-test."""
    # Significant difference
    r = proportion_ztest(100, 1000, 120, 1000, alpha=0.05)
    assert isinstance(r, FrequentistResult)
    assert r.method == "proportion_ztest"
    assert 0 <= r.p_value <= 1
    
    # No difference
    r = proportion_ztest(100, 1000, 100, 1000)
    assert r.p_value == 1.0 or abs(r.statistic) < 1e-10
    
    # Edge case: zero conversions
    r = proportion_ztest(0, 100, 0, 100)
    assert r.p_value == 1.0
    
    # Edge case: full conversions
    r = proportion_ztest(100, 100, 100, 100)
    assert r.p_value == 1.0
    
    print("test_proportion_ztest PASSED")


def test_ttest_independent():
    """Test independent t-test."""
    np.random.seed(42)
    vals_a = np.random.normal(10, 2, 100).tolist()
    vals_b = np.random.normal(11, 2, 100).tolist()
    
    r = ttest_independent(vals_a, vals_b)
    assert isinstance(r, FrequentistResult)
    assert r.method == "ttest_independent"
    assert r.significant == (r.p_value < 0.05)
    
    # Equal variance
    r = ttest_independent(vals_a, vals_b, equal_var=True)
    assert r.method == "ttest_independent"
    
    # Alternative hypotheses
    r = ttest_independent(vals_a, vals_b, alternative="greater")
    assert r.p_value >= 0
    
    r = ttest_independent(vals_a, vals_b, alternative="less")
    assert r.p_value >= 0
    
    # Edge case: identical values (zero variance)
    r = ttest_independent([10, 10, 10], [10, 10, 10])
    assert r.statistic == 0.0
    assert r.p_value == 1.0
    
    # Edge case: zero variance but different means
    r = ttest_independent([10, 10, 10], [20, 20, 20])
    assert r.significant == True
    assert r.p_value == 0.0
    
    # Edge case: too few samples
    r = ttest_independent([10], [20])
    assert r.p_value == 1.0
    
    print("test_ttest_independent PASSED")


def test_chi_square_test():
    """Test chi-square test of independence."""
    # 2x2 table: [[success_a, fail_a], [success_b, fail_b]]
    r = chi_square_test([[100, 900], [120, 880]])
    assert isinstance(r, FrequentistResult)
    assert r.method == "chi_square"
    assert r.p_value >= 0
    
    # No association
    r = chi_square_test([[100, 900], [100, 900]])
    assert r.p_value == 1.0 or r.statistic == 0.0
    
    print("test_chi_square_test PASSED")


def test_sequential_test_alpha_spending():
    """Test alpha spending for sequential testing."""
    # O'Brien-Fleming
    alphas = sequential_test_alpha_spending(0.05, 3, "obrien_fleming")
    assert len(alphas) == 3
    assert alphas[0] < alphas[1] < alphas[2]
    assert sum(alphas) <= 0.05 * 2  # Roughly
    
    # Pocock
    alphas = sequential_test_alpha_spending(0.05, 3, "pocock")
    assert len(alphas) == 3
    assert abs(alphas[0] - alphas[1]) < 1e-10
    
    print("test_sequential_test_alpha_spending PASSED")


def test_bayesian_beta_binomial():
    """Test Bayesian Beta-Binomial."""
    r = bayesian_beta_binomial(100, 1000, 120, 1000, n_samples=10000)
    assert isinstance(r, BayesianResult)
    assert r.method == "bayesian_beta_binomial"
    assert 0 <= r.prob_superior <= 1
    assert r.hdi_lower <= r.hdi_upper
    
    # Edge case: zero conversions
    r = bayesian_beta_binomial(0, 100, 0, 100, n_samples=10000)
    assert abs(r.prob_superior - 0.5) < 0.05  # Symmetric prior
    
    print("test_bayesian_beta_binomial PASSED")


def test_bayesian_gaussian():
    """Test Bayesian Gaussian."""
    np.random.seed(42)
    vals_a = np.random.normal(10, 2, 100).tolist()
    vals_b = np.random.normal(11, 2, 100).tolist()
    
    r = bayesian_gaussian(vals_a, vals_b, n_samples=10000)
    assert isinstance(r, BayesianResult)
    assert r.method == "bayesian_gaussian"
    assert 0 <= r.prob_superior <= 1
    assert r.hdi_lower <= r.hdi_upper
    
    # Edge case: zero variance
    r = bayesian_gaussian([10, 10, 10], [20, 20, 20], n_samples=10000)
    assert r.prob_superior >= 0  # Should work without error
    
    # Edge case: too few samples
    r = bayesian_gaussian([10], [20], n_samples=10000)
    assert r.prob_superior == 0.5
    
    print("test_bayesian_gaussian PASSED")


def test_power_analysis_proportion():
    """Test power analysis for proportions."""
    r = power_analysis_proportion(0.1, 0.02, alpha=0.05, power=0.8)
    assert isinstance(r, PowerAnalysisResult)
    assert r.method == "power_analysis_proportion"
    assert r.required_sample_size > 0
    assert 0 < r.achieved_power <= 1
    
    # Edge case: zero effect
    r = power_analysis_proportion(0.1, 0.0)
    assert r.required_sample_size == 0
    assert r.achieved_power == 0.0
    
    print("test_power_analysis_proportion PASSED")


def test_power_analysis_mean():
    """Test power analysis for continuous metrics."""
    r = power_analysis_mean(0.5, alpha=0.05, power=0.8)
    assert isinstance(r, PowerAnalysisResult)
    assert r.method == "power_analysis_mean"
    assert r.required_sample_size > 0
    assert 0 < r.achieved_power <= 1
    
    # Edge case: zero effect
    r = power_analysis_mean(0.0)
    assert r.required_sample_size == 0
    assert r.achieved_power == 0.0
    
    print("test_power_analysis_mean PASSED")


def test_check_guardrail():
    """Test guardrail check."""
    # Decrease guardrail - should pass (5% decrease, threshold 5%)
    r = check_guardrail('revenue', 100.0, 95.0, 0.05, 'decrease')
    assert isinstance(r, GuardrailResult)
    assert r.passed == True
    
    # Decrease guardrail - should fail (10% decrease, threshold 5%)
    r = check_guardrail('revenue', 100.0, 90.0, 0.05, 'decrease')
    assert r.passed == False
    
    # Increase guardrail - should pass (5% increase, threshold 10%)
    r = check_guardrail('error_rate', 10.0, 10.5, 0.10, 'increase')
    assert r.passed == True
    
    # Increase guardrail - should fail (20% increase, threshold 10%)
    r = check_guardrail('error_rate', 10.0, 12.0, 0.10, 'increase')
    assert r.passed == False
    
    print("test_check_guardrail PASSED")


def test_evaluate_experiment():
    """Test full experiment evaluation."""
    # Conversion only
    results = evaluate_experiment(conv_a=100, n_a=1000, conv_b=120, n_b=1000)
    assert 'conversion_frequentist' in results
    assert 'conversion_bayesian' in results
    assert 'power_posthoc' in results
    
    # Continuous only
    np.random.seed(42)
    vals_a = np.random.normal(10, 2, 100).tolist()
    vals_b = np.random.normal(11, 2, 100).tolist()
    results = evaluate_experiment(values_a=vals_a, values_b=vals_b)
    assert 'continuous_frequentist' in results
    assert 'continuous_bayesian' in results
    assert 'power_continuous' in results
    
    # Both
    results = evaluate_experiment(
        conv_a=100, n_a=1000, conv_b=120, n_b=1000,
        values_a=vals_a, values_b=vals_b,
        guardrails=[{'metric_name': 'rev', 'control_value': 100, 'treatment_value': 95, 'threshold': 0.05, 'direction': 'decrease'}]
    )
    assert 'guardrails' in results
    assert len(results['guardrails']) == 1
    
    print("test_evaluate_experiment PASSED")


if __name__ == "__main__":
    test_proportion_ztest()
    test_ttest_independent()
    test_chi_square_test()
    test_sequential_test_alpha_spending()
    test_bayesian_beta_binomial()
    test_bayesian_gaussian()
    test_power_analysis_proportion()
    test_power_analysis_mean()
    test_check_guardrail()
    test_evaluate_experiment()
    print("\nALL TESTS PASSED!")