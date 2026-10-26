"""Doppio Python SDK client."""

from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional, Sequence

from .types import (
    DoppioOptions,
    EvaluationContext,
    EvaluationResult,
    ExposureEvent,
    FlagDefinition,
    MetricEvent,
)
from .evaluate import evaluate_flag
from .cache import create_storage
from .sync import create_sync_client


class Doppio:
    def __init__(self, options: DoppioOptions) -> None:
        self.options = options
        self.flags: Dict[str, FlagDefinition] = {}
        self.listeners: Dict[str, set] = {}
        self.exposure_queue: List[ExposureEvent] = []
        self.metric_queue: List[MetricEvent] = []
        self.is_ready = False
        self.storage = create_storage(False, None)
        self.sync_client = create_sync_client(options)

        if options.flags:
            self.load_flag_definitions(options.flags)

    @classmethod
    def init(cls, options=None) -> "Doppio":
        if options is None:
            options = DoppioOptions()
        if isinstance(options, dict):
            options = DoppioOptions.from_mapping(options)
        client = cls(options)
        client.is_ready = True
        client.emit("ready")
        return client

    def on(self, event: str, callback: Callable) -> Callable[[], None]:
        self.listeners.setdefault(event, set()).add(callback)
        if event == "ready" and self.is_ready:
            callback()
        return lambda: self.listeners.get(event, set()).discard(callback)

    def emit(self, event: str, *args: Any) -> None:
        for cb in list(self.listeners.get(event, ())):
            try:
                cb(*args)
            except Exception:
                pass

    def set_flags(self, flags: List[FlagDefinition]) -> None:
        changed: List[str] = []
        for flag in flags:
            existing = self.flags.get(flag.key)
            if existing is None or existing.to_mapping() != flag.to_mapping():
                changed.append(flag.key)
        self.load_flag_definitions(flags)
        if changed:
            self.emit("change", changed)

    def load_flag_definitions(self, flags: List[FlagDefinition]) -> None:
        self.flags.clear()
        for flag in flags:
            self.flags[flag.key] = flag

    def get(self, flag_key: str, context: Any = None) -> EvaluationResult:
        ctx = EvaluationContext.coerce(context)
        flag = self.flags.get(flag_key)
        if flag is None:
            return EvaluationResult(
                flag_key=flag_key,
                enabled=False,
                value=False,
                variation=None,
                reason="ERROR",
                bucket=0,
            )

        evaluation = evaluate_flag(flag, ctx, self.flags)

        exposure = ExposureEvent(
            flag_key=flag_key,
            unit_id=ctx.resolved_unit,
            enabled=evaluation.enabled,
            variation=evaluation.variation,
            bucket=evaluation.bucket,
            timestamp=int(time.time() * 1000),
            reason=evaluation.reason,
        )
        self.exposure_queue.append(exposure)

        return evaluation

    def is_enabled(self, flag_key: str, context: Any = None) -> bool:
        return self.get(flag_key, context).enabled

    def track(self, event_name: str, payload=None) -> None:
        self.metric_queue.append(
            MetricEvent(event_name=event_name, timestamp=int(time.time() * 1000), payload=payload)
        )

    def get_exposures(self) -> List[ExposureEvent]:
        return list(self.exposure_queue)

    def flush_exposures(self) -> List[ExposureEvent]:
        exposures = list(self.exposure_queue)
        self.exposure_queue = []
        return exposures

    def get_metrics(self) -> List[MetricEvent]:
        return list(self.metric_queue)

    def flush_metrics(self) -> List[MetricEvent]:
        metrics = list(self.metric_queue)
        self.metric_queue = []
        return metrics