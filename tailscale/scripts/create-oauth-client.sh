#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"
TAG_NAME="$3"
DESCRIPTION="$4"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET_NAME" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

if [ -z "$TAG_NAME" ]; then
    echo "Error: Tag name is required as third argument (e.g., 'test-tag')" >&2
    exit 1
fi

DESCRIPTION="${DESCRIPTION:-device authentication}"

if [[ ! "$TAG_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Tag name must contain only alphanumeric characters, hyphens, and underscores" >&2
    exit 1
fi

echo "Creating OAuth client for tag:$TAG_NAME in tailnet: $TAILNET_NAME" >&2

CLIENT_JSON=$(cat <<EOF
{
  "keyType": "client",
  "description": "$DESCRIPTION",
  "scopes": ["auth_keys"],
  "tags": ["tag:$TAG_NAME"]
}
EOF
)

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST https://api.tailscale.com/api/v2/tailnet/"$TAILNET_NAME"/keys \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$CLIENT_JSON")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Failed to create OAuth client with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "OAuth client created successfully:" >&2
echo "$RESPONSE_BODY" | jq .