#!/bin/bash

set -e

ACCESS_TOKEN="$1"
TAILNET_NAME="$2"
FORMAT="${3:-json}"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Access token is required as first argument" >&2
    exit 1
fi

if [ -z "$TAILNET_NAME" ]; then
    echo "Error: Tailnet name is required as second argument" >&2
    exit 1
fi

if [[ "$FORMAT" != "json" && "$FORMAT" != "table" ]]; then
    echo "Error: Format must be 'json' or 'table'" >&2
    exit 1
fi

echo "Listing devices for tailnet: $TAILNET_NAME" >&2

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" https://api.tailscale.com/api/v2/tailnet/"$TAILNET_NAME"/devices \
  --header "Authorization: Bearer $ACCESS_TOKEN")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Failed to list devices with status $HTTP_STATUS" >&2
    echo "Response: $RESPONSE_BODY" >&2
    exit 1
fi

if [ "$FORMAT" == "json" ]; then
    echo "$RESPONSE_BODY" | jq .
elif [ "$FORMAT" == "table" ]; then
    echo "$RESPONSE_BODY" | jq -r '.devices[] | [.name, .addresses[0], .os, .tags // [], (.online // false)] | @tsv' | column -t -s $'\t' -N "NAME,IP,OS,TAGS,ONLINE"
fi