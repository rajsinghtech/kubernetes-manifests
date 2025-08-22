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

echo "Deleting tailnet: $TAILNET_NAME" >&2

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X DELETE https://api.tailscale.com/api/v2/tailnet/"$TAILNET_NAME" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Tailnet deletion failed with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "Tailnet deleted successfully" >&2