secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.robbinsdale.local https://k8s.robbinsdale.local:6443 -f 
	cp ./talosconfig ~/.talos/config
	talosctl machineconfig patch controlplane.yaml --patch @patch/tank.patch --output tank.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/titan.patch --output titan.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/stone.patch --output stone.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/silver.patch --output silver.yaml
init:
	${MAKE} config
	talosctl apply-config --insecure -n tank.local --file tank.yaml 
	talosctl apply-config --insecure -n titan.local --file titan.yaml
	talosctl apply-config --insecure -n stone.local --file stone.yaml
	talosctl apply-config --insecure -n silver.local --file silver.yaml
	sleep 10
	${MAKE} bootstrap

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n tank.local -e tank.local

apply-proxmox:
	talosctl apply-config --insecure -n titan.local --file proxmox.yaml

apply:
	${MAKE} config
	talosctl -e tank.local -n tank.local apply-config --file tank.yaml
	talosctl -e titan.local -n titan.local apply-config --file titan.yaml
	talosctl -e stone.local -n stone.local apply-config --file stone.yaml
	talosctl -e silver.local -n silver.local apply-config --file silver.yaml
iso: 
	@echo "Uploading schematic and retrieving ID..."
	@SCHEMATIC_ID=$$(curl -s -X POST --data-binary @patch/schematic.yaml https://factory.talos.dev/schematics | jq -r '.id'); \
	echo "Schematic ID: $$SCHEMATIC_ID"; \
	echo "Downloading ISO..."; \
	echo "curl -O https://factory.talos.dev/image/$${SCHEMATIC_ID}/v1.10.5/metal-amd64.iso"
	curl -O "https://factory.talos.dev/image/$${SCHEMATIC_ID}/v1.10.5/metal-amd64.iso"

kubeconfig:
	cp talosconfig ~/.talos/config.yaml
	talosctl kubeconfig ~/.kube/talosconfig -n tank.local -e k8s.robbinsdale.local --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n tank.local -e tank.local

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n tank.local -e tank.local
	talosctl dashboard --talosconfig=./talosconfig -n titan.local -e titan.local
	talosctl dashboard --talosconfig=./talosconfig -n stone.local -e stone.local

disk:
	# talosctl get disk --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	# talosctl get discoveredvolumes --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	# talosctl get volumestatus --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	talosctl -e tank.local -n tank.local get discoveredvolumes
	talosctl -e titan.local -n titan.local get discoveredvolumes
	talosctl -e stone.local -n stone.local get discoveredvolumes

etcd:
	talosctl service etcd --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local

static:
	talosctl get staticpods --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local

link:
	talosctl get links --talosconfig=./talosconfig -n tank.local -e k8s.robbinsdale.local
	talosctl get links --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	talosctl get links --talosconfig=./talosconfig -n stone.local -e k8s.robbinsdale.local

addresses:
	talosctl get addresses --talosconfig=./talosconfig -n tank.local -e k8s.robbinsdale.local
	talosctl get addresses --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	talosctl get addresses --talosconfig=./talosconfig -n stone.local -e k8s.robbinsdale.local

reset:
	talosctl -e tank.local -n tank.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sda,/dev/sdb,/dev/sdc,/dev/sdd
	talosctl -e titan.local -n titan.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sdb,/dev/sdc,/dev/sdd,/dev/sde
	talosctl -e stone.local -n stone.local reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sdb,/dev/sdc

reboot:
	talosctl -e tank.local -n tank.local reboot --debug
	talosctl -e titan.local -n titan.local reboot --debug
	talosctl -e stone.local -n stone.local reboot --debug

service:
	talosctl service --talosconfig=./talosconfig -n tank.local -e k8s.robbinsdale.local
	talosctl service --talosconfig=./talosconfig -n titan.local -e k8s.robbinsdale.local
	talosctl service --talosconfig=./talosconfig -n stone.local -e k8s.robbinsdale.local

upgrade:
	talosctl upgrade --nodes tank.local --image ghcr.io/siderolabs/installer:v1.10.5 -e tank.local --wait --debug
	talosctl upgrade --nodes titan.local --image ghcr.io/siderolabs/installer:v1.10.5 -e titan.local --wait --debug
	talosctl upgrade --nodes stone.local --image ghcr.io/siderolabs/installer:v1.10.5 -e stone.local --wait --debug

standalone:
	talosctl machineconfig patch controlplane.yaml --patch @patch/vault.patch --output vault.yaml
	talosctl apply-config --insecure -n vault.local --file vault.yaml
	talosctl bootstrap --talosconfig=./talosconfig -n vault.local -e vault.local
	talosctl kubeconfig ~/.kube/personal/vault.yaml -n vault.local -e vault.local --talosconfig=./talosconfig -f
