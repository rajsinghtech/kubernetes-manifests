#!/usr/bin/env python3
"""Diagnose alert conditions that churn without surviving their ``for`` time.

This is deliberately a report-only diagnostic.  It evaluates the complete
alert expression against live Mimir samples, groups samples by the labels the
alert instance would actually have, and reports high-churn instances whose
longest observed active run is shorter than the rule's ``for`` duration.  It
also reports when Mimir says an alert is pending or firing while the expression
is currently inactive.

The diagnostic does not emit Prometheus samples, change rules, or use its exit
status for findings.  Exit 2 means the live sweep could not be completed; a
non-zero finding count is still a successful diagnostic run.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import dataclasses
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

try:
    import yaml
except ImportError as error:  # pragma: no cover - deployment failure
    raise SystemExit("PyYAML is required to read native Mimir rule files") from error


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES_DIR = ROOT / "kubernetes/apps/base/mimir/mimir-ottawa/rules"
DEFAULT_API_URL = (
    "http://mimir-gateway.mimir.svc.cluster.local:8080"
    "/prometheus/api/v1"
)
DEFAULT_TENANTS = (
    "talos-ottawa",
    "talos-robbinsdale",
    "talos-stpetersburg",
)
DEFAULT_LOOKBACK = "6h"
DEFAULT_STEP = "1m"
DEFAULT_WORKERS = 8
DEFAULT_TIMEOUT = 15.0

DURATION_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h|d|w|y)")
UNIT_SECONDS = {
    "ms": 0.001,
    "s": 1,
    "m": 60,
    "h": 3600,
    "d": 86400,
    "w": 604800,
    "y": 31536000,
}


class DiagnosticError(RuntimeError):
    """The diagnostic could not complete its live or rule-file inspection."""


@dataclasses.dataclass(frozen=True)
class AlertRule:
    path: Path
    group: str
    name: str
    expression: str
    for_seconds: float
    labels: dict[str, str]

    @property
    def location(self) -> str:
        try:
            path = self.path.relative_to(ROOT)
        except ValueError:
            path = self.path
        return f"{path}:alert={self.name}"


@dataclasses.dataclass(frozen=True)
class StabilityObservation:
    labels: dict[str, str]
    active_runs: int
    transitions: int
    max_active_seconds: float
    for_seconds: float
    lookback_seconds: float
    current_active: bool
    duration_censored: bool

    @property
    def ratio(self) -> float | None:
        if self.for_seconds <= 0:
            return None
        return self.max_active_seconds / self.for_seconds

    @property
    def transition_frequency_per_hour(self) -> float:
        if self.lookback_seconds <= 0:
            return 0.0
        return self.transitions * 3600 / self.lookback_seconds

    @property
    def classification(self) -> str | None:
        if (
            self.for_seconds <= 0
            or self.active_runs < 2
            or self.max_active_seconds >= self.for_seconds
        ):
            return None
        if self.duration_censored:
            return "high-churn, range-censored"
        return "high-churn, never-sustained"

    @property
    def high_churn_never_sustained(self) -> bool:
        return self.classification == "high-churn, never-sustained"


@dataclasses.dataclass(frozen=True)
class StateMismatch:
    state: str
    labels: dict[str, str]


def parse_duration(value: str) -> float:
    match = DURATION_RE.fullmatch(value.strip())
    if not match:
        raise argparse.ArgumentTypeError(
            f"invalid duration {value!r}; use e.g. 30s, 5m, or 2h"
        )
    return float(match.group(1)) * UNIT_SECONDS[match.group(2)]


def parse_rule_duration(value: Any) -> float:
    if value is None or str(value).strip() in {"", "0"}:
        return 0.0
    return parse_duration(str(value))


def format_duration(seconds: float) -> str:
    seconds = float(seconds)
    if seconds <= 0:
        return "0s"
    if seconds.is_integer():
        whole = int(seconds)
        for unit, size in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
            if whole >= size and whole % size == 0:
                return f"{whole // size}{unit}"
        return f"{whole}s"
    return f"{seconds:g}s"


def load_rules(rules_dir: Path, requested_names: set[str]) -> list[AlertRule]:
    paths = sorted(rules_dir.glob("*.yaml")) + sorted(rules_dir.glob("*.yml"))
    if not paths:
        raise DiagnosticError(f"no Mimir rule files found under {rules_dir}")

    rules: list[AlertRule] = []
    try:
        for path in paths:
            for document in yaml.safe_load_all(path.read_text()):
                if not isinstance(document, dict):
                    continue
                for group in document.get("groups", []):
                    if not isinstance(group, dict):
                        continue
                    group_name = str(group.get("name", "(unnamed)"))
                    for rule in group.get("rules", []):
                        if not isinstance(rule, dict):
                            continue
                        name = rule.get("alert")
                        expression = rule.get("expr")
                        if not isinstance(name, str) or not isinstance(expression, str):
                            continue
                        if requested_names and name not in requested_names:
                            continue
                        labels = {
                            str(key): str(value)
                            for key, value in (rule.get("labels") or {}).items()
                        }
                        rules.append(
                            AlertRule(
                                path=path,
                                group=group_name,
                                name=name,
                                expression=expression,
                                for_seconds=parse_rule_duration(rule.get("for")),
                                labels=labels,
                            )
                        )
    except (
        OSError,
        yaml.YAMLError,
        TypeError,
        ValueError,
        argparse.ArgumentTypeError,
    ) as error:
        raise DiagnosticError(f"cannot read Mimir rules: {error}") from error

    if not rules:
        raise DiagnosticError("no alert rules were found")
    return rules


def canonical_labels(labels: dict[str, str]) -> tuple[tuple[str, str], ...]:
    # __name__ is a query result detail, not an alert identity label. Mimir's
    # rules API includes alertname/alertstate on active alerts; those are also
    # excluded because the rule name and state are carried separately here.
    return tuple(
        sorted(
            (key, str(value))
            for key, value in labels.items()
            if key not in {"__name__", "alertname", "alertstate"}
        )
    )


def labels_from_key(key: tuple[tuple[str, str], ...]) -> dict[str, str]:
    return dict(key)


def labels_text(labels: dict[str, str]) -> str:
    if not labels:
        return "{}"
    return "{" + ",".join(f"{key}={value}" for key, value in sorted(labels.items())) + "}"


def measure_runs(bits: list[bool]) -> tuple[int, int, int, bool]:
    active_runs = 0
    transitions = 0
    longest = 0
    current = 0
    duration_censored = False
    previous: bool | None = None
    run_start: int | None = None
    for index, active in enumerate(bits):
        if previous is not None and active != previous:
            transitions += 1
        if active and (previous is None or not previous):
            active_runs += 1
            run_start = index
        if not active and previous:
            if run_start == 0:
                duration_censored = True
            run_start = None
        current = current + 1 if active else 0
        longest = max(longest, current)
        previous = active
    if previous and run_start is not None:
        # The final active run is right-censored because the range ends while
        # the expression is still present.
        duration_censored = True
    return active_runs, transitions, longest, duration_censored


def result_labels(metric: dict[str, Any], rule: AlertRule) -> dict[str, str]:
    labels = {
        str(key): str(value)
        for key, value in metric.items()
        if key not in {"__name__", "alertname", "alertstate"}
    }
    # Alert rule labels override labels returned by the expression, matching
    # Prometheus alerting-rule label construction.
    labels.update(rule.labels)
    return labels


def analyze_query_result(
    rule: AlertRule,
    results: list[dict[str, Any]],
    start: int,
    end: int,
    step: int,
    state_alerts: Iterable[dict[str, Any]] = (),
) -> tuple[list[StabilityObservation], list[StateMismatch]]:
    """Analyze one query_range response without requiring a live API.

    The query result is the already-evaluated alert expression, so a present
    sample means active and a missing sample means inactive. That is the same
    presence semantics used by an alerting rule. Durations are lower bounds at
    the sampled resolution: N adjacent active samples span (N - 1) steps. An
    active run touching either range edge is marked censored because its real
    duration may continue outside the requested range.
    """

    if step <= 0 or end < start or (end - start) % step:
        raise ValueError("query range must be non-negative and aligned to step")
    sample_count = ((end - start) // step) + 1
    active_by_key: dict[tuple[tuple[str, str], ...], set[int]] = {}
    labels_by_key: dict[tuple[tuple[str, str], ...], dict[str, str]] = {}

    for result in results:
        metric = result.get("metric")
        values = result.get("values")
        if not isinstance(metric, dict) or not isinstance(values, list):
            continue
        labels = result_labels(metric, rule)
        key = canonical_labels(labels)
        active_by_key.setdefault(key, set())
        labels_by_key[key] = labels_from_key(key)
        for sample in values:
            if not isinstance(sample, list) or len(sample) < 2:
                continue
            try:
                timestamp = float(sample[0])
            except (TypeError, ValueError):
                continue
            index = int(round((timestamp - start) / step))
            if (
                0 <= index < sample_count
                and abs(timestamp - (start + index * step)) <= step / 2
            ):
                active_by_key[key].add(index)

    observations: list[StabilityObservation] = []
    for key, active_indices in active_by_key.items():
        bits = [index in active_indices for index in range(sample_count)]
        active_runs, transitions, longest_samples, duration_censored = measure_runs(bits)
        max_active_seconds = max(0, (longest_samples - 1) * step)
        observations.append(
            StabilityObservation(
                labels=labels_by_key[key],
                active_runs=active_runs,
                transitions=transitions,
                max_active_seconds=max_active_seconds,
                for_seconds=rule.for_seconds,
                lookback_seconds=end - start,
                current_active=bits[-1] if bits else False,
                duration_censored=duration_censored,
            )
        )

    mismatches: list[StateMismatch] = []
    active_now = {
        key for key, indices in active_by_key.items() if sample_count - 1 in indices
    }
    for alert in state_alerts:
        state = str(alert.get("state", "")).lower()
        labels = alert.get("labels")
        if state not in {"pending", "firing"} or not isinstance(labels, dict):
            continue
        normalized = {str(key): str(value) for key, value in labels.items()}
        key = canonical_labels(normalized)
        if key not in active_now:
            mismatches.append(StateMismatch(state=state, labels=labels_from_key(key)))

    return observations, mismatches


class MimirAPI:
    def __init__(self, api_url: str, tenant: str, timeout: float) -> None:
        self.api_url = api_url.rstrip("/")
        self.tenant = tenant
        self.timeout = timeout

    def get_json(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = f"?{urlencode(params)}" if params else ""
        request = Request(
            f"{self.api_url}/{path.lstrip('/')}{query}",
            headers={"Accept": "application/json", "X-Scope-OrgID": self.tenant},
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise DiagnosticError(f"Mimir {path} query failed: {error}") from error
        try:
            document = json.loads(payload)
        except (UnicodeDecodeError, ValueError) as error:
            raise DiagnosticError(f"Mimir {path} returned invalid JSON") from error
        if not isinstance(document, dict):
            raise DiagnosticError(f"Mimir {path} returned a non-object response")
        if document.get("status") != "success":
            detail = document.get("error", document.get("status"))
            raise DiagnosticError(f"Mimir {path} returned an unsuccessful response: {detail}")
        return document

    def query_range(
        self, expression: str, start: int, end: int, step: int
    ) -> list[dict[str, Any]]:
        document = self.get_json(
            "query_range",
            {
                "query": expression,
                "start": str(start),
                "end": str(end),
                "step": str(step),
            },
        )
        data = document.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("result"), list):
            raise DiagnosticError("Mimir query_range returned an invalid result")
        return [item for item in data["result"] if isinstance(item, dict)]

    def alert_states(self) -> dict[str, list[dict[str, Any]]]:
        document = self.get_json("rules", {"type": "alert"})
        data = document.get("data")
        if not isinstance(data, dict):
            raise DiagnosticError("Mimir rules returned an invalid result")
        states: dict[str, list[dict[str, Any]]] = {}
        for group in data.get("groups", []):
            if not isinstance(group, dict):
                continue
            for rule in group.get("rules", []):
                if not isinstance(rule, dict) or not isinstance(rule.get("name"), str):
                    continue
                alerts = rule.get("alerts", [])
                if isinstance(alerts, list):
                    states.setdefault(rule["name"], []).extend(
                        alert for alert in alerts if isinstance(alert, dict)
                    )
        return states


def tenant_names(args: argparse.Namespace) -> list[str]:
    if args.tenant:
        return list(dict.fromkeys(args.tenant))
    environment = os.environ.get("MIMIR_TENANTS") or os.environ.get("MIMIR_TENANT")
    if environment:
        return list(dict.fromkeys(item.strip() for item in environment.split(",") if item.strip()))
    return list(DEFAULT_TENANTS)


def run(args: argparse.Namespace) -> int:
    rules = load_rules(Path(args.rules_dir), set(args.rule_name))
    tenants = tenant_names(args)
    if not tenants:
        raise DiagnosticError("at least one tenant is required")
    if args.workers < 1:
        raise DiagnosticError("workers must be a positive integer")
    if args.timeout <= 0:
        raise DiagnosticError("timeout must be positive")
    if not float(args.step).is_integer() or not float(args.lookback).is_integer():
        raise DiagnosticError("lookback and step must be whole seconds")
    step = int(args.step)
    lookback = int(args.lookback)
    if step <= 0 or lookback < step or lookback % step:
        raise DiagnosticError(
            "lookback must be at least one positive whole step and step must be positive"
        )
    end = int(time.time())
    start = end - lookback

    errors: list[str] = []
    tasks: list[tuple[str, AlertRule]] = [
        (tenant, rule) for tenant in tenants for rule in rules
    ]
    query_results: list[tuple[str, AlertRule, list[dict[str, Any]]]] = []
    completed = 0

    def query_one(
        tenant: str, rule: AlertRule
    ) -> tuple[str, AlertRule, list[dict[str, Any]]]:
        api = MimirAPI(args.api_url, tenant, args.timeout)
        results = api.query_range(rule.expression, start, end, step)
        return tenant, rule, results

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = {
            pool.submit(query_one, tenant, rule): (tenant, rule)
            for tenant, rule in tasks
        }
        for future in as_completed(pending):
            tenant, rule = pending[future]
            try:
                query_results.append(future.result())
                completed += 1
            except DiagnosticError as error:
                errors.append(f"tenant={tenant} {rule.location}: {error}")
    # Fetch evaluator state after the range queries. This keeps the current
    # state comparison close to the range endpoint instead of comparing a
    # possibly several-minutes-old /rules response with a newer expression.
    states_by_tenant: dict[str, dict[str, list[dict[str, Any]]]] = {}
    with ThreadPoolExecutor(max_workers=min(args.workers, len(tenants))) as pool:
        pending_states = {
            pool.submit(MimirAPI(args.api_url, tenant, args.timeout).alert_states): tenant
            for tenant in tenants
        }
        for future in as_completed(pending_states):
            tenant = pending_states[future]
            try:
                states_by_tenant[tenant] = future.result()
            except DiagnosticError as error:
                errors.append(f"tenant={tenant} rules: {error}")
                states_by_tenant[tenant] = {}

    findings: list[tuple[str, AlertRule, StabilityObservation]] = []
    mismatches: list[tuple[str, AlertRule, StateMismatch]] = []
    for tenant, rule, results in query_results:
        observations, state_mismatches = analyze_query_result(
            rule,
            results,
            start,
            end,
            step,
            states_by_tenant.get(tenant, {}).get(rule.name, []),
        )
        for observation in observations:
            if observation.classification is not None:
                findings.append((tenant, rule, observation))
        for mismatch in state_mismatches:
            mismatches.append((tenant, rule, mismatch))

    for tenant, rule, observation in sorted(
        findings,
        key=lambda item: (item[0], item[1].name, labels_text(item[2].labels)),
    ):
        ratio = observation.ratio if observation.ratio is not None else 0.0
        print(
            f"! tenant={tenant} {rule.location}: {observation.classification} "
            f"max_active={format_duration(observation.max_active_seconds)} "
            f"for={format_duration(observation.for_seconds)} "
            f"active_duration_for_ratio={ratio:.3f} "
            f"active_runs={observation.active_runs} transitions={observation.transitions} "
            f"transition_frequency={observation.transition_frequency_per_hour:.2f}/h "
            f"current_active={str(observation.current_active).lower()} "
            f"duration_censored={str(observation.duration_censored).lower()} "
            f"labels={labels_text(observation.labels)}"
        )
    for tenant, rule, mismatch in sorted(
        mismatches,
        key=lambda item: (item[0], item[1].name, item[2].state, labels_text(item[2].labels)),
    ):
        print(
            f"! tenant={tenant} {rule.location}: {mismatch.state} state while "
            f"expression is currently inactive labels={labels_text(mismatch.labels)}"
        )
    for error in sorted(errors):
        print(f"! {error}", file=sys.stderr)

    never_sustained = sum(
        observation.classification == "high-churn, never-sustained"
        for _, _, observation in findings
    )
    range_censored = sum(
        observation.classification == "high-churn, range-censored"
        for _, _, observation in findings
    )
    print(
        f"Mimir alert stability diagnostic: tenants={len(tenants)} "
        f"rules={len(rules)} queries={completed}/{len(tasks)} "
        f"high_churn_never_sustained={never_sustained} "
        f"high_churn_range_censored={range_censored} "
        f"state_mismatches={len(mismatches)} errors={len(errors)} "
        f"lookback={format_duration(lookback)} step={format_duration(step)}"
    )
    # Findings are report data, not a CI or Alertmanager condition. Only an
    # incomplete live sweep is exceptional.
    return 2 if errors else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Report live Mimir alert churn; never emits an alert"
    )
    parser.add_argument(
        "--api-url",
        default=os.environ.get("MIMIR_API_URL", DEFAULT_API_URL),
        help="Mimir Prometheus API base ending in /api/v1",
    )
    parser.add_argument(
        "--tenant",
        action="append",
        default=[],
        help="X-Scope-OrgID tenant; repeat for multiple tenants",
    )
    parser.add_argument(
        "--rules-dir",
        default=str(DEFAULT_RULES_DIR),
        help="directory containing native Mimir rule YAML files",
    )
    parser.add_argument(
        "--rule-name",
        action="append",
        default=[],
        help="inspect only this alert name; may be repeated",
    )
    parser.add_argument(
        "--lookback",
        type=parse_duration,
        default=parse_duration(DEFAULT_LOOKBACK),
        help="range to inspect (default: 6h)",
    )
    parser.add_argument(
        "--step",
        type=parse_duration,
        default=parse_duration(DEFAULT_STEP),
        help="evaluation sample interval (default: 1m)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"concurrent Mimir queries (default: {DEFAULT_WORKERS})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help=f"HTTP timeout per request in seconds (default: {DEFAULT_TIMEOUT:g})",
    )
    return parser


def main() -> int:
    try:
        return run(build_parser().parse_args())
    except DiagnosticError as error:
        print(f"Mimir alert stability diagnostic failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
