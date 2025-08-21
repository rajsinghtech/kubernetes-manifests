#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET="$2"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

echo "Fetching devices for tailnet: $TAILNET"

curl -s https://api.tailscale.com/api/v2/tailnet/"$TAILNET"/devices \
    --header "Authorization: Bearer $ACCESS_TOKEN"