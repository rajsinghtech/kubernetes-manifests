# GPU Operator Configuration for DGX Spark (GB10)

## Hardware
- **System**: NVIDIA DGX Spark
- **GPU**: GB10 (Blackwell) - 6144 CUDA cores
- **Memory**: 128GB unified memory
- **Architecture**: ARM64 Grace Blackwell

## GPU Sharing Mode: Time-Slicing

### Why Time-Slicing?
- ✅ **Proven and stable** in GPU operator
- ✅ **Works on GB10** without issues
- ✅ **Simple configuration**
- ❌ No memory/compute limits per pod
- ❌ GB10 does not support MIG
- ❌ MPS is broken (socket issues)

### Configuration
- **Replicas**: 8 virtual GPU slices
- **failRequestsGreaterThanOne**: false (allows pods to request multiple slices)
- **renameByDefault**: false (keeps resource name as nvidia.com/gpu)

## Pod Resource Requests

### Single GPU Slice (1/8th of GPU)
```yaml
spec:
  containers:
  - name: inference
    resources:
      limits:
        nvidia.com/gpu: 1
```

### Multiple GPU Slices (More GPU Time)
```yaml
spec:
  containers:
  - name: inference
    resources:
      limits:
        nvidia.com/gpu: 2  # 2/8ths of GPU time
```

**Note**: Requesting multiple slices gives more GPU time-slices, but does NOT provide:
- Guaranteed proportional performance (2 slices ≠ 2x performance)
- Memory isolation (all workloads share 128GB)
- Dedicated compute resources

### Example Workload Sizing

#### Small Inference Workloads
- Request: `nvidia.com/gpu: 1`
- Use case: Small models, low throughput APIs

#### Medium Inference Workloads
- Request: `nvidia.com/gpu: 2`
- Use case: Medium models, moderate throughput

#### Large Inference Workloads
- Request: `nvidia.com/gpu: 3-4`
- Use case: Large models, high throughput

## Important Notes

1. **No Resource Isolation**: Time-slicing provides NO memory or compute isolation
2. **Shared Memory**: All workloads share the full 128GB - watch for OOM errors
3. **Equal Time Slices**: Each replica gets equal GPU time regardless of request count
4. **Monitor Total Usage**: Ensure total pod requests don't exceed 8 available slices
5. **No Guaranteed Performance**: Multiple slices ≠ guaranteed proportional performance

## Verification

After deployment, check node capacity:
```bash
kubectl get node spark-9533 -o json | jq '.status.capacity."nvidia.com/gpu"'
# Should show: "8"
```

Check time-slicing is active:
```bash
kubectl get node spark-9533 -o json | jq '.metadata.labels | with_entries(select(.key | contains("nvidia.com/gpu")))'
# Look for: nvidia.com/gpu.replicas: "8"
```

## Monitoring

Watch for:
- Out-of-memory errors (no memory limits)
- Inference latency increase (context switching overhead)
- GPU utilization via DCGM exporter
- Pod GPU resource requests vs limits
