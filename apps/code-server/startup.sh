#!/bin/sh
echo "Running prestart script..."
echo ' ______     ______       __        ______     __     __   __     ______     __  __    '
echo '/\  == \   /\  __ \     /\ \      /\  ___\   /\ \   /\ "-.\ \   /\  ___\   /\ \_\ \   '
echo '\ \  __<   \ \  __ \   _\_\ \     \ \___  \  \ \ \  \ \ \-.  \  \ \ \__ \  \ \  __ \  '
echo ' \ \_\ \_\  \ \_\ \_\ /\_____\     \/\_____\  \ \_\  \ \_\\"\_\  \ \_____\  \ \_\ \_\ '
echo '  \/_/ /_/   \/_/\/_/ \/_____/      \/_____/   \/_/   \/_/ \/_/   \/_____/   \/_/\/_/ '
                                                                                     
# Add your startup commands here
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -s https://fluxcd.io/install.sh | sudo FLUX_VERSION=2.0.0 bash
test -d ~/.linuxbrew && eval "$(~/.linuxbrew/bin/brew shellenv)"
test -d /home/linuxbrew/.linuxbrew && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
echo "eval \"\$($(brew --prefix)/bin/brew shellenv)\"" >> ~/.bashrc
brew install k9s