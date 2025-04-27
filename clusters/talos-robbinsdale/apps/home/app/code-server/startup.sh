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
apt update
apt install dnsutils iputils-ping rsync wget iproute2 curl nfs-common -y