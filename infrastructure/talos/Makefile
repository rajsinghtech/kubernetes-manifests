secret:
	talosctl gen secrets -o secrets.yaml

config:
	talosctl gen config --with-secrets secrets.yaml robbinsdale https://192.168.50.25:6443 --dns-domain k8s.robbinsdale.local --additional-sans k8s.robbinsdale.rajsingh.info k8s.robbinsdale.lukehouge.com
	cp ./talosconfig ~/.talos/config

patch-machineconfig:
	talosctl machineconfig patch controlplane.yaml --patch @patch/base.patch --output controlplane.yaml
	talosctl machineconfig patch worker.yaml --patch @patch/base.patch --output worker.yaml
	talosctl machineconfig patch controlplane.yaml --patch @patch/proxmox.patch --output proxmox.yaml

apply:
	${MAKE} patch-machineconfig
	talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml

bootstrap:
	talosctl bootstrap --talosconfig=./talosconfig -n 192.168.50.97 -e 192.168.50.97

apply-proxmox:
	talosctl apply-config --insecure -n 192.168.50.97 --file proxmox.yaml

update-proxmox:
	${MAKE} patch-machineconfig
	talosctl -e 192.168.50.97 -n 192.168.50.97 apply-config --file proxmox.yaml
	
talosconfig:
	talosctl --talosconfig=./talosconfig -n 192.168.50.97 -e 192.168.50.97 version


kubeconfig:
	talosctl kubeconfig ~/.kube/talosconfig -n 192.168.50.97 -e 192.168.50.97 --talosconfig=./talosconfig

k9s:
	k9s --context admin@robbinsdale

health:
	talosctl health --talosconfig=./talosconfig -n 192.168.50.97 -e 192.168.50.97

dashboard:
	talosctl dashboard --talosconfig=./talosconfig -n 192.168.50.97 -e 192.168.50.97

