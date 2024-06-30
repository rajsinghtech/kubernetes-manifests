#!/bin/sh
echo "Running prestart script..."
echo ' ______     ______       __        ______     __     __   __     ______     __  __    '
echo '/\  == \   /\  __ \     /\ \      /\  ___\   /\ \   /\ "-.\ \   /\  ___\   /\ \_\ \   '
echo '\ \  __<   \ \  __ \   _\_\ \     \ \___  \  \ \ \  \ \ \-.  \  \ \ \__ \  \ \  __ \  '
echo ' \ \_\ \_\  \ \_\ \_\ /\_____\     \/\_____\  \ \_\  \ \_\\"\_\  \ \_____\  \ \_\ \_\ '
echo '  \/_/ /_/   \/_/\/_/ \/_____/      \/_____/   \/_/   \/_/ \/_/   \/_____/   \/_/\/_/ '
                                                                                     
# Add your startup commands here
echo '------'
echo 'Installing Kubectl'
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
echo '------'
echo 'Installing Fluxcd'
curl -s https://fluxcd.io/install.sh | FLUX_VERSION=2.0.0 bash
echo '------'
apt update
apt install dnsutils iputils-ping -y
# echo 'Installing Tailscale'
# curl -fsSL https://tailscale.com/install.sh | sh

# tailscale up --authkey $TAILSCALE_KEY
