#!/usr/bin/env python3
"""Compare the GitOps-declared Mimir rule groups with the live ruler.

This process deliberately runs outside the Mimir rules loader.  It sends its
own alerts to Alertmanager so an incomplete loader sync cannot also remove the
rule that would report the incompleteness.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_TENANTS = (
    "talos-ottawa",
    "talos-robbinsdale",
    "talos-stpetersburg",
)
DEFAULT_EXPECTED_PATH = "/scripts/expected-groups.tsv"
DEFAULT_MIMIR_RULES_URL = (
    "http://mimir-gateway.mimir.svc.cluster.local:8080"
    "/prometheus/api/v1/rules"
)
DEFAULT_ALERTMANAGER_URL = (
    "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
    "/api/v2/alerts"
)


class CheckError(RuntimeError):
    """The live ruler response could not be checked safely."""


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value: dt.datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def load_expected(path: Path) -> set[tuple[str, str]]:
    expected: set[tuple[str, str]] = set()
    for line_number, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = raw_line.split("\t")
        if len(fields) != 2 or not all(field.strip() for field in fields):
            raise CheckError(
                f"{path}:{line_number}: expected namespace<TAB>group"
            )
        identity = (fields[0].strip(), fields[1].strip())
        if identity in expected:
            raise CheckError(f"{path}:{line_number}: duplicate group {identity!r}")
        expected.add(identity)
    if not expected:
        raise CheckError(f"{path}: expected at least one rule group")
    return expected


def ruler_groups(payload: dict) -> set[tuple[str, str]]:
    if payload.get("status") != "success":
        raise CheckError(f"ruler API returned {payload.get('status')!r}")
    groups = payload.get("data", {}).get("groups")
    if not isinstance(groups, list):
        raise CheckError("ruler API response has no data.groups list")

    actual: set[tuple[str, str]] = set()
    for group in groups:
        if not isinstance(group, dict):
            raise CheckError("ruler API returned a non-object rule group")
        namespace = group.get("file")
        name = group.get("name")
        if not isinstance(namespace, str) or not namespace:
            raise CheckError("ruler API returned a group without file")
        if not isinstance(name, str) or not name:
            raise CheckError("ruler API returned a group without name")
        actual.add((namespace, name))
    return actual


def compare_groups(
    expected: set[tuple[str, str]], actual: set[tuple[str, str]]
) -> tuple[set[tuple[str, str]], set[tuple[str, str]]]:
    """Return (missing, unexpected) without treating a partial set as healthy."""

    return expected - actual, actual - expected


def get_ruler_groups(url: str, tenant: str, timeout: float) -> set[tuple[str, str]]:
    request = Request(
        url,
        headers={"Accept": "application/json", "X-Scope-OrgID": tenant},
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError) as error:
        raise CheckError(f"ruler query failed: {error}") from error
    if not isinstance(payload, dict):
        raise CheckError("ruler API returned a non-object JSON response")
    return ruler_groups(payload)


def alert_payload(
    alertname: str,
    tenant: str,
    summary: str,
    description: str,
    starts_at: dt.datetime,
    ends_at: dt.datetime,
    cluster: str,
) -> dict:
    return {
        "labels": {
            "alertname": alertname,
            "cluster": cluster,
            "job": "mimir-rule-completeness",
            "severity": "critical",
            "tenant": tenant,
        },
        "annotations": {
            "summary": summary,
            "description": description,
        },
        "startsAt": timestamp(starts_at),
        "endsAt": timestamp(ends_at),
    }


def send_alerts(
    alerts: list[dict],
    url: str,
    timeout: float,
    dry_run: bool,
) -> None:
    if not alerts:
        return
    if dry_run:
        for alert in alerts:
            print(json.dumps(alert, sort_keys=True))
        return
    request = Request(
        url,
        data=json.dumps(alerts).encode("utf-8"),
        headers={"Accept": "application/json", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            response.read()
    except (HTTPError, URLError, TimeoutError, OSError) as error:
        raise CheckError(f"Alertmanager notification failed: {error}") from error


def fixture_payload(path: Path, tenant: str) -> dict:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"fixture could not be read: {error}") from error
    if isinstance(payload, dict) and "status" in payload:
        return payload
    if isinstance(payload, dict) and isinstance(payload.get(tenant), dict):
        return payload[tenant]
    raise CheckError(f"fixture has no ruler response for {tenant}")


def replay_fixture(expected_path: Path, fixture_path: Path, tenant: str) -> int:
    expected = load_expected(expected_path)
    actual = ruler_groups(fixture_payload(fixture_path, tenant))
    missing, unexpected = compare_groups(expected, actual)
    print(f"tenant={tenant} expected_groups={len(expected)} actual_groups={len(actual)}")
    print("missing=" + ",".join(sorted(f"{namespace}/{name}" for namespace, name in missing)))
    print(
        "unexpected="
        + ",".join(sorted(f"{namespace}/{name}" for namespace, name in unexpected))
    )
    if missing:
        print("DETECTOR WOULD FIRE: declared group set is incomplete")
        return 1
    print("DETECTOR WOULD NOT FIRE: declared group set is complete")
    return 0


def run_loop(args: argparse.Namespace, expected: set[tuple[str, str]]) -> int:
    tenants = tuple(
        tenant.strip()
        for tenant in args.tenants.split(",")
        if tenant.strip()
    )
    if not tenants:
        raise CheckError("TENANTS must contain at least one tenant")

    missing_since: dict[str, dt.datetime] = {}
    firing_since: dict[str, dt.datetime] = {}
    last_missing: dict[str, set[tuple[str, str]]] = {}
    error_since: dict[str, dt.datetime] = {}
    error_firing_since: dict[str, dt.datetime] = {}

    while True:
        current = now_utc()
        alerts: list[dict] = []
        for tenant in tenants:
            try:
                actual = get_ruler_groups(args.mimir_rules_url, tenant, args.timeout)
            except CheckError as error:
                print(f"tenant={tenant} check failed: {error}", file=sys.stderr)
                error_since.setdefault(tenant, current)
                if (
                    current - error_since[tenant]
                ).total_seconds() >= args.grace_seconds:
                    error_firing_since.setdefault(tenant, error_since[tenant])
                    alerts.append(
                        alert_payload(
                            "MimirRuleCompletenessCheckerFailed",
                            tenant,
                            f"Mimir rule completeness check failed for {tenant}",
                            f"The live ruler group set could not be checked: {error}",
                            error_firing_since[tenant],
                            current + dt.timedelta(seconds=args.alert_ttl_seconds),
                            args.cluster,
                        )
                    )
                if tenant in firing_since and tenant in last_missing:
                    alerts.append(
                        alert_payload(
                            "MimirRuleGroupIncomplete",
                            tenant,
                            f"Mimir rule group set remains incomplete for {tenant}",
                            "The last successful comparison was missing: "
                            + ", ".join(
                                f"{namespace}/{name}"
                                for namespace, name in sorted(last_missing[tenant])
                            ),
                            firing_since[tenant],
                            current + dt.timedelta(seconds=args.alert_ttl_seconds),
                            args.cluster,
                        )
                    )
                continue

            if tenant in error_firing_since:
                alerts.append(
                    alert_payload(
                        "MimirRuleCompletenessCheckerFailed",
                        tenant,
                        f"Mimir rule completeness check recovered for {tenant}",
                        "The ruler API is responding again.",
                        error_firing_since.pop(tenant),
                        current,
                        args.cluster,
                    )
                )
            error_since.pop(tenant, None)

            missing, unexpected = compare_groups(expected, actual)
            if unexpected:
                print(
                    f"tenant={tenant} unexpected groups: "
                    + ", ".join(f"{namespace}/{name}" for namespace, name in sorted(unexpected)),
                    file=sys.stderr,
                )
            if missing:
                missing_since.setdefault(tenant, current)
                last_missing[tenant] = missing
                if (
                    current - missing_since[tenant]
                ).total_seconds() >= args.grace_seconds:
                    firing_since.setdefault(tenant, missing_since[tenant])
                    alerts.append(
                        alert_payload(
                            "MimirRuleGroupIncomplete",
                            tenant,
                            f"Mimir rule group set incomplete for {tenant}",
                            "The ruler is missing declared group(s): "
                            + ", ".join(
                                f"{namespace}/{name}" for namespace, name in sorted(missing)
                            ),
                            firing_since[tenant],
                            current + dt.timedelta(seconds=args.alert_ttl_seconds),
                            args.cluster,
                        )
                    )
            elif tenant in firing_since:
                alerts.append(
                    alert_payload(
                        "MimirRuleGroupIncomplete",
                        tenant,
                        f"Mimir rule group set recovered for {tenant}",
                        "The live ruler now contains every declared rule group.",
                        firing_since.pop(tenant),
                        current,
                        args.cluster,
                    )
                )
                missing_since.pop(tenant, None)
                last_missing.pop(tenant, None)
            else:
                missing_since.pop(tenant, None)
                last_missing.pop(tenant, None)

        try:
            send_alerts(alerts, args.alertmanager_url, args.timeout, args.dry_run)
        except CheckError as error:
            print(str(error), file=sys.stderr)

        if args.once:
            return 0
        time.sleep(args.poll_seconds)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--expected",
        default=os.environ.get("EXPECTED_GROUPS_PATH", DEFAULT_EXPECTED_PATH),
        type=Path,
    )
    parser.add_argument(
        "--actual-json",
        type=Path,
        help="replay one ruler API response instead of querying the live API",
    )
    parser.add_argument("--tenant", default="talos-ottawa")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--mimir-rules-url",
        default=os.environ.get("MIMIR_RULES_URL", DEFAULT_MIMIR_RULES_URL),
    )
    parser.add_argument(
        "--alertmanager-url",
        default=os.environ.get("ALERTMANAGER_URL", DEFAULT_ALERTMANAGER_URL),
    )
    parser.add_argument(
        "--tenants",
        default=os.environ.get("TENANTS", ",".join(DEFAULT_TENANTS)),
    )
    parser.add_argument(
        "--cluster",
        default=os.environ.get("CHECKER_CLUSTER", "talos-ottawa"),
    )
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=float(os.environ.get("POLL_INTERVAL_SECONDS", "60")),
    )
    parser.add_argument(
        "--grace-seconds",
        type=float,
        default=float(os.environ.get("MISSING_GROUP_GRACE_SECONDS", "300")),
    )
    parser.add_argument(
        "--alert-ttl-seconds",
        type=float,
        default=float(os.environ.get("ALERT_TTL_SECONDS", "180")),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("HTTP_TIMEOUT_SECONDS", "10")),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        expected = load_expected(args.expected)
        if args.actual_json:
            return replay_fixture(args.expected, args.actual_json, args.tenant)
        return run_loop(args, expected)
    except (CheckError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
