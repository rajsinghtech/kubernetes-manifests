#!/usr/bin/env python3
"""Replay km#2809: a successful-looking ruler missing one declared group."""

from pathlib import Path
import sys


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from rule_completeness import compare_groups, load_expected, ruler_groups  # noqa: E402


EXPECTED = SCRIPT_DIR / "expected-groups.tsv"


def main() -> int:
    expected = load_expected(EXPECTED)
    omitted = ("bhaiya-workspace-image", "bhaiya-workspace-image.rules")

    # This is the concrete km#2809 state: the live ruler returns every group
    # except one file that remains declared by GitOps.
    simulated_ruler = set(expected)
    simulated_ruler.remove(omitted)
    ruler_response = {
        "status": "success",
        "data": {
            "groups": [
                {"file": namespace, "name": name}
                for namespace, name in sorted(simulated_ruler)
            ]
        },
    }
    parsed_ruler = ruler_groups(ruler_response)

    missing, unexpected = compare_groups(expected, parsed_ruler)
    assert missing == {omitted}, (missing, unexpected)
    assert not unexpected, unexpected
    print(
        "✓ km#2809 replay: ruler omitted "
        f"{omitted[0]}/{omitted[1]}; detector flags it"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
