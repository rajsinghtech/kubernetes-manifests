#!/usr/bin/env python3
"""Offline proof for the live Mimir label-contract checker."""

from __future__ import annotations

import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/check-mimir-label-contract.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("mimir_label_contract", TOOL)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {TOOL}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeMimirHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        query = parse_qs(urlparse(self.path).query)
        selector = query.get("match[]", [""])[0]
        if selector.startswith("kopiur_snapshotpolicy_last_backup_success"):
            family = [
                {
                    "__name__": "kopiur_snapshotpolicy_last_backup_success",
                    "cluster": "talos-stpetersburg",
                    "namespace": "kopiur-system",
                    "exported_namespace": "home-assistant",
                    "policy": "homeassistant-config",
                }
            ]
            # This is the pre-#2924 selector: the family exists, but the
            # namespace matcher cannot match the stored series.
            if selector.startswith(
                'kopiur_snapshotpolicy_last_backup_success{namespace="home-assistant"'
            ):
                result = []
            else:
                result = family
        elif selector.startswith("kopiur_leader_is_leader"):
            result = [
                {
                    "__name__": "kopiur_leader_is_leader",
                    "cluster": "talos-stpetersburg",
                }
            ]
        elif selector.startswith("optional_component_metric"):
            # The entire family is absent. This is a legitimate quiet or
            # undeployed component and must not fail the checker.
            result = []
        else:
            result = []

        body = json.dumps({"status": "success", "data": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


def run_checker(rule_dir: Path, server: ThreadingHTTPServer) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            str(TOOL),
            "--api-url",
            f"http://127.0.0.1:{server.server_port}/prometheus/api/v1",
            "--tenant",
            "talos-stpetersburg",
            "--rules-dir",
            str(rule_dir),
            "--lookback",
            "1h",
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> int:
    tool = load_tool()
    extracted = tool.extract_selectors(
        'label_replace(metric_a{namespace="x"}, "namespace", "$1", "namespace", "(.+)") '
        'and on (cluster, namespace) metric_b{state=~"ready|pending"}'
    )
    extracted_text = {selector.text for selector in extracted}
    assert extracted_text == {
        'metric_a{namespace="x"}',
        'metric_b{state=~"ready|pending"}',
    }, extracted_text

    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeMimirHandler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="mimir-label-contract-") as temporary:
            root = Path(temporary)
            old_rule = """groups:
  - name: kopiur.rules
    rules:
      - alert: KopiurSnapshotFailed
        expr: |
          kopiur_snapshotpolicy_last_backup_success{namespace="home-assistant",policy="homeassistant-config"} == 0
          and on (cluster) kopiur_leader_is_leader
      - alert: OptionalComponentMissing
        expr: optional_component_metric{state="ready"} == 0
"""
            new_rule = old_rule.replace(
                'namespace="home-assistant",policy=',
                'exported_namespace="home-assistant",policy=',
            )

            old_dir = root / "old"
            new_dir = root / "new"
            old_dir.mkdir()
            new_dir.mkdir()
            (old_dir / "kopiur.yaml").write_text(old_rule)
            (new_dir / "kopiur.yaml").write_text(new_rule)

            old_result = run_checker(old_dir, server)
            assert old_result.returncode == 1, old_result
            assert "family exists" in old_result.stderr, old_result.stderr
            assert 'namespace="home-assistant"' in old_result.stderr, old_result.stderr
            assert "absent; skipped" in old_result.stdout, old_result.stdout

            new_result = run_checker(new_dir, server)
            assert new_result.returncode == 0, new_result
            assert "failed=0" in new_result.stdout, new_result.stdout
            assert "absent; skipped" in new_result.stdout, new_result.stdout

    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()

    print("✓ Mimir live label-contract checker: pre-fix fails, post-fix passes")
    print("✓ Mimir live label-contract checker: absent metric families are skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
