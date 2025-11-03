"""
title: Kubernetes Cluster Query Tool
author: AI Demo
description: Query Kubernetes cluster information directly from chat
version: 1.0.0
"""

import subprocess
import json
from typing import Optional


class Tools:
    def __init__(self):
        self.kubeconfig = "/root/.kube/config"  # Adjust path as needed

    def get_pods(self, namespace: Optional[str] = None) -> str:
        """
        Get list of pods in the cluster or specific namespace.

        :param namespace: Optional namespace to filter pods. If None, shows all namespaces.
        :return: JSON formatted list of pods with status information.
        """
        try:
            cmd = ["kubectl", "get", "pods"]
            if namespace:
                cmd.extend(["-n", namespace])
            else:
                cmd.append("--all-namespaces")
            cmd.extend(["-o", "json"])

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                pods_data = json.loads(result.stdout)
                pod_list = []
                for pod in pods_data.get("items", []):
                    pod_info = {
                        "name": pod["metadata"]["name"],
                        "namespace": pod["metadata"]["namespace"],
                        "status": pod["status"]["phase"],
                        "ready": f"{sum(1 for c in pod['status'].get('containerStatuses', []) if c.get('ready', False))}/{len(pod['status'].get('containerStatuses', []))}",
                        "restarts": sum(c.get("restartCount", 0) for c in pod["status"].get("containerStatuses", [])),
                        "age": pod["metadata"].get("creationTimestamp", "")
                    }
                    pod_list.append(pod_info)
                return json.dumps(pod_list, indent=2)
            else:
                return f"Error: {result.stderr}"
        except Exception as e:
            return f"Error querying pods: {str(e)}"

    def get_nodes(self) -> str:
        """
        Get list of nodes in the cluster with status and resource information.

        :return: JSON formatted list of nodes with capacity and status.
        """
        try:
            result = subprocess.run(
                ["kubectl", "get", "nodes", "-o", "json"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                nodes_data = json.loads(result.stdout)
                node_list = []
                for node in nodes_data.get("items", []):
                    node_info = {
                        "name": node["metadata"]["name"],
                        "status": next((c["type"] for c in node["status"]["conditions"] if c["status"] == "True"), "Unknown"),
                        "roles": node["metadata"].get("labels", {}).get("node-role.kubernetes.io/master", "worker"),
                        "cpu": node["status"]["capacity"].get("cpu", ""),
                        "memory": node["status"]["capacity"].get("memory", ""),
                        "gpu": node["status"]["capacity"].get("nvidia.com/gpu", "0"),
                        "version": node["status"]["nodeInfo"]["kubeletVersion"]
                    }
                    node_list.append(node_info)
                return json.dumps(node_list, indent=2)
            else:
                return f"Error: {result.stderr}"
        except Exception as e:
            return f"Error querying nodes: {str(e)}"

    def get_deployments(self, namespace: Optional[str] = "default") -> str:
        """
        Get list of deployments with replica status.

        :param namespace: Namespace to query. Defaults to 'default'.
        :return: JSON formatted list of deployments with replica information.
        """
        try:
            cmd = ["kubectl", "get", "deployments", "-n", namespace, "-o", "json"]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                deployments_data = json.loads(result.stdout)
                deployment_list = []
                for deploy in deployments_data.get("items", []):
                    deploy_info = {
                        "name": deploy["metadata"]["name"],
                        "namespace": deploy["metadata"]["namespace"],
                        "ready": f"{deploy['status'].get('readyReplicas', 0)}/{deploy['spec']['replicas']}",
                        "available": deploy["status"].get("availableReplicas", 0),
                        "image": deploy["spec"]["template"]["spec"]["containers"][0]["image"] if deploy["spec"]["template"]["spec"].get("containers") else "N/A"
                    }
                    deployment_list.append(deploy_info)
                return json.dumps(deployment_list, indent=2)
            else:
                return f"Error: {result.stderr}"
        except Exception as e:
            return f"Error querying deployments: {str(e)}"

    def get_services(self, namespace: Optional[str] = None) -> str:
        """
        Get list of services with endpoints.

        :param namespace: Optional namespace to filter services. If None, shows all namespaces.
        :return: JSON formatted list of services.
        """
        try:
            cmd = ["kubectl", "get", "services"]
            if namespace:
                cmd.extend(["-n", namespace])
            else:
                cmd.append("--all-namespaces")
            cmd.extend(["-o", "json"])

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                services_data = json.loads(result.stdout)
                service_list = []
                for svc in services_data.get("items", []):
                    svc_info = {
                        "name": svc["metadata"]["name"],
                        "namespace": svc["metadata"]["namespace"],
                        "type": svc["spec"]["type"],
                        "cluster_ip": svc["spec"].get("clusterIP", "None"),
                        "external_ip": svc["spec"].get("externalIPs", ["<none>"])[0] if svc["spec"].get("externalIPs") else "<none>",
                        "ports": [f"{p.get('port', '')}/{p.get('protocol', '')}" for p in svc["spec"].get("ports", [])]
                    }
                    service_list.append(svc_info)
                return json.dumps(service_list, indent=2)
            else:
                return f"Error: {result.stderr}"
        except Exception as e:
            return f"Error querying services: {str(e)}"

    def get_gpu_status(self) -> str:
        """
        Get GPU node capacity and allocation status.

        :return: GPU status information including total capacity and allocated resources.
        """
        try:
            result = subprocess.run(
                ["kubectl", "get", "nodes", "-o", "json"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                nodes_data = json.loads(result.stdout)
                gpu_info = []
                for node in nodes_data.get("items", []):
                    gpu_capacity = node["status"]["capacity"].get("nvidia.com/gpu", "0")
                    if gpu_capacity != "0":
                        gpu_node = {
                            "node": node["metadata"]["name"],
                            "total_gpus": gpu_capacity,
                            "allocatable": node["status"]["allocatable"].get("nvidia.com/gpu", "0"),
                            "gpu_model": node["metadata"].get("labels", {}).get("nvidia.com/gpu.product", "Unknown"),
                            "driver": node["metadata"].get("labels", {}).get("nvidia.com/cuda.driver.major", "Unknown")
                        }
                        gpu_info.append(gpu_node)

                if gpu_info:
                    return json.dumps(gpu_info, indent=2)
                else:
                    return "No GPU nodes found in the cluster."
            else:
                return f"Error: {result.stderr}"
        except Exception as e:
            return f"Error querying GPU status: {str(e)}"

    def describe_pod(self, pod_name: str, namespace: str = "default") -> str:
        """
        Get detailed information about a specific pod.

        :param pod_name: Name of the pod to describe.
        :param namespace: Namespace of the pod. Defaults to 'default'.
        :return: Detailed pod information.
        """
        try:
            result = subprocess.run(
                ["kubectl", "describe", "pod", pod_name, "-n", namespace],
                capture_output=True, text=True, timeout=10
            )
            return result.stdout if result.returncode == 0 else f"Error: {result.stderr}"
        except Exception as e:
            return f"Error describing pod: {str(e)}"
