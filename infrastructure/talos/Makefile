secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml --config-patch @patch/base.patch k8s.robbinsdale.local https://k8s.robbinsdale.local:6443 -f
	cp ./talosconfig ~/.talos/config
	talosctl machineconfig patch controlplane.yaml --patch @patch/proxmox.patch --output proxmox.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/tank.patch --output tank.yaml

init:
	${MAKE} config
	# talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml
	# talosctl apply-config --insecure -n 192.168.50.184 --file proxmox.yaml
	# talosctl apply-config --insecure -n 192.168.50.213 --file proxmox.yaml
	# talosctl apply-config --insecure -n 192.168.50.51 --file tank.yaml

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local

apply-proxmox:
	talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml

apply:
	${MAKE} config
	talosctl -e k8s.robbinsdale.local -n 192.168.50.97 apply-config --file proxmox.yaml
	talosctl -e k8s.robbinsdale.local -n 192.168.50.184 apply-config --file proxmox.yaml
	talosctl -e k8s.robbinsdale.local -n 192.168.50.213 apply-config --file proxmox.yaml	
	talosctl -e k8s.robbinsdale.local -n 192.168.50.51 apply-config --file tank.yaml

kubeconfig:
	talosctl kubeconfig ~/.kube/talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local --talosconfig=./talosconfig -f

k9s:
	k9s --kubeconfig ~/.kube/talosconfig --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n 192.168.50.97 -e k8s.robbinsdale.local

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n 192.168.50.51 -e k8s.robbinsdale.local

disk:
	talosctl get disk --talosconfig=./talosconfig -n 192.168.50.51 -e k8s.robbinsdale.local
