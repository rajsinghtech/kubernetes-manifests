# GPU Operator Configuration for DGX Spark (GB10)

## Hardware
- **System**: NVIDIA DGX Spark
- **GPU**: GB10 (Blackwell) - 6144 CUDA cores
- **Memory**: 128GB unified memory
- **Architecture**: ARM64 Grace Blackwell

## GPU Sharing Mode: MPS (Multi-Process Service)

### Why MPS?
- ✅ **Configurable memory limits** per pod
- ✅ **Configurable compute allocation** per pod
- ✅ **Parallel execution** (better than time-slicing)
- ✅ **Better isolation** than time-slicing
- ❌ GB10 does not support MIG

### Configuration
- **Replicas**: 10 virtual GPU slices
- **Default memory per replica**: 12.8GB (128GB / 10)
- **Default compute per replica**: 10% GPU threads

## Pod Resource Requests

### Basic Request (Default Limits)
```yaml
spec:
  containers:
  - name: inference
    resources:
      limits:
        nvidia.com/gpu: 1  # Request 1 MPS slice
```

### Custom Memory and Compute Limits
```yaml
spec:
  containers:
  - name: inference
    env:
      # Limit to 20% of GPU compute threads
      - name: CUDA_MPS_ACTIVE_THREAD_PERCENTAGE
        value: "20"

      # Limit to 16GB GPU memory (device 0)
      - name: CUDA_MPS_PINNED_DEVICE_MEM_LIMIT
        value: "0=16G"
    resources:
      limits:
        nvidia.com/gpu: 1
```

### Example Workload Tiers

#### Small Models (e.g., 7B LLMs)
```yaml
env:
  - name: CUDA_MPS_ACTIVE_THREAD_PERCENTAGE
    value: "10"  # 10% compute
  - name: CUDA_MPS_PINNED_DEVICE_MEM_LIMIT
    value: "0=8G"  # 8GB memory
resources:
  limits:
    nvidia.com/gpu: 1
```

#### Medium Models (e.g., 13B-30B LLMs)
```yaml
env:
  - name: CUDA_MPS_ACTIVE_THREAD_PERCENTAGE
    value: "25"  # 25% compute
  - name: CUDA_MPS_PINNED_DEVICE_MEM_LIMIT
    value: "0=32G"  # 32GB memory
resources:
  limits:
    nvidia.com/gpu: 1
```

#### Large Models (e.g., 70B+ LLMs)
```yaml
env:
  - name: CUDA_MPS_ACTIVE_THREAD_PERCENTAGE
    value: "50"  # 50% compute
  - name: CUDA_MPS_PINNED_DEVICE_MEM_LIMIT
    value: "0=64G"  # 64GB memory
resources:
  limits:
    nvidia.com/gpu: 1
```

## Memory Limit Syntax
Format: `<device-id>=<memory-size>`
- Device ID: `0` (single GPU system)
- Memory size: `8G`, `16G`, `32G`, etc.

## Important Notes

1. **No Hard Isolation**: MPS provides resource limits but not hard memory/fault isolation like MIG
2. **Monitor OOM**: Watch for out-of-memory errors if workloads exceed their limits
3. **Total Resources**: Ensure sum of all pod requests doesn't exceed 128GB memory / 100% compute
4. **Experimental**: MPS support in GPU operator is marked as experimental (as of v0.15.0)

## Verification

After deployment, check node capacity:
```bash
kubectl get node spark-9533 -o json | jq '.status.capacity."nvidia.com/gpu"'
# Should show: "10"
```

Check GPU operator logs:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset
# Look for: "MPS is healthy, active thread percentage = 100.0"
```

## Monitoring

MPS provides per-process GPU metrics, but DCGM metrics may not associate correctly to containers. Monitor:
- Pod memory usage
- Model inference latency
- Throughput metrics
- OOM events in pod logs
