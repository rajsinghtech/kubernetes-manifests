#!/usr/bin/env bash
# Run the exact kubeconform release used by the repository schema gate.
# Like tools/flate.sh, the verified binary is cached per platform and is
# bootstrapped only when absent; schemas are never fetched by this wrapper.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.8.0"

version_of() {
  "$1" -v 2>/dev/null | sed -n 's/^v//p' | head -1
}

if [ -n "${KMAN_KUBECONFORM_BIN:-}" ]; then
  actual="$(version_of "$KMAN_KUBECONFORM_BIN" || true)"
  [ "$actual" = "$VERSION" ] || {
    echo "error: KMAN_KUBECONFORM_BIN is kubeconform ${actual:-unknown}; expected $VERSION" >&2
    exit 2
  }
  exec "$KMAN_KUBECONFORM_BIN" "$@"
fi

if command -v kubeconform >/dev/null 2>&1; then
  system="$(command -v kubeconform)"
  if [ "$(version_of "$system" || true)" = "$VERSION" ]; then
    exec "$system" "$@"
  fi
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os/$arch" in
  darwin/x86_64) asset="kubeconform-darwin-amd64.tar.gz" ;;
  darwin/arm64) asset="kubeconform-darwin-arm64.tar.gz" ;;
  linux/x86_64) asset="kubeconform-linux-amd64.tar.gz" ;;
  linux/aarch64|linux/arm64) asset="kubeconform-linux-arm64.tar.gz" ;;
  *) echo "error: no bootstrapped kubeconform binary for $os/$arch" >&2; exit 2 ;;
esac

if [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache_root="$XDG_CACHE_HOME"
elif [ "$os" = darwin ]; then
  cache_root="${HOME:?HOME is required}/Library/Caches"
else
  cache_root="${HOME:?HOME is required}/.cache"
fi

install_dir="$cache_root/kubernetes-manifests/kubeconform/$VERSION/$os-$arch"
cached="$install_dir/kubeconform"
if [ -x "$cached" ] && [ "$(version_of "$cached" || true)" = "$VERSION" ]; then
  exec "$cached" "$@"
fi

mkdir -p "$install_dir"
stage="$(mktemp -d "$install_dir/.install.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT INT TERM
base="https://github.com/yannh/kubeconform/releases/download/v${VERSION}"
curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
  --connect-timeout 10 --max-time 120 "$base/$asset" -o "$stage/$asset"
curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
  --connect-timeout 10 --max-time 120 "$base/CHECKSUMS" -o "$stage/CHECKSUMS"
expected="$(awk -v file="$asset" '$2 == file {print $1}' "$stage/CHECKSUMS")"
[ "${#expected}" = 64 ] || { echo "error: missing checksum for $asset" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$stage/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$stage/$asset" | awk '{print $1}')"
fi
[ "$actual" = "$expected" ] || { echo "error: checksum mismatch for $asset" >&2; exit 1; }
tar -xzf "$stage/$asset" -C "$stage" kubeconform
chmod 0755 "$stage/kubeconform"
[ "$(version_of "$stage/kubeconform")" = "$VERSION" ] || {
  echo "error: downloaded kubeconform has unexpected version" >&2; exit 1;
}
mv -f -- "$stage/kubeconform" "$cached"
exec "$cached" "$@"
