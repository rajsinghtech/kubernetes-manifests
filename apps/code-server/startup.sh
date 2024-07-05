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
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
sudo chmod a+r /etc/bash_completion.d/kubectl
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -o default -F __start_kubectl k' >>~/.bashrc
echo '------'
echo 'Installing Fluxcd'
curl -s https://fluxcd.io/install.sh | FLUX_VERSION=2.0.0 bash
echo '------'
echo 'Installing virtctl'
VERSION=$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}")
ARCH=$(uname -s | tr A-Z a-z)-$(uname -m | sed 's/x86_64/amd64/') || windows-amd64.exe
echo ${ARCH}
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-${ARCH}
chmod +x virtctl
sudo install virtctl /usr/local/bin
echo '------'

apt update
apt install dnsutils iputils-ping -y
# echo 'Installing Tailscale'
# curl -fsSL https://tailscale.com/install.sh | sh

# tailscale up --authkey $TAILSCALE_KEY
