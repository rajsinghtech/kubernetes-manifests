#!/bin/sh
echo "Running prestart script..."
# Add your startup commands here
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -s https://fluxcd.io/install.sh | sudo FLUX_VERSION=2.0.0 bash
