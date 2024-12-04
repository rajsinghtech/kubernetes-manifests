secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.robbinsdale.local https://k8s.robbinsdale.local:6443
	cp ./talosconfig ~/.talos/config

patch-machineconfig:
	talosctl machineconfig patch controlplane.yaml --patch @patch/base.patch --output controlplane.yaml
	talosctl machineconfig patch worker.yaml --patch @patch/base.patch --output worker.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/proxmox.patch --output proxmox.yaml

apply:
	${MAKE} patch-machineconfig
	talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local

apply-proxmox:
	talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml

update-proxmox:
	${MAKE} patch-machineconfig
	talosctl -e k8s.robbinsdale.local -n 192.168.50.97 apply-config --file proxmox.yaml

kubeconfig:
	talosctl kubeconfig ~/.kube/talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local

