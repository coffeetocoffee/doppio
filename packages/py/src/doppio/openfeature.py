"""OpenFeature Provider for Doppio (Python SDK).

Implements the OpenFeature Provider interface to allow Doppio to be used
as a feature flag backend for OpenFeature-compatible applications.

Install: pip install doppio openfeature-sdk
Usage:
    from openfeature import provider as of_provider
    from openfeature.provider import AbstractProvider
    from doppio import Doppio
    from doppio.openfeature import DoppioProvider

    client = Doppio(flags=[...])
    provider = DoppioProvider(client)
    of_provider.set_provider(provider)
    of_client = of_provider.get_client('my-app')
    enabled = of_client.get_boolean_value('flag-key', False, targeting_key='user-123')
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional

from .client import Doppio
from .evaluate import parse_variation_value
from .types import EvaluationContext, EvaluationReason


class DoppioProvider:
    """OpenFeature-compatible provider wrapping a Doppio client."""

    def __init__(self, doppio: Doppio) -> None:
        self._doppio = doppio

    def get_metadata(self) -> Dict[str, str]:
        return {"name": "Doppio Feature Flag Provider"}

    def _convert_context(self, context: Optional[Mapping[str, Any]]) -> EvaluationContext:
        if not context:
            return {}

        doppio_context: Dict[str, Any] = {
            "unitId": context.get("targetingKey"),
            "userId": context.get("targetingKey"),
        }

        custom: Dict[str, Any] = {}
        for key, value in context.items():
            if key == "targetingKey":
                continue
            if key in ("ip", "userAgent", "hostname"):
                custom[key] = value
            elif key == "custom" and isinstance(value, dict):
                custom.update(value)
            else:
                doppio_context[key] = value

        if custom:
            doppio_context["custom"] = custom

        return doppio_context

    def _map_reason(self, reason: EvaluationReason) -> str:
        mapping = {
            "TARGET_MATCH": "TARGETING_MATCH",
            "ROLLOUT": "SPLIT",
            "ROLLOUT_MISS": "SPLIT",
            "DISABLED": "DISABLED",
            "DEFAULT": "DEFAULT",
            "PREREQUISITE_FAILED": "ERROR",
            "ERROR": "ERROR",
        }
        return mapping.get(reason, "ERROR")

    def _get_flag_metadata(self, flag_key: str) -> Dict[str, Any]:
        flags = getattr(self._doppio, "flags", None)
        if not flags:
            return {}
        flag = flags.get(flag_key)
        if not flag:
            return {}

        metadata: Dict[str, Any] = {"flagKey": flag.key}
        if flag.variations:
            metadata["description"] = ", ".join(
                f"{v.key}: {v.value}" for v in flag.variations
            )
        return metadata

    def _resolve(self, flag_key: str, default_value: Any, context: Optional[Mapping[str, Any]], value_type: str) -> Dict[str, Any]:
        doppio_context = self._convert_context(context)
        result = self._doppio.get(flag_key, doppio_context)

        if result.reason == "DISABLED":
            value = result.value if result.value is not None else False
        elif result.enabled and result.value is not None:
            value = result.value
        else:
            value = default_value

        return {
            "value": value,
            "variant": result.variation,
            "reason": self._map_reason(result.reason),
            "flagMetadata": self._get_flag_metadata(flag_key),
        }

    def get_boolean_value(
        self, flag_key: str, default_value: bool, context: Optional[Mapping[str, Any]] = None
    ) -> bool:
        result = self._resolve(flag_key, default_value, context, "boolean")
        return bool(result["value"])

    def get_string_value(
        self, flag_key: str, default_value: str, context: Optional[Mapping[str, Any]] = None
    ) -> str:
        result = self._resolve(flag_key, default_value, context, "string")
        return str(result["value"])

    def get_int_value(
        self, flag_key: str, default_value: int, context: Optional[Mapping[str, Any]] = None
    ) -> int:
        result = self._resolve(flag_key, default_value, context, "number")
        value = result["value"]
        if isinstance(value, (int, float)):
            return int(value)
        return default_value

    def get_float_value(
        self, flag_key: str, default_value: float, context: Optional[Mapping[str, Any]] = None
    ) -> float:
        result = self._resolve(flag_key, default_value, context, "number")
        value = result["value"]
        if isinstance(value, (int, float)):
            return float(value)
        return default_value

    def get_object_value(
        self, flag_key: str, default_value: Any, context: Optional[Mapping[str, Any]] = None
    ) -> Any:
        result = self._resolve(flag_key, default_value, context, "object")
        value = result["value"]
        if isinstance(value, dict):
            return value
        if isinstance(value, str):
            try:
                import json
                parsed = json.loads(value)
                if isinstance(parsed, dict):
                    return parsed
            except (ValueError, TypeError):
                pass
        return default_value

    def get_resolution_details(
        self, flag_key: str, default_value: Any, context: Optional[Mapping[str, Any]] = None
    ) -> Dict[str, Any]:
        return self._resolve(flag_key, default_value, context, "object")


def create_doppio_provider(doppio: Doppio) -> DoppioProvider:
    """Factory for creating a DoppioProvider with a configured Doppio client."""
    return DoppioProvider(doppio)