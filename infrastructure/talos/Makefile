secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.robbinsdale.local https://k8s.robbinsdale.local:6443 -f
	cp ./talosconfig ~/.talos/config
	talosctl machineconfig patch controlplane.yaml --patch @patch/talos2.patch --output talos2.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/talos3.patch --output talos3.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/tank.patch --output tank.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/stone.patch --output stone.yaml

init:
	${MAKE} config
	talosctl apply-config --insecure -n 192.168.50.184 --file talos2.yaml --mode=try
	talosctl apply-config --insecure -n 192.168.50.213 --file talos3.yaml --mode=try
	talosctl apply-config --insecure -n 192.168.50.51 --file tank.yaml --mode=try
	# talosctl apply-config --insecure -n 192.168.50.82 --file stone.yaml --mode=try

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n 192.168.50.184 -e 192.168.50.184

apply-proxmox:
	talosctl apply-config --insecure -n 192.168.50.82 --file proxmox.yaml

apply:
	${MAKE} config
	talosctl -e 192.168.50.184 -n 192.168.50.184 apply-config --file talos2.yaml --mode=try
	talosctl -e 192.168.50.213 -n 192.168.50.213 apply-config --file talos3.yaml --mode=try
	talosctl -e 192.168.50.51 -n 192.168.50.51 apply-config --file tank.yaml --mode=try
	# talosctl -e 192.168.50.82 -n 192.168.50.82 apply-config --file stone.yaml --mode=try
	
iso: 
	@echo "Uploading schematic and retrieving ID..."
	@SCHEMATIC_ID=$$(curl -s -X POST --data-binary @patch/schematic.yaml https://factory.talos.dev/schematics | jq -r '.id'); \
	echo "Schematic ID: $$SCHEMATIC_ID"; \
	echo "Downloading ISO..."; \
	curl -O https://factory.talos.dev/image/$$SCHEMATIC_ID/v1.8.3/metal-amd64.iso

kubeconfig:
	talosctl kubeconfig ~/.kube/talosconfig -n 192.168.50.51 -e k8s.robbinsdale.local --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n 192.168.50.51 -e 192.168.50.51

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n 192.168.50.184 -e k8s.robbinsdale.local

disk:
	talosctl get disk --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local
	talosctl get discoveredvolumes --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local
	talosctl get volumestatus --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local

etcd:
	talosctl service etcd --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local

static:
	talosctl get staticpods --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local

link:
	talosctl get links --talosconfig=./talosconfig -n 192.168.50.82 -e k8s.robbinsdale.local

reset:
	talosctl -e 192.168.50.213 -n 192.168.50.213 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot
	talosctl -e 192.168.50.184 -n 192.168.50.184 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot 
	talosctl -e  192.168.50.51 -n 192.168.50.51 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot
	# talosctl -e 192.168.50.82 -n 192.168.50.82 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot