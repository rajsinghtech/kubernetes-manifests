#!/bin/bash

# Check if TESLA_AUTH_TOKEN is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 TESLA_AUTH_TOKEN"
    exit 1
fi

TESLA_AUTH_TOKEN="$1"

# Read and process the CA_CERT
CA_CERT=$(awk '{printf "%s\\n", $0}' /secret/ca/tls.crt)

# Substitute the CA_CERT into the JSON template using jq
JSON_DATA=$(jq --arg ca_cert "$CA_CERT" '.ca_cert = $ca_cert' /api/fleet_telemetry_config.json)

# Execute the curl command with the correct certificate path
curl -H "Authorization: Bearer $TESLA_AUTH_TOKEN" \
     -H 'Content-Type: application/json' \
     --data "$JSON_DATA" \
     -X POST -i https://localhost:4443/api/1/vehicles/fleet_telemetry_config \
     --cacert config/tls-cert.pem