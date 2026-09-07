#!/usr/bin/env bash
# Read-only: print UniFi RIB rows for a destination (default public Envoy VIP).
# Auth: kubectl read of home/external-dns-unifi-secret api-key.
# Usage: ./scripts/unifi-rib-snapshot.sh [destination/prefix]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-10.169.10.15/32}"
KEY="$("$ROOT/tools/kc.sh" ot -n home get secret external-dns-unifi-secret -o jsonpath='{.data.api-key}' | base64 -d)"
curl -k -sS -H "X-API-KEY: $KEY" -H 'Accept: application/json' \
  'https://192.168.169.1/proxy/network/v2/api/site/default/routes' \
  | DEST="$DEST" python3 -c '
import json,os,sys
dest=os.environ["DEST"]
items=json.load(sys.stdin).get("items",[])
hits=[r for r in items if r.get("destination")==dest]
json.dump(hits, sys.stdout, indent=2)
print()
if not hits:
  sys.exit(1)
'
