#!/bin/bash
set -euxo pipefail

# Check if auth_key is provided
if [ -z "${auth_key:-}" ]; then
  echo "Error: auth_key environment variable is not set"
  echo "Usage: auth_key=tskey-xxxx ./tailscale_setup.sh"
  exit 1
fi

# Enable IPv4 and IPv6 forwarding immediately
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# Persist forwarding settings across reboots
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

# Install Tailscale using the official installer
curl -fsSL https://tailscale.com/install.sh | sh

# Enable and start the Tailscale service
systemctl enable --now tailscaled

# Authenticate and enable subnet routing (fixed syntax)
tailscale up --authkey=${auth_key} --advertise-routes=172.41.53.253/32,172.50.0.0/24 --accept-routes

echo "Tailscale subnet router setup complete." 