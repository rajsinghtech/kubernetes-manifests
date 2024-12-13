secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.robbinsdale.local https://k8s.robbinsdale.local:6443 -f 
	cp ./talosconfig ~/.talos/config
	talosctl machineconfig patch controlplane.yaml --patch @patch/vault.patch --output vault.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/tank.patch --output tank.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/titan.patch --output titan.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/stone.patch --output stone.yaml

init:
	${MAKE} config
	talosctl apply-config --insecure -n vault-proxmox.local --file vault.yaml
	talosctl apply-config --insecure -n tank.local --file tank.yaml 
	talosctl apply-config --insecure -n titan.local --file titan.yaml
	talosctl apply-config --insecure -n stone-proxmox.local --file stone.yaml

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n tank.local -e tank.local

apply-proxmox:
	talosctl apply-config --insecure -n titan.local --file proxmox.yaml

apply:
	${MAKE} config
	talosctl -e vault-proxmox.local -n vault-proxmox.local apply-config --file vault.yaml
	talosctl -e tank.local -n tank.local apply-config --file tank.yaml
	talosctl -e titan.local -n titan.local apply-config --file titan.yaml
	talosctl -e stone-proxmox.local -n stone-proxmox.local apply-config --file stone.yaml
	
iso: 
	@echo "Uploading schematic and retrieving ID..."
	@SCHEMATIC_ID=$$(curl -s -X POST --data-binary @patch/schematic.yaml https://factory.talos.dev/schematics | jq -r '.id'); \
	echo "Schematic ID: $$SCHEMATIC_ID"; \
	echo "Downloading ISO..."; \
	curl -O https://factory.talos.dev/image/32553c72324961acdc4b6a531a1143e84dc5d3bd5225589150f5d273142c5908/v1.8.3/metal-amd64.iso

kubeconfig:
	talosctl kubeconfig ~/.kube/talosconfig -n tank.local -e k8s.robbinsdale.local --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n tank.local -e tank.local

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n tank.local -e tank.local

disk:
	# talosctl get disk --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	# talosctl get discoveredvolumes --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	# talosctl get volumestatus --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	talosctl -e vault-proxmox.local -n vault-proxmox.local get discoveredvolumes
	talosctl -e tank.local -n tank.local get discoveredvolumes
	talosctl -e titan.local -n titan.local get discoveredvolumes
	talosctl -e stone-proxmox.local -n stone-proxmox.local get discoveredvolumes

etcd:
	talosctl service etcd --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local

static:
	talosctl get staticpods --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local

link:
	talosctl get links --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local

reset:
	talosctl -e vault-proxmox.local -n vault-proxmox.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/sdb
	talosctl -e tank.local -n tank.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sda,/dev/sdb,/dev/sdc,/dev/sdd
	talosctl -e titan.local -n titan.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme0n1,/dev/sda,/dev/sdb,/dev/sdc,/dev/sdd
	talosctl -e stone-proxmox.local -n stone-proxmox.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/sdc,/dev/sdd

reboot:
	talosctl -e vault-proxmox.local -n vault-proxmox.local reboot
	talosctl -e stone-proxmox.local -n stone-proxmox.local reboot
	talosctl -e tank.local -n tank.local reboot
	talosctl -e titan.local -n titan.local reboot