secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.ottawa.local https://k8s.ottawa.local:6443 -f 
	cp ./talosconfig ~/.talos/config
	talosctl machineconfig patch controlplane.yaml --patch @patch/ms01-1.patch --output ms01-1.yaml
	# talosctl machineconfig patch controlplane.yaml --patch @patch/ms01-2.patch --output ms01-2.yaml
	# talosctl machineconfig patch controlplane.yaml --patch @patch/ms01-3.patch --output ms01-3.yaml
	# talosctl machineconfig patch controlplane.yaml --patch @patch/ms01-4.patch --output ms01-4.yaml
init:
	${MAKE} config
	talosctl apply-config --insecure -n ms01-1.local --file ms01-1.yaml 
	# talosctl apply-config --insecure -n ms01-2.local --file ms01-2.yaml
	# talosctl apply-config --insecure -n ms01-3.local --file ms01-3.yaml
	# talosctl apply-config --insecure -n ms01-4.local --file ms01-4.yaml
	sleep 10
	${MAKE} bootstrap

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n ms01-1 -e ms01-1

apply-proxmox:
	talosctl apply-config --insecure -n ms01-1 -e ms01-1 --file ms01-1.yaml

apply:
	${MAKE} config
	talosctl -e ms01-1 -n ms01-1 apply-config --file ms01-1.yaml
	# talosctl -e ms01-2 -n ms01-2 apply-config --file ms01-2.yaml
	# talosctl -e ms01-3 -n ms01-3 apply-config --file ms01-3.yaml
	# talosctl -e ms01-4 -n ms01-4 apply-config --file ms01-4.yaml
iso: 
	@echo "Uploading schematic and retrieving ID..."
	@TALOS_VERSION="v1.10.0"; \
	@SCHEMATIC_ID=$$(curl -s -X POST --data-binary @patch/schematic.yaml https://factory.talos.dev/schematics | jq -r '.id'); \
	echo "Schematic ID: $$SCHEMATIC_ID"; \
	echo "Downloading ISO..."; \
	echo "curl -O https://factory.talos.dev/image/$${SCHEMATIC_ID}/$$TALOS_VERSION/metal-amd64.iso"
	curl -O "https://factory.talos.dev/image/$${SCHEMATIC_ID}/$$TALOS_VERSION/metal-amd64.iso"

kubeconfig:
	cp talosconfig ~/.talos/config.yaml
	talosctl kubeconfig ~/.kube/talosconfig -n ms01-1 -e ms01-1 --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@ms01-1

health:
	talosctl health --talosconfig=./talosconfig -n ms01-1 -e ms01-1

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n ms01-1 -e ms01-1

disk:
	# talosctl get disk --talosconfig=./talosconfig -n ms01-1 -e ms01-1
	# talosctl get discoveredvolumes --talosconfig=./talosconfig -n ms01-1 -e ms01-1
	# talosctl get volumestatus --talosconfig=./talosconfig -n ms01-1 -e ms01-1
	talosctl -e ms01-1 -n ms01-1 get discoveredvolumes
	# talosctl -e ms01-2 -n ms01-2 get discoveredvolumes
	# talosctl -e ms01-3 -n ms01-3 get discoveredvolumes
	# talosctl -e ms01-4 -n ms01-4 get discoveredvolumes

etcd:
	talosctl service etcd --talosconfig=./talosconfig -n ms01-1 -e k8s.ottawa.local

static:
	talosctl get staticpods --talosconfig=./talosconfig -n ms01-1 -e k8s.ottawa.local

link:
	talosctl get linkstatus --talosconfig=./talosconfig -n ms01-1 -e k8s.ottawa.local
	# talosctl get linkstatus --talosconfig=./talosconfig -n ms01-2 -e k8s.ottawa.local
	# talosctl get linkstatus --talosconfig=./talosconfig -n ms01-3 -e k8s.ottawa.local
	# talosctl get linkstatus --talosconfig=./talosconfig -n ms01-4 -e k8s.ottawa.local

addresses:
	talosctl get addresses --talosconfig=./talosconfig -n ms01-1 -e k8s.ottawa.local
	# talosctl get addresses --talosconfig=./talosconfig -n ms01-2 -e k8s.ottawa.local
	# talosctl get addresses --talosconfig=./talosconfig -n ms01-3 -e k8s.ottawa.local
	# talosctl get addresses --talosconfig=./talosconfig -n ms01-4 -e k8s.ottawa.local

reset:
	talosctl -e ms01-1 -n ms01-1 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sda,/dev/sdb,/dev/sdc,/dev/sdd
	# talosctl -e ms01-2 -n ms01-2 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sdb,/dev/sdc,/dev/sdd,/dev/sde
	# talosctl -e ms01-3 -n ms01-3 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sdb,/dev/sdc
	# talosctl -e ms01-4 -n ms01-4 reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot --user-disks-to-wipe /dev/nvme1n1,/dev/sdb,/dev/sdc

reboot:
	talosctl -e ms01-1 -n ms01-1 reboot --debug
	# talosctl -e ms01-2 -n ms01-2 reboot --debug
	# talosctl -e ms01-3 -n ms01-3 reboot --debug
	# talosctl -e ms01-4 -n ms01-4 reboot --debug

service:
	talosctl service --talosconfig=./talosconfig -n ms01-1 -e k8s.ottawa.local
	# talosctl service --talosconfig=./talosconfig -n ms01-2 -e k8s.ottawa.local
	# talosctl service --talosconfig=./talosconfig -n ms01-3 -e k8s.ottawa.local
	# talosctl service --talosconfig=./talosconfig -n ms01-4 -e k8s.ottawa.local

upgrade:
	@TALOS_VERSION="v1.10.0"; \
	talosctl upgrade --nodes ms01-1 --image ghcr.io/siderolabs/installer:$${TALOS_VERSION} -e ms01-1 --wait --debug
	# talosctl upgrade --nodes ms01-2 --image ghcr.io/siderolabs/installer:$${TALOS_VERSION} -e ms01-2 --wait --debug
	# talosctl upgrade --nodes ms01-3 --image ghcr.io/siderolabs/installer:$${TALOS_VERSION} -e ms01-3 --wait --debug
	# talosctl upgrade --nodes ms01-4 --image ghcr.io/siderolabs/installer:$${TALOS_VERSION} -e ms01-4 --wait --debug

standalone:
	talosctl machineconfig patch controlplane.yaml --patch @patch/vault.patch --output vault.yaml
	talosctl apply-config --insecure -n vault.local --file vault.yaml
	talosctl bootstrap --talosconfig=./talosconfig -n vault.local -e vault.local
	talosctl kubeconfig ~/.kube/personal/vault.yaml -n vault.local -e vault.local --talosconfig=./talosconfig -f
