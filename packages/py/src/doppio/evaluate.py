"""Flag evaluation for the Python SDK.

The control flow mirrors ``libdoppio/src/eval.zig`` and the JavaScript SDK's
``client.ts``: disabled short-circuits, then prerequisites, then targeting
rules, then the default rollout. Bucketing always comes from :mod:`doppio.hash`
so a given user lands in the same bucket in every language.

Rule expressions are a small CEL-compatible subset evaluated locally: string
and numeric equality, ``in`` membership, and ``&&``/``||``/``!`` with
parentheses. The JavaScript SDK hands the same strings to the Zig core compiled
to WebAssembly; Python has no WASM runtime in the dependency set yet, so the
common subset lives here.
"""

from __future__ import annotations

import json
import math
import re
from typing import Any, Dict, List, Mapping, Optional, Sequence

from . import hash as bucketing
from .types import (
    EvaluationContext,
    EvaluationReason,
    EvaluationResult,
    FlagDefinition,
    Variation,
)

_MISSING = object()

_EQ_RE = re.compile(r'^([\w.]+)\s*==\s*["\']([^"\']+)["\']$')
_IN_RE = re.compile(r"^([\w.]+)\s+in\s+\[(.*)\]$")
_TOKEN_RE = re.compile(
    r"""
    \s*(
        \|\| | && | == | != | >= | <= | > | < | ! | \( | \) | \[ | \] | ,
      | "(?:[^"\\]|\\.)*" | '(?:[^'\\]|\\.)*'
      | -?\d+(?:\.\d+)?
      | [A-Za-z_][A-Za-z0-9_.]*
    )
    """,
    re.VERBOSE,
)


def parse_variation_value(raw: Any) -> Any:
    """Turn a variation's string payload back into a typed value."""
    if not isinstance(raw, str):
        return raw
    if raw == "true":
        return True
    if raw == "false":
        return False
    stripped = raw.strip()
    if stripped:
        try:
            num = float(stripped)
        except ValueError:
            num = math.nan
        if not math.isnan(num) and not math.isinf(num):
            return int(num) if num.is_integer() else num
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return raw


def default_variation(flag: FlagDefinition) -> Optional[Variation]:
    if not flag.variations or len(flag.variations) == 0:
        return None
    index = flag.default_variation
    if index is None or index >= len(flag.variations):
        index = 0
    return flag.variations[index]


def _truthy(value: Any) -> bool:
    if value is _MISSING or value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() not in ("", "false", "0", "no", "off")
    return bool(value)


def _equal(left: Any, right: Any) -> bool:
    if left is _MISSING or right is _MISSING:
        return False
    if isinstance(left, bool) or isinstance(right, bool):
        return left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return float(left) == float(right)
    return str(left) == str(right)


def _compare(op: str, left: Any, right: Any) -> bool:
    if op == "==":
        return _equal(left, right)
    if op == "!=":
        return not _equal(left, right)
    if left is _MISSING or right is _MISSING:
        return False
    try:
        if isinstance(left, str) or isinstance(right, str):
            left_cmp: Any = str(left)
            right_cmp: Any = str(right)
        else:
            left_cmp, right_cmp = left, right
        if op == ">":
            return left_cmp > right_cmp
        if op == ">=":
            return left_cmp >= right_cmp
        if op == "<":
            return left_cmp < right_cmp
        if op == "<=":
            return left_cmp <= right_cmp
    except TypeError:
        return False
    return False


class _ExpressionEvaluator:
    """Recursive descent evaluator for the supported expression subset."""

    def __init__(self, expression: str, flat: Mapping[str, Any]) -> None:
        self.flat = flat
        self.tokens = self._tokenize(expression)

    @staticmethod
    def _tokenize(expression: str) -> List[str]:
        tokens: List[str] = []
        pos = 0
        length = len(expression)
        while pos < length:
            if expression[pos].isspace():
                pos += 1
                continue
            match = _TOKEN_RE.match(expression, pos)
            if not match or match.end() == pos:
                raise ValueError(f"unsupported expression syntax: {expression!r}")
            tokens.append(match.group(1))
            pos = match.end()
        return tokens

    def parse(self) -> bool:
        value = self._or()
        if self.tokens:
            raise ValueError("trailing tokens in expression")
        return _truthy(value)

    def _peek(self) -> Optional[str]:
        return self.tokens[0] if self.tokens else None

    def _accept(self, token: str) -> bool:
        if self.tokens and self.tokens[0] == token:
            self.tokens.pop(0)
            return True
        return False

    def _or(self) -> Any:
        value = self._and()
        while self._peek() == "||":
            self.tokens.pop(0)
            right = self._and()
            value = _truthy(value) or _truthy(right)
        return value

    def _and(self) -> Any:
        value = self._not()
        while self._peek() == "&&":
            self.tokens.pop(0)
            right = self._not()
            value = _truthy(value) and _truthy(right)
        return value

    def _not(self) -> Any:
        if self._accept("!"):
            return not _truthy(self._not())
        return self._comparison()

    def _comparison(self) -> Any:
        left = self._primary()
        token = self._peek()
        if token in ("==", "!=", ">", ">=", "<", "<="):
            self.tokens.pop(0)
            return _compare(token, left, self._primary())
        if token == "in":
            self.tokens.pop(0)
            return _membership(left, self._primary())
        if token == "not" and len(self.tokens) > 1 and self.tokens[1] == "in":
            self.tokens.pop(0)
            self.tokens.pop(0)
            return not _membership(left, self._primary())
        return left

    def _primary(self) -> Any:
        if not self.tokens:
            raise ValueError("unexpected end of expression")
        token = self.tokens.pop(0)
        if token == "(":
            value = self._or()
            if not self._accept(")"):
                raise ValueError("missing closing parenthesis")
            return value
        if token == "[":
            items: List[Any] = []
            if self._accept("]"):
                return items
            while True:
                items.append(self._literal_or_field())
                if self._accept(","):
                    continue
                if self._accept("]"):
                    return items
                raise ValueError("malformed list literal")
        return self._value(token)

    def _literal_or_field(self) -> Any:
        token = self.tokens.pop(0) if self.tokens else ""
        return self._value(token)

    @staticmethod
    def _value(token: str) -> Any:
        if not token:
            raise ValueError("missing value")
        if token[0] in "\"'" and token[-1] == token[0] and len(token) >= 2:
            return token[1:-1].replace("\\'", "'").replace('\\"', '"')
        if token == "true":
            return True
        if token == "false":
            return False
        try:
            if "." in token:
                return float(token)
            return int(token)
        except ValueError:
            pass
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", token):
            raise _FieldLookup(token)
        raise ValueError(f"unsupported token: {token!r}")

    def _resolve_primary(self) -> Any:  # pragma: no cover - kept for clarity
        raise NotImplementedError

    def _eval_field(self, name: str) -> Any:
        return self.flat.get(name, _MISSING)


def _membership(left: Any, right: Any) -> bool:
    if not isinstance(right, (list, tuple, set)) or left is _MISSING:
        return False
    if any(_equal(left, item) for item in right):
        return True
    return str(left) in [str(item) for item in right]


class _FieldLookup(Exception):
    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.name = name


def evaluate_expression(expression: str, flat: Mapping[str, Any]) -> bool:
    """Evaluate a rule expression against a flattened context.

    Returns ``False`` for anything the subset evaluator cannot handle so a
    malformed rule fails closed instead of crashing an evaluation.
    """
    expr = expression.strip()
    if not expr:
        return False

    # Fast paths that also cover the shapes the JS SDK special-cases.
    eq_match = _EQ_RE.match(expr)
    if eq_match:
        return _equal(flat.get(eq_match.group(1), _MISSING), eq_match.group(2))

    in_match = _IN_RE.match(expr)
    if in_match:
        items = [part.strip().strip("\"'") for part in in_match.group(2).split(",")]
        items = [item for item in items if item != ""]
        return _membership(flat.get(in_match.group(1), _MISSING), items)

    try:
        evaluator = _ExpressionEvaluator(expr, flat)
        return _truthy(_eval_tokens(evaluator, expr, flat))
    except (_FieldLookup, ValueError):
        return False


def _eval_tokens(evaluator: _ExpressionEvaluator, expr: str, flat: Mapping[str, Any]) -> Any:
    """Run the parser with field lookups resolved against ``flat``."""
    original = _ExpressionEvaluator._value

    def resolving(token: str) -> Any:
        try:
            return original(token)
        except _FieldLookup as lookup:
            return flat.get(lookup.name, _MISSING)

    _ExpressionEvaluator._value = staticmethod(resolving)  # type: ignore[method-assign]
    try:
        return evaluator._or()
    finally:
        _ExpressionEvaluator._value = original  # type: ignore[method-assign]


def evaluate_flag(
    flag: FlagDefinition,
    context: EvaluationContext,
    flags_by_key: Mapping[str, FlagDefinition],
    visited: Optional[set] = None,
) -> EvaluationResult:
    """Evaluate one flag. ``flags_by_key`` backs prerequisite lookups."""
    unit_id = context.resolved_unit
    visited = set(visited) if visited else set()
    flat = context.flat()
    bucket = bucketing.bucket_unit(flag.key, unit_id)

    def result(
        enabled: bool,
        value: Any,
        variation: Optional[str],
        reason: EvaluationReason,
        bucket_value: int,
    ) -> EvaluationResult:
        return EvaluationResult(
            flag_key=flag.key,
            enabled=enabled,
            value=value,
            variation=variation,
            reason=reason,
            bucket=bucket_value,
        )

    # 1. Disabled flags short-circuit to their default variation.
    if not flag.enabled:
        default_var = default_variation(flag)
        return result(
            False,
            parse_variation_value(default_var.value if default_var else "false"),
            default_var.key if default_var else None,
            "DISABLED",
            bucket,
        )

    # 2. Prerequisites gate on a parent flag's variation.
    if flag.prerequisites:
        if flag.key in visited:
            return result(False, False, None, "ERROR", 0)
        visited.add(flag.key)

        for prereq in flag.prerequisites:
            parent = flags_by_key.get(prereq.flag_key)
            if parent is None:
                return result(False, False, None, "ERROR", 0)

            parent_result = evaluate_flag(parent, context, flags_by_key, visited)
            matched = parent_result.enabled and parent_result.variation == prereq.variation_key
            if not matched:
                default_var = default_variation(flag)
                return result(
                    False,
                    parse_variation_value(default_var.value if default_var else "false"),
                    default_var.key if default_var else None,
                    "PREREQUISITE_FAILED",
                    bucket,
                )

    # 3. Targeting rules in priority order.
    for rule in flag.rules or []:
        if not rule.expression:
            continue
        if not evaluate_expression(rule.expression, flat):
            continue

        if rule.variation is not None and flag.variations and rule.variation < len(flag.variations):
            selected = flag.variations[rule.variation]
            return result(
                True,
                parse_variation_value(selected.value),
                selected.key,
                "TARGET_MATCH",
                bucket,
            )

        if rule.rollout_percentage is not None:
            in_rollout = bucketing.in_rollout(flag.key, unit_id, rule.rollout_percentage)
            if in_rollout:
                default_var = default_variation(flag)
                return result(
                    True,
                    parse_variation_value(default_var.value if default_var else "true"),
                    default_var.key if default_var else "on",
                    "TARGET_MATCH",
                    bucket,
                )
            default_var = default_variation(flag)
            return result(
                False,
                parse_variation_value(default_var.value if default_var else "false"),
                default_var.key if default_var else None,
                "DEFAULT",
                bucket,
            )

    # 4. Default rollout bucketing.
    rollout = 100 if flag.rollout_percentage is None else flag.rollout_percentage
    default_var = default_variation(flag)
    if bucketing.in_rollout(flag.key, unit_id, rollout):
        return result(
            True,
            parse_variation_value(default_var.value if default_var else "true"),
            default_var.key if default_var else "on",
            "ROLLOUT",
            bucket,
        )
    return result(
        False,
        parse_variation_value(default_var.value if default_var else "false"),
        default_var.key if default_var else None,
        "ROLLOUT_MISS",
        bucket,
    )
