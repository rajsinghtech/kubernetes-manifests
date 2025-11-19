#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET_NAME" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

if ! echo "$TAILNET_NAME" | grep -E "^[a-zA-Z0-9' -]+$" > /dev/null; then
    echo "Error: Tailnet name can only contain letters, numbers, spaces, apostrophes, and hyphens" >&2
    exit 1
fi

echo "Creating API-only tailnet: $TAILNET_NAME" >&2

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST https://api.tailscale.com/api/v2/organizations/-/tailnets \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"displayName\": \"$TAILNET_NAME\", \"tailnetName\": \"$TAILNET_NAME\"}")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Tailnet creation failed with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "Tailnet created successfully:" >&2
echo "$RESPONSE_BODY" | jq .