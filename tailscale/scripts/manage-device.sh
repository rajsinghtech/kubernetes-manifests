#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"
DEVICE_ID="$3"
ACTION="$4"

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

if [ -z "$ACTION" ]; then
    echo "Error: Action is required as fourth argument (authorize|expire|extend)" >&2
    exit 1
fi

case "$ACTION" in
    "authorize")
        DATA='{"authorized": true}'
        echo "Authorizing device $DEVICE_ID in tailnet: $TAILNET_NAME"
        ;;
    "expire")
        DATA='{"keyExpiryDisabled": false}'
        echo "Enabling key expiry for device $DEVICE_ID in tailnet: $TAILNET_NAME"
        ;;
    "extend")
        DATA='{"keyExpiryDisabled": true}'
        echo "Disabling key expiry for device $DEVICE_ID in tailnet: $TAILNET_NAME"
        ;;
    *)
        echo "Error: Invalid action '$ACTION'. Must be one of: authorize, expire, extend" >&2
        exit 1
        ;;
esac

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST https://api.tailscale.com/api/v2/device/"$DEVICE_ID" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$DATA")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Failed to $ACTION device with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

echo "Device $DEVICE_ID $ACTION action completed successfully" >&2
echo "$RESPONSE_BODY" | jq .