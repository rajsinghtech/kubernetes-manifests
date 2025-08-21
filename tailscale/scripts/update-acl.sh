#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"
ACL_FILE="$3"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET_NAME" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

if [ -z "$ACL_FILE" ]; then
    echo "Error: ACL file path is required as third argument" >&2
    exit 1
fi

if [ ! -f "$ACL_FILE" ]; then
    echo "Error: ACL file '$ACL_FILE' does not exist" >&2
    exit 1
fi

if ! jq empty "$ACL_FILE" 2>/dev/null; then
    echo "Error: ACL file '$ACL_FILE' is not valid JSON" >&2
    exit 1
fi

echo "Updating ACL/policy for tailnet: $TAILNET_NAME"

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST https://api.tailscale.com/api/v2/tailnet/"$TAILNET_NAME"/acl \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary @"$ACL_FILE")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Failed to update ACL with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "ACL updated successfully:"
echo "$RESPONSE_BODY" | jq .