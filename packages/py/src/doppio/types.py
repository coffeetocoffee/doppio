"""Public data types for the Doppio Python SDK.

Field names are snake_case (Python convention). The TypeScript SDK uses the
camelCase equivalents (``flagKey`` -> ``flag_key``, ``rolloutPercentage`` ->
``rollout_percentage``), and the wire format coming from the control plane is
also snake_case, so the two line up on the network.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Literal, Mapping, Optional, Sequence, Union

EvaluationReason = Literal[
    "DISABLED",
    "TARGET_MATCH",
    "ROLLOUT",
    "ROLLOUT_MISS",
    "DEFAULT",
    "PREREQUISITE_FAILED",
    "ERROR",
]

SyncStrategy = Literal["websocket", "sse", "delta-poll", "auto", "manual"]
SyncTransport = Literal["websocket", "sse", "delta-poll"]


@dataclass
class EvaluationContext:
    """Who and what we are evaluating a flag for."""

    unit_id: Optional[str] = None
    user_id: Optional[str] = None
    country: Optional[str] = None
    plan: Optional[str] = None
    custom: Optional[Dict[str, Any]] = None
    attributes: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def coerce(cls, value: "ContextLike") -> "EvaluationContext":
        if value is None:
            return cls()
        if isinstance(value, EvaluationContext):
            return value
        if isinstance(value, Mapping):
            known: Dict[str, Any] = {}
            attributes: Dict[str, Any] = {}
            for key, val in value.items():
                if key in ("user_id", "userId"):
                    known["user_id"] = val
                elif key in ("unit_id", "unitId"):
                    known["unit_id"] = val
                elif key == "custom":
                    known["custom"] = val
                elif key in ("country", "plan"):
                    known[key] = val
                else:
                    attributes[key] = val
            return cls(attributes=attributes, **known)
        raise TypeError(f"evaluation context must be a mapping or EvaluationContext, got {type(value)!r}")

    @property
    def resolved_unit(self) -> str:
        return self.unit_id or self.user_id or "anonymous"

    def flat(self) -> Dict[str, Any]:
        """Flatten into the namespace rule expressions are evaluated against."""
        unit = self.resolved_unit
        flat: Dict[str, Any] = {
            "unit_id": unit,
            "user.id": unit,
        }
        if self.country is not None:
            flat["user.country"] = self.country
            flat["country"] = self.country
        if self.plan is not None:
            flat["account.plan"] = self.plan
            flat["plan"] = self.plan
            flat["user.plan"] = self.plan

        for key, val in (self.custom or {}).items():
            flat[f"custom.{key}"] = val
            flat[f"user.{key}"] = val
            flat[key] = val

        flat["user_id"] = self.user_id if self.user_id is not None else unit
        flat["unit_id"] = unit

        for key, val in self.attributes.items():
            if key != "custom":
                flat[key] = val

        return flat


ContextLike = Union[EvaluationContext, Mapping[str, Any], None]


@dataclass
class Variation:
    key: str
    value: str

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "Variation":
        return cls(key=str(raw.get("key", "")), value=str(raw.get("value", "")))


@dataclass
class Rule:
    expression: str
    id: Optional[str] = None
    priority: Optional[int] = None
    variation: Optional[int] = None
    rollout_percentage: Optional[int] = None

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "Rule":
        return cls(
            expression=str(raw.get("expression", "")),
            id=raw.get("id"),
            priority=raw.get("priority"),
            variation=_first_int(raw, "variation"),
            rollout_percentage=_first_int(raw, "rollout_percentage", "rolloutPercentage"),
        )


@dataclass
class Prerequisite:
    flag_key: str
    variation_key: str

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "Prerequisite":
        return cls(
            flag_key=str(raw.get("flag_key") or raw.get("flagKey") or ""),
            variation_key=str(raw.get("variation_key") or raw.get("variationKey") or ""),
        )


@dataclass
class FlagDefinition:
    key: str
    enabled: bool
    rollout_percentage: Optional[int] = None
    variations: Optional[List[Variation]] = None
    default_variation: Optional[int] = None
    prerequisites: Optional[List[Prerequisite]] = None
    rules: Optional[List[Rule]] = None

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "FlagDefinition":
        """Parse a flag from either the wire shape or an SDK-shaped dict."""
        variations = raw.get("variations")
        rules = raw.get("rules")
        prereqs = raw.get("prerequisites")
        return cls(
            key=str(raw.get("key", "")),
            enabled=bool(raw.get("enabled", True)),
            rollout_percentage=_first_int(raw, "rollout_percentage", "rolloutPercentage"),
            variations=[Variation.from_mapping(v) for v in variations] if variations else None,
            default_variation=_first_int(raw, "default_variation", "defaultVariation"),
            prerequisites=[Prerequisite.from_mapping(p) for p in prereqs] if prereqs else None,
            rules=[Rule.from_mapping(r) for r in rules] if rules else None,
        )

    def to_mapping(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"key": self.key, "enabled": self.enabled}
        if self.rollout_percentage is not None:
            out["rollout_percentage"] = self.rollout_percentage
        if self.variations is not None:
            out["variations"] = [{"key": v.key, "value": v.value} for v in self.variations]
        if self.default_variation is not None:
            out["default_variation"] = self.default_variation
        if self.prerequisites is not None:
            out["prerequisites"] = [
                {"flag_key": p.flag_key, "variation_key": p.variation_key}
                for p in self.prerequisites
            ]
        if self.rules is not None:
            out["rules"] = [
                {
                    "expression": r.expression,
                    **({"id": r.id} if r.id is not None else {}),
                    **({"priority": r.priority} if r.priority is not None else {}),
                    **({"variation": r.variation} if r.variation is not None else {}),
                    **(
                        {"rollout_percentage": r.rollout_percentage}
                        if r.rollout_percentage is not None
                        else {}
                    ),
                }
                for r in self.rules
            ]
        return out


@dataclass
class ConfigDefinition:
    flags: List[FlagDefinition]
    environment: Optional[str] = None
    version: Optional[int] = None


@dataclass
class EvaluationResult:
    flag_key: str
    enabled: bool
    value: Any
    variation: Optional[str]
    reason: EvaluationReason
    bucket: int
    version: Optional[int] = None


@dataclass
class ExposureEvent:
    flag_key: str
    unit_id: str
    enabled: bool
    variation: Optional[str]
    bucket: int
    timestamp: int
    reason: EvaluationReason
    idempotency_key: Optional[str] = None


@dataclass
class MetricEvent:
    event_name: str
    timestamp: int
    payload: Optional[Dict[str, Any]] = None


@dataclass
class DoppioOptions:
    client_key: Optional[str] = None
    environment: Optional[str] = None
    offline: bool = True
    flags: Optional[Sequence[FlagDefinition]] = None
    endpoint: Optional[str] = None
    sync_strategy: SyncStrategy = "auto"
    poll_interval: int = 5000
    flush_interval: int = 15000
    storage: Any = None
    """Explicit storage adapter, overrides ``offline``/default path choice."""
    transport: Any = None
    """httpx transport override, used by tests to fake the network."""

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "DoppioOptions":
        """Build options from a dict, accepting snake_case or camelCase keys."""
        def pick(*names: str, default: Any = None) -> Any:
            for name in names:
                if name in raw and raw[name] is not None:
                    return raw[name]
            return default

        flags = pick("flags", "flag_definitions")
        parsed_flags = (
            [f if isinstance(f, FlagDefinition) else FlagDefinition.from_mapping(f) for f in flags]
            if flags
            else None
        )
        return cls(
            client_key=pick("client_key", "clientKey"),
            environment=pick("environment"),
            offline=bool(pick("offline", default=True)),
            flags=parsed_flags,
            endpoint=pick("endpoint"),
            sync_strategy=pick("sync_strategy", "syncStrategy", default="auto"),
            poll_interval=int(pick("poll_interval", "pollInterval", default=5000)),
            flush_interval=int(pick("flush_interval", "flushInterval", default=15000)),
            storage=pick("storage"),
            transport=pick("transport"),
        )


def _first_int(raw: Mapping[str, Any], *names: str) -> Optional[int]:
    for name in names:
        if name in raw and raw[name] is not None:
            try:
                return int(raw[name])
            except (TypeError, ValueError):
                return None
    return None
