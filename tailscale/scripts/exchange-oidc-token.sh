#!/bin/bash

set -e

CLIENT_ID="$1"
JWT="$2"

if [ -z "$CLIENT_ID" ]; then
    echo "Error: OAuth client ID is required as first argument" >&2
    exit 1
fi

if [ -z "$JWT" ]; then
    echo "Error: JWT token is required as second argument" >&2
    exit 1
fi

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST https://api.tailscale.com/api/v2/oauth/token-exchange \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=$CLIENT_ID" \
  -d "jwt=$JWT")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Token exchange failed with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

ACCESS_TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: No access token in response" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "$ACCESS_TOKEN"