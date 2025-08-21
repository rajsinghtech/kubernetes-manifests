#!/bin/bash

set -e

OAUTH_CLIENT_SECRET="$1"
TAG_NAME="$2"
EPHEMERAL="${3:-false}"
PREAUTHORIZED="${4:-true}"

if [ -z "$OAUTH_CLIENT_SECRET" ]; then
    echo "Error: OAuth client secret is required as first argument" >&2
    exit 1
fi

if [ -z "$TAG_NAME" ]; then
    echo "Error: Tag name is required as second argument (e.g., 'test-tag')" >&2
    exit 1
fi

if [[ ! "$TAG_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Tag name must contain only alphanumeric characters, hyphens, and underscores" >&2
    exit 1
fi

if ! command -v tailscale &> /dev/null; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "Connecting device with tag:$TAG_NAME (ephemeral=$EPHEMERAL, preauthorized=$PREAUTHORIZED)"

AUTH_KEY_PARAMS="ephemeral=$EPHEMERAL&preauthorized=$PREAUTHORIZED"
tailscale up --auth-key="${OAUTH_CLIENT_SECRET}?${AUTH_KEY_PARAMS}" --advertise-tags="tag:$TAG_NAME"

echo "Device connected successfully. Status:"
tailscale status