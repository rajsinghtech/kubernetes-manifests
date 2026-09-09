#!/usr/bin/env python3
"""Check native Mimir rule selectors against live Mimir series.

PromQL parsing and fixture tests prove that an expression is syntactically
valid and behaves as expected for the labels the fixture invents.  They do not
prove that the selector matches the labels which the remote-write path
actually stores.  This checker closes that gap without evaluating the rule:
for every metric selector in every rule, it asks Mimir whether the metric
family exists and whether the complete selector matches any series.

An absent family is deliberately not an error.  Rule files are shared by all
three tenants and some components are intentionally absent from a tenant.  A
present family with a zero-match selector is different: it is evidence that a
label contract (or a selector spelling) is wrong.

The checker is intentionally one-shot.  Run it from a periodic in-cluster
process with network access to Mimir and have that process report a non-zero
exit as an operational alert.  It must not be made a PR-only check and called
healthy merely because the PR runner cannot reach the live tenant.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

try:
    import yaml
except ImportError as error:  # pragma: no cover - exercised by deployment errors
    raise SystemExit(
        "PyYAML is required to read native Mimir rule files"
    ) from error


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES_DIR = ROOT / "kubernetes/apps/base/mimir/mimir-ottawa/rules"
DEFAULT_API_URL = (
    "http://mimir-gateway.mimir.svc.cluster.local:8080"
    "/prometheus/api/v1"
)
DEFAULT_LOOKBACK = "24h"
DEFAULT_TIMEOUT = 10.0

IDENTIFIER_START = re.compile(r"[A-Za-z_:]")
IDENTIFIER_CONTINUE = re.compile(r"[A-Za-z0-9_:]")
PROMQL_MATCHER = re.compile(
    r'''([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*"((?:\\.|[^"\\])*)"'''
)

# These words can occur outside a selector but are not metric names.  Function
# names are handled separately when followed by "("; keeping the aggregation
# and binary-operator words here covers `sum by (...)` and `on (...)` too.
PROMQL_WORDS = {
    "and",
    "bool",
    "by",
    "group_left",
    "group_right",
    "ignoring",
    "in",
    "on",
    "or",
    "unless",
    "without",
    "offset",
    "sum",
    "min",
    "max",
    "avg",
    "count",
    "stddev",
    "stdvar",
    "bottomk",
    "topk",
    "count_values",
    "quantile",
    "limitk",
    "limit_ratio",
    "true",
    "false",
}


@dataclasses.dataclass(frozen=True)
class Selector:
    metric: str
    text: str
    has_matchers: bool


@dataclasses.dataclass(frozen=True)
class RuleSelector:
    path: Path
    rule_kind: str
    rule_name: str
    selector: Selector

    @property
    def location(self) -> str:
        return f"{self.path.name}:{self.rule_kind}={self.rule_name}"


class CheckError(RuntimeError):
    """The live Mimir response or a rule file could not be checked safely."""


def skip_string(expression: str, index: int) -> int:
    """Return the index immediately after a PromQL quoted string."""

    assert expression[index] == '"'
    index += 1
    while index < len(expression):
        if expression[index] == "\\":
            index += 2
        elif expression[index] == '"':
            return index + 1
        else:
            index += 1
    raise CheckError("unterminated string in PromQL expression")


def balanced_braces(expression: str, index: int) -> tuple[str, int]:
    """Return selector contents and the index after its closing brace."""

    assert expression[index] == "{"
    start = index
    index += 1
    while index < len(expression):
        if expression[index] == '"':
            index = skip_string(expression, index)
            continue
        if expression[index] == "}":
            return expression[start + 1 : index], index + 1
        index += 1
    raise CheckError("unterminated label selector in PromQL expression")


def skip_parentheses(expression: str, index: int) -> int:
    """Return the index immediately after a parenthesized label list."""

    assert expression[index] == "("
    depth = 0
    while index < len(expression):
        if expression[index] == '"':
            index = skip_string(expression, index)
            continue
        if expression[index] == "(":
            depth += 1
        elif expression[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise CheckError("unterminated PromQL label list")


def extract_selectors(expression: str) -> list[Selector]:
    """Extract metric vector selectors without mistaking functions for metrics.

    This is a lexer for the selector-shaped part of PromQL, not a PromQL
    evaluator.  The repository already runs the pinned Prometheus parser for
    syntax validation.  Keeping this extraction independent means the live
    check only needs Python, PyYAML, and the Mimir HTTP API.
    """

    selectors: list[Selector] = []
    seen: set[tuple[str, str]] = set()
    index = 0
    while index < len(expression):
        char = expression[index]
        if char == '"':
            index = skip_string(expression, index)
            continue
        if not IDENTIFIER_START.fullmatch(char):
            index += 1
            continue

        end = index + 1
        while end < len(expression) and IDENTIFIER_CONTINUE.fullmatch(expression[end]):
            end += 1
        name = expression[index:end]
        cursor = end
        while cursor < len(expression) and expression[cursor].isspace():
            cursor += 1

        if cursor < len(expression) and expression[cursor] == "{":
            contents, after = balanced_braces(expression, cursor)
            normalized_contents = re.sub(r"\s+", " ", contents).strip()
            selector_text = f"{name}{{{normalized_contents}}}"
            selector = Selector(name, selector_text, bool(normalized_contents))
            identity = (selector.metric, selector.text)
            if identity not in seen:
                selectors.append(selector)
                seen.add(identity)
            index = after
            continue

        if name in {"by", "ignoring", "on", "without", "group_left", "group_right"}:
            if cursor < len(expression) and expression[cursor] == "(":
                index = skip_parentheses(expression, cursor)
                continue
        # A function/aggregation name is followed by "(".  Do not skip the
        # parenthesized expression: it may contain the real metric selector.
        if cursor < len(expression) and expression[cursor] == "(":
            index = end
            continue
        if name in PROMQL_WORDS:
            index = end
            continue

        selector = Selector(name, name, False)
        identity = (selector.metric, selector.text)
        if identity not in seen:
            selectors.append(selector)
            seen.add(identity)
        index = end

    return selectors


def parse_matchers(selector: Selector) -> list[tuple[str, str, str]]:
    """Return (label, operator, PromQL string contents) for label matchers."""

    if not selector.has_matchers:
        return []
    contents = selector.text[selector.text.find("{") + 1 : -1]
    matchers = [match.groups() for match in PROMQL_MATCHER.finditer(contents)]
    # The checker sends the original selector to Mimir, but fail closed if its
    # simple matcher view cannot account for the full contents.  Otherwise a
    # malformed selector could be silently classified as tenant-independent.
    remainder = PROMQL_MATCHER.sub("", contents)
    if remainder.replace(",", "").strip():
        raise CheckError(f"unsupported label matcher syntax in {selector.text!r}")
    return matchers


def promql_unescape(value: str) -> str:
    return re.sub(r"\\(.)", r"\1", value)


def targets_another_tenant(selector: Selector, tenant: str) -> bool:
    """Skip an explicit cluster selector belonging to another Mimir tenant."""

    for label, operator, raw_value in parse_matchers(selector):
        if label != "cluster":
            continue
        value = promql_unescape(raw_value)
        if operator == "=" and value != tenant:
            return True
        if operator == "=~":
            try:
                if re.fullmatch(value, tenant) is None:
                    return True
            except re.error as error:
                raise CheckError(
                    f"invalid cluster matcher {selector.text!r}: {error}"
                ) from error
        if operator == "!=" and value == tenant:
            return True
        if operator == "!~":
            try:
                if re.fullmatch(value, tenant) is not None:
                    return True
            except re.error as error:
                raise CheckError(
                    f"invalid cluster matcher {selector.text!r}: {error}"
                ) from error
    return False


def iter_rule_selectors(
    paths: Iterable[Path], requested_rule_names: set[str] | None = None
) -> Iterable[RuleSelector]:
    for path in paths:
        try:
            documents = yaml.safe_load_all(path.read_text())
            loaded = list(documents)
        except (OSError, yaml.YAMLError) as error:
            raise CheckError(f"cannot read {path}: {error}") from error

        for document in loaded:
            if not isinstance(document, dict):
                continue
            for group in document.get("groups", []):
                if not isinstance(group, dict):
                    continue
                for rule in group.get("rules", []):
                    if not isinstance(rule, dict):
                        continue
                    rule_kind = "alert" if isinstance(rule.get("alert"), str) else "record"
                    rule_name = rule.get(rule_kind)
                    expression = rule.get("expr")
                    if not isinstance(rule_name, str) or not isinstance(expression, str):
                        continue
                    if requested_rule_names and rule_name not in requested_rule_names:
                        continue
                    for selector in extract_selectors(expression):
                        yield RuleSelector(path, rule_kind, rule_name, selector)


def parse_duration(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smhd])", value.strip())
    if not match:
        raise argparse.ArgumentTypeError(
            f"invalid duration {value!r}; use e.g. 6h, 24h, or 30m"
        )
    amount = float(match.group(1))
    multiplier = {"s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2)]
    return amount * multiplier


class MimirSeriesAPI:
    def __init__(
        self,
        api_url: str,
        tenant: str,
        start: float,
        end: float,
        timeout: float,
    ) -> None:
        self.series_url = api_url.rstrip("/") + "/series"
        self.tenant = tenant
        self.start = start
        self.end = end
        self.timeout = timeout
        self.cache: dict[str, list[dict]] = {}

    def series(self, selector: str) -> list[dict]:
        if selector in self.cache:
            return self.cache[selector]
        query = urlencode(
            {
                "match[]": selector,
                "start": f"{self.start:.3f}",
                "end": f"{self.end:.3f}",
            }
        )
        request = Request(
            f"{self.series_url}?{query}",
            headers={"Accept": "application/json", "X-Scope-OrgID": self.tenant},
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise CheckError(f"Mimir series query failed for {selector!r}: {error}") from error
        try:
            document = json.loads(payload)
        except (UnicodeDecodeError, ValueError) as error:
            raise CheckError(f"Mimir returned invalid JSON for {selector!r}") from error
        if not isinstance(document, dict) or document.get("status") != "success":
            detail = document.get("error", document.get("status")) if isinstance(document, dict) else document
            raise CheckError(f"Mimir returned an unsuccessful response for {selector!r}: {detail}")
        data = document.get("data")
        if not isinstance(data, list) or not all(isinstance(item, dict) for item in data):
            raise CheckError(f"Mimir returned an invalid series list for {selector!r}")
        self.cache[selector] = data
        return data


def rule_paths(rules_dir: Path, explicit_paths: list[str]) -> list[Path]:
    if explicit_paths:
        paths = [Path(path).resolve() for path in explicit_paths]
    else:
        paths = sorted(rules_dir.glob("*.yaml")) + sorted(rules_dir.glob("*.yml"))
    if not paths:
        raise CheckError(f"no Mimir rule files found under {rules_dir}")
    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise CheckError("rule file(s) not found: " + ", ".join(map(str, missing)))
    return paths


def run(args: argparse.Namespace) -> int:
    if not args.api_url:
        raise CheckError("--api-url or MIMIR_API_URL is required")
    if not args.tenant:
        raise CheckError("--tenant or MIMIR_TENANT is required")

    paths = rule_paths(Path(args.rules_dir), args.rule_file)
    requested_names = set(args.rule_name)
    selectors = list(iter_rule_selectors(paths, requested_names or None))
    if not selectors:
        raise CheckError("no rule selectors were extracted")

    end = time.time()
    api = MimirSeriesAPI(
        args.api_url,
        args.tenant,
        end - args.lookback,
        end,
        args.timeout,
    )
    checked = matched = absent = skipped = failed = errors = 0

    for occurrence in selectors:
        selector = occurrence.selector
        if targets_another_tenant(selector, args.tenant):
            skipped += 1
            print(
                f"⊘ {occurrence.location}: {selector.text} "
                f"(explicit cluster selector excludes tenant {args.tenant})"
            )
            continue
        checked += 1
        try:
            family = api.series(selector.metric)
            if not family:
                absent += 1
                print(
                    f"⊘ {occurrence.location}: {selector.text} "
                    f"(metric family {selector.metric!r} absent; skipped)"
                )
                continue
            selected = api.series(selector.text)
        except CheckError as error:
            errors += 1
            print(f"! {occurrence.location}: {error}", file=sys.stderr)
            continue
        if selected:
            matched += 1
            print(
                f"✓ {occurrence.location}: {selector.text} "
                f"({len(selected)} matching series; family={len(family)})"
            )
        else:
            failed += 1
            print(
                f"✗ {occurrence.location}: {selector.text} "
                f"(family exists with {len(family)} series, selector matches zero)",
                file=sys.stderr,
            )

    print(
        f"Mimir label contract: tenant={args.tenant} rules={len(paths)} "
        f"selectors={checked} matched={matched} absent={absent} "
        f"cross-tenant={skipped} failed={failed} errors={errors}"
    )
    if errors:
        return 2
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check native Mimir selectors against live tenant series"
    )
    parser.add_argument(
        "--api-url",
        default=os.environ.get("MIMIR_API_URL", DEFAULT_API_URL),
        help="Mimir Prometheus API base ending in /api/v1",
    )
    parser.add_argument(
        "--tenant",
        default=os.environ.get("MIMIR_TENANT"),
        help="X-Scope-OrgID tenant to inspect",
    )
    parser.add_argument(
        "--rules-dir",
        default=str(DEFAULT_RULES_DIR),
        help="directory containing native Mimir rule YAML files",
    )
    parser.add_argument(
        "--rule-file",
        action="append",
        default=[],
        help="check only this rule file; may be repeated",
    )
    parser.add_argument(
        "--rule-name",
        action="append",
        default=[],
        help="check only this alert/record name; may be repeated",
    )
    parser.add_argument(
        "--lookback",
        type=parse_duration,
        default=parse_duration(DEFAULT_LOOKBACK),
        help="series lookback window (default: 24h)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help="HTTP timeout in seconds (default: 10)",
    )
    return parser


def main() -> int:
    try:
        return run(build_parser().parse_args())
    except CheckError as error:
        print(f"Mimir label contract check failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
