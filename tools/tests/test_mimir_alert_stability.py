#!/usr/bin/env python3
"""Offline proof for the report-only live alert-stability diagnostic."""

from __future__ import annotations

import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/check-mimir-alert-stability.py"
FIXTURE = ROOT / "tools/tests/fixtures/alert-stability-unknown-toggle.json"
KUBELET_FIXTURE = ROOT / "tools/tests/fixtures/alert-stability-kubeletdown.json"


def load_tool():
    spec = importlib.util.spec_from_file_location("mimir_alert_stability", TOOL)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {TOOL}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    tool = load_tool()
    fixture = json.loads(FIXTURE.read_text())
    rule = tool.AlertRule(
        path=Path("flux.yaml"),
        group="flux.rules",
        name=fixture["rule"]["name"],
        expression='flux_resource_info{ready="Unknown"}',
        for_seconds=tool.parse_duration(fixture["rule"]["for"]),
        labels=fixture["rule"]["labels"],
    )
    observations, mismatches = tool.analyze_query_result(
        rule,
        fixture["results"],
        fixture["start"],
        fixture["end"],
        fixture["step"],
    )
    assert not mismatches, mismatches
    assert len(observations) == 1, observations
    observation = observations[0]
    assert fixture["ready_states"][2:5] == ["Unknown", "True", "Unknown"]
    assert observation.classification == fixture["expected"]["kind"]
    assert observation.high_churn_never_sustained
    assert observation.active_runs == fixture["expected"]["active_runs"]
    assert observation.max_active_seconds == fixture["expected"]["max_active_seconds"]
    assert observation.ratio == fixture["expected"]["ratio"]
    assert observation.transitions == fixture["expected"]["transition_count"]
    assert (
        observation.transition_frequency_per_hour
        == fixture["expected"]["transition_frequency_per_hour"]
    )
    assert observation.current_active == fixture["expected"]["current_active"]
    assert observation.duration_censored == fixture["expected"]["duration_censored"]

    # A multi-minute KubeletDown flap is a candidate for human triage, while
    # one-sample spikes are resolution-level noise. The latter still has two
    # separated runs and therefore exercises the active-duration floor rather
    # than being discarded by the existing run-count guard.
    kubelet_fixture = json.loads(KUBELET_FIXTURE.read_text())
    kubelet_rule = tool.AlertRule(
        path=Path("node-health.yaml"),
        group="node-health.rules",
        name=kubelet_fixture["rule"]["name"],
        expression='up{job="kubelet"} == 0',
        for_seconds=tool.parse_duration(kubelet_fixture["rule"]["for"]),
        labels=kubelet_fixture["rule"]["labels"],
    )
    for case in kubelet_fixture["cases"]:
        case_observations, case_mismatches = tool.analyze_query_result(
            kubelet_rule,
            case["results"],
            kubelet_fixture["start"],
            kubelet_fixture["end"],
            kubelet_fixture["step"],
        )
        assert not case_mismatches, case_mismatches
        assert len(case_observations) == 1, case_observations
        case_observation = case_observations[0]
        expected = case["expected"]
        assert case_observation.classification == expected["raw_kind"]
        assert (
            case_observation.report_category(kubelet_fixture["step"])
            == expected["report_category"]
        )
        assert case_observation.is_candidate(kubelet_fixture["step"]) == (
            expected["report_category"] == "candidate"
        )
        assert case_observation.active_runs == expected["active_runs"]
        assert case_observation.max_active_seconds == expected["max_active_seconds"]
        assert case_observation.ratio == expected["ratio"]
        assert case_observation.transitions == expected["transition_count"]
        assert case_observation.current_active == expected["current_active"]
        assert case_observation.duration_censored == expected["duration_censored"]

    # Native manifests use $$ to carry a literal $ through Flux substitution;
    # live queries must use the deployed expression form.
    assert tool.query_expression('label_replace(vector(1), "name", "$$1", "x", ".*")') == (
        'label_replace(vector(1), "name", "$1", "x", ".*")'
    )

    # Mimir can split a matrix response into more than one item while the
    # output label set remains the same. The alert identity must be merged by
    # output labels, not by the response item's boundaries.
    split_results = [
        {**copy.deepcopy(fixture["results"][0]), "values": [[60, "1"], [120, "1"]]},
        {**copy.deepcopy(fixture["results"][0]), "values": [[240, "1"], [300, "1"]]},
    ]
    split_observations, _ = tool.analyze_query_result(
        rule,
        split_results,
        fixture["start"],
        fixture["end"],
        fixture["step"],
    )
    assert len(split_observations) == 1, split_observations
    assert split_observations[0].classification == "high-churn, never-sustained"

    # The same diagnostic must recognize a pending state after the expression
    # has gone inactive; this is the second live signal that the sweep reports.
    _, stale = tool.analyze_query_result(
        rule,
        [
            {
                **copy.deepcopy(fixture["results"][0]),
                "values": fixture["results"][0]["values"][:-1],
            }
        ],
        fixture["start"],
        fixture["end"],
        fixture["step"],
        state_alerts=[
            {
                "state": "pending",
                "labels": {
                    "alertname": "FluxKustomizationUnknown",
                    "cluster": "talos-test",
                    "kind": "Kustomization",
                    "name": "reconciling",
                    "namespace": "flux-system",
                    "path": "./reconciling",
                    "severity": "critical",
                },
            },
            {
                "state": "firing",
                "labels": {
                    "alertname": "FluxKustomizationUnknown",
                    "cluster": "talos-test",
                    "kind": "Kustomization",
                    "name": "reconciling",
                    "namespace": "flux-system",
                    "path": "./reconciling",
                    "severity": "critical",
                },
            },
        ],
    )
    assert {item.state for item in stale} == {"pending", "firing"}, stale

    # A current expression result with the same output labels is not stale,
    # even when the evaluator reports it as firing.
    active_results = copy.deepcopy(fixture["results"])
    active_results[0]["values"].append([360, "1"])
    _, active_state = tool.analyze_query_result(
        rule,
        active_results,
        fixture["start"],
        fixture["end"],
        fixture["step"],
        state_alerts=[
            {
                "state": "firing",
                "labels": {
                    "alertname": "FluxKustomizationUnknown",
                    "cluster": "talos-test",
                    "kind": "Kustomization",
                    "name": "reconciling",
                    "namespace": "flux-system",
                    "path": "./reconciling",
                    "severity": "critical",
                },
            }
        ],
    )
    assert not active_state, active_state

    # Findings are informational: a complete sweep with a candidate must still
    # return success. This guards the report-only contract against accidentally
    # becoming a CI/Alertmanager condition. The default output omits a pair of
    # one-sample spikes and a stale evaluator state; --all restores both.
    with tempfile.TemporaryDirectory(prefix="mimir-alert-stability-") as temporary:
        rules_dir = Path(temporary)
        (rules_dir / "rules.yaml").write_text(
            """groups:
  - name: test.rules
    rules:
      - alert: ToggleCandidate
        expr: vector(1)
        for: 5m
      - alert: ToggleShort
        expr: vector(2)
        for: 5m
"""
        )

        class FakeAPI:
            def __init__(self, api_url, tenant, timeout):
                del api_url, tenant, timeout

            def query_range(self, expression, start, end, step):
                if expression == "vector(1)":
                    values = [
                        [start + step, "1"],
                        [start + 2 * step, "1"],
                        [start + 4 * step, "1"],
                        [start + 5 * step, "1"],
                    ]
                else:
                    assert expression == "vector(2)"
                    values = [
                        [start + step, "1"],
                        [start + 4 * step, "1"],
                    ]
                return [
                    {
                        "metric": {"cluster": "talos-test"},
                        "values": values,
                    }
                ]

            def alert_states(self):
                return {
                    "ToggleCandidate": [],
                    "ToggleShort": [
                        {
                            "state": "pending",
                            "labels": {
                                "alertname": "ToggleShort",
                                "cluster": "talos-test",
                            },
                        }
                    ],
                }

        original_api = tool.MimirAPI
        tool.MimirAPI = FakeAPI
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = tool.run(
                    SimpleNamespace(
                        rules_dir=str(rules_dir),
                        rule_name=[],
                        tenant=["talos-test"],
                        api_url="http://mimir.test/api/v1",
                        lookback=360,
                        step=60,
                        workers=2,
                        timeout=1,
                        min_active_duration=None,
                        show_all=False,
                    )
                )
            assert result == 0
            default_output = output.getvalue()
            assert "candidate tenant=talos-test" in default_output
            assert "ToggleCandidate" in default_output
            assert "ToggleShort" not in default_output
            assert "candidates=1" in default_output
            assert "suppressed_short_activity=1" in default_output
            assert "state_mismatches=1" in default_output
            assert "mode=candidates" in default_output

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = tool.run(
                    SimpleNamespace(
                        rules_dir=str(rules_dir),
                        rule_name=[],
                        tenant=["talos-test"],
                        api_url="http://mimir.test/api/v1",
                        lookback=360,
                        step=60,
                        workers=2,
                        timeout=1,
                        min_active_duration=None,
                        show_all=True,
                    )
                )
            assert result == 0
            all_output = output.getvalue()
            assert "candidate tenant=talos-test" in all_output
            assert "suppressed-short-activity tenant=talos-test" in all_output
            assert "ToggleShort" in all_output
            assert "state-mismatch tenant=talos-test" in all_output
            assert "mode=all" in all_output
        finally:
            tool.MimirAPI = original_api

    print("✓ Mimir alert stability: Unknown -> True -> Unknown is high-churn, never-sustained")
    print(
        "✓ Mimir alert stability: KubeletDown 3m is a candidate; "
        "one-sample spikes are suppressed"
    )
    print("✓ Mimir alert stability: output labels merge split response items")
    print("✓ Mimir alert stability: pending/firing state while expression is inactive is reported")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
