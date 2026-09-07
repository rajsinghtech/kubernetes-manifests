#!/usr/bin/env python3
"""Extract the HelmRelease v2 schema from a pinned Flux CRD.

The output is intentionally deterministic. Kubernetes object maps with a
declared property set become closed objects for kubeconform strict mode, while
objects explicitly marked x-kubernetes-preserve-unknown-fields (notably
spec.values) retain their opaque extensibility.
"""
import json
import pathlib
import sys

import yaml


def close_objects(value):
    if isinstance(value, dict):
        if (
            value.get("type") == "object"
            and "properties" in value
            and "additionalProperties" not in value
            and not value.get("x-kubernetes-preserve-unknown-fields")
        ):
            value["additionalProperties"] = False
        for child in value.values():
            close_objects(child)
    elif isinstance(value, list):
        for child in value:
            close_objects(child)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} CRD-YAML OUTPUT-JSON")
    source, output = map(pathlib.Path, sys.argv[1:])
    for document in yaml.safe_load_all(source.read_text()):
        if (
            isinstance(document, dict)
            and document.get("kind") == "CustomResourceDefinition"
            and document.get("metadata", {}).get("name")
            == "helmreleases.helm.toolkit.fluxcd.io"
        ):
            version = next(
                item for item in document["spec"]["versions"] if item["name"] == "v2"
            )
            schema = version["schema"]["openAPIV3Schema"]
            close_objects(schema)
            output.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
            return
    raise SystemExit("HelmRelease v2 CRD was not found")


if __name__ == "__main__":
    main()
