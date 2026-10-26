"""OpenFeature conformance tests for the Doppio Python SDK.

Based on the OpenFeature specification:
https://openfeature.dev/specification

These tests verify that the DoppioProvider behaves correctly when used
as an OpenFeature provider.
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest
from doppio import Doppio
from doppio.openfeature import DoppioProvider, create_doppio_provider


def test_provider_metadata():
    c = Doppio({"flags": []})
    provider = DoppioProvider(c)
    metadata = provider.get_metadata()
    assert metadata["name"] == "Doppio Feature Flag Provider"


def test_boolean_evaluation_with_default():
    c = Doppio({
        "flags": [
            {"key": "enabled-flag", "enabled": True, "rollout_percentage": 100},
            {"key": "disabled-flag", "enabled": False, "rollout_percentage": 0},
        ]
    })
    provider = DoppioProvider(c)

    res1 = provider.get_boolean_value("enabled-flag", False, {"targetingKey": "user-1"})
    assert res1 is True

    res2 = provider.get_boolean_value("disabled-flag", True, {"targetingKey": "user-1"})
    assert res2 is False

    res3 = provider.get_boolean_value("missing-flag", True, {"targetingKey": "user-1"})
    assert res3 is True


def test_targeting_context_respected():
    c = Doppio({
        "flags": [
            {
                "key": "targeted-flag",
                "enabled": True,
                "rules": [
                    {
                        "id": "vip-rule",
                        "expression": 'user.plan == "premium"',
                        "variation": 1,
                    }
                ],
                "variations": [
                    {"key": "standard", "value": "false"},
                    {"key": "premium", "value": "true"},
                ],
                "default_variation": 0,
                "rollout_percentage": 100,
            }
        ]
    })
    provider = DoppioProvider(c)

    premium_res = provider.get_boolean_value(
        "targeted-flag",
        False,
        {"targetingKey": "user-1", "custom": {"plan": "premium"}}
    )
    assert premium_res is True

    standard_res = provider.get_boolean_value(
        "targeted-flag",
        False,
        {"targetingKey": "user-2", "custom": {"plan": "free"}}
    )
    assert standard_res is False


def test_deterministic_evaluation():
    c = Doppio({
        "flags": [{"key": "det-flag", "enabled": True, "rollout_percentage": 50}]
    })
    provider = DoppioProvider(c)

    res1 = provider.get_boolean_value("det-flag", False, {"targetingKey": "user-123"})
    res2 = provider.get_boolean_value("det-flag", False, {"targetingKey": "user-123"})
    assert res1 == res2


def test_string_evaluation():
    c = Doppio({
        "flags": [
            {
                "key": "string-flag",
                "enabled": True,
                "rollout_percentage": 100,
                "variations": [{"key": "on", "value": "hello world"}],
                "default_variation": 0,
            }
        ]
    })
    provider = DoppioProvider(c)

    res = provider.get_string_value("string-flag", "default", {"targetingKey": "user-1"})
    assert res == "hello world"


def test_int_evaluation():
    c = Doppio({
        "flags": [
            {
                "key": "int-flag",
                "enabled": True,
                "rollout_percentage": 100,
                "variations": [{"key": "on", "value": "42"}],
                "default_variation": 0,
            }
        ]
    })
    provider = DoppioProvider(c)

    res = provider.get_int_value("int-flag", 0, {"targetingKey": "user-1"})
    assert res == 42


def test_float_evaluation():
    c = Doppio({
        "flags": [
            {
                "key": "float-flag",
                "enabled": True,
                "rollout_percentage": 100,
                "variations": [{"key": "on", "value": "3.14"}],
                "default_variation": 0,
            }
        ]
    })
    provider = DoppioProvider(c)

    res = provider.get_float_value("float-flag", 0.0, {"targetingKey": "user-1"})
    assert res == 3.14


def test_object_evaluation():
    c = Doppio({
        "flags": [
            {
                "key": "obj-flag",
                "enabled": True,
                "rollout_percentage": 100,
                "variations": [{"key": "on", "value": '{"feature": true}'}],
                "default_variation": 0,
            }
        ]
    })
    provider = DoppioProvider(c)

    res = provider.get_object_value("obj-flag", {}, {"targetingKey": "user-1"})
    assert res == {"feature": True}


def test_factory_function():
    c = Doppio({"flags": []})
    provider = create_doppio_provider(c)
    assert isinstance(provider, DoppioProvider)


def test_empty_context_handling():
    c = Doppio({
        "flags": [{"key": "ctx-flag", "enabled": True, "rollout_percentage": 100}]
    })
    provider = DoppioProvider(c)

    res1 = provider.get_boolean_value("ctx-flag", False)
    assert res1 is True

    res2 = provider.get_boolean_value("ctx-flag", False, {})
    assert res2 is True


def test_resolution_details():
    c = Doppio({
        "flags": [
            {
                "key": "detail-flag",
                "enabled": True,
                "rollout_percentage": 100,
                "variations": [{"key": "on", "value": "true"}],
                "default_variation": 0,
            }
        ]
    })
    provider = DoppioProvider(c)

    details = provider.get_resolution_details("detail-flag", False, {"targetingKey": "user-1"})
    assert details["value"] is True
    assert details["variant"] == "on"
    assert "reason" in details
    assert "flagMetadata" in details