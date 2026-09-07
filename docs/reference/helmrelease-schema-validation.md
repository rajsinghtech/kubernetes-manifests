# Offline HelmRelease schema validation

The repository validates rendered `helm.toolkit.fluxcd.io/v2` `HelmRelease`
objects with `tools/check-helmrelease-schema.sh`. It uses Flate's rendered
Kustomization YAML from the location application tree (the `build all` output
is final chart resources and does not contain the HelmRelease CRs), selects the
raw HelmRelease documents, then runs the pinned kubeconform binary against the
checked-in schema. The complete cluster render gate remains responsible for
chart/source reconciliation failures. Schema lookup has no HTTP fallback and
does not contact a cluster.

The schema is the complete `HelmRelease` v2 OpenAPI schema from
`helm-controller` v1.6.4, selected by the Flux v2.9.5 bootstrap pin:

* Flux source: `https://github.com/fluxcd/flux2/releases/tag/v2.9.5`
* Flux bootstrap base: `https://github.com/fluxcd/flux2/tree/v2.9.5/manifests/bases/helm-controller`
* CRD source: `https://github.com/fluxcd/helm-controller/releases/download/v1.6.4/helm-controller.crds.yaml`
* CRD SHA-256: `8af19966e63cccde7d2c62e24c7bd3466010dd53e9d063e2ce22d1391e11f272`
* validator: kubeconform v0.8.0, bootstrapped by `tools/kubeconform.sh`
* kubeconform schema filename: `helmrelease-helm-v2-strict.json` (an explicit
  JSON schema location; no Kubernetes-version directory is inferred)

The checked-in JSON is generated with:

```sh
tools/update-helmrelease-schema.py /path/to/helm-controller.crds.yaml \
  tools/schemas/helm-controller-v1.6.4/helmrelease-helm-v2-strict.json
```

The conversion closes declared object maps for kubeconform strict mode but
preserves `x-kubernetes-preserve-unknown-fields`, including opaque
`spec.values`. `spec.valuesFrom` is validated by the CRD schema. When either
Flux or helm-controller changes, refresh the complete schema, SHA-256, and
this provenance record together. JSON Schema cannot enforce Kubernetes CEL
`x-kubernetes-validations`, defaulting, or admission behavior; this is a
structural prevention slice, not server equivalence. The checker mechanically
verifies the generated artifact hash and local Flux bootstrap pin, rejects
unsupported HelmRelease API versions, and fails when a selected render emits
zero HelmReleases. Never add a remote schema location to the checker.
