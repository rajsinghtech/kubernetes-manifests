#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"
DEVICE_ID="$3"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET_NAME" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

if [ -z "$DEVICE_ID" ]; then
    echo "Error: Device ID is required as third argument" >&2
    exit 1
fi

echo "Deleting device $DEVICE_ID from tailnet: $TAILNET_NAME"

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X DELETE https://api.tailscale.com/api/v2/device/"$DEVICE_ID" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Failed to delete device with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "Device $DEVICE_ID deleted successfully"