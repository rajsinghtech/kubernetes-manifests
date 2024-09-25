#!/bin/bash

# Check if TESLA_AUTH_TOKEN is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 TESLA_AUTH_TOKEN"
    exit 1
fi

TESLA_AUTH_TOKEN="$1"

# Use jq to read the certificate file into the JSON
JSON_DATA=$(jq --rawfile ca_cert /secret/ca/tls.crt '.config.ca = $ca_cert' /api/fleet_telemetry_config.json)

# Output JSON_DATA for debugging
echo "JSON_DATA:"
echo "$JSON_DATA"

# Execute the curl command with the correct certificate path
curl -H "Authorization: Bearer $TESLA_AUTH_TOKEN" \
     -H 'Content-Type: application/json' \
     --data "$JSON_DATA" \
     -X POST -i https://localhost:4443/api/1/vehicles/fleet_telemetry_config \
     --cacert /config/tls-cert.pem