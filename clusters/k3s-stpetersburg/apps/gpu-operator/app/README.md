# GPU Operator Configuration for DGX Spark (GB10)

## Hardware
- **System**: NVIDIA DGX Spark
- **GPU**: GB10 (Blackwell) - 6144 CUDA cores
- **Memory**: 128GB unified memory
- **Architecture**: ARM64 Grace Blackwell

## GPU Mode: Exclusive Access (No Sharing)

### Why Exclusive Access?
- ✅ **Best performance** - no context switching overhead
- ✅ **Full GPU resources** - entire 128GB VRAM available
- ✅ **Lowest latency** - no time-slicing delays
- ❌ GB10 does not support MIG
- ❌ MPS is broken (socket issues)
- ❌ Time-slicing has poor inference latency

### Configuration
- **Mode**: Exclusive GPU access (default device plugin behavior)
- **VRAM**: Full 128GB unified memory per pod
- **Allocation**: nvidia.com/gpu: 1 = entire GPU

## Pod Resource Requests

### Exclusive GPU Access
```yaml
spec:
  containers:
  - name: inference
    resources:
      limits:
        nvidia.com/gpu: 1  # Full GPU with 128GB VRAM
      requests:
        nvidia.com/gpu: 1
```

### Example Workloads

#### Large Language Models
- Request: `nvidia.com/gpu: 1`
- VRAM: Full 128GB available
- Use case: 33B+ parameter models, high throughput inference
- Example: DeepSeek-Coder 33B (~66GB FP16 or ~16GB 4-bit)

#### Multiple Small Models
- Request: `nvidia.com/gpu: 1` per pod
- Limit: Only 1 pod can use GPU at a time on this single-GPU node
- For multiple concurrent workloads, consider deploying across multiple GB10 nodes

## Important Notes

1. **Exclusive Access**: Each pod requesting `nvidia.com/gpu: 1` gets the entire GPU
2. **Full Memory**: Pods have access to the full 128GB unified memory
3. **Single Node Limitation**: spark-9533 has 1 GPU - only 1 pod can run at a time
4. **Best Performance**: No sharing overhead = maximum inference speed
5. **For Multiple Workloads**: Deploy additional GB10 nodes or use smaller quantized models

## Verification

After deployment, check node capacity:
```bash
kubectl get node spark-9533 -o json | jq '.status.capacity."nvidia.com/gpu"'
# Should show: "1"
```

Check GPU is detected:
```bash
kubectl get node spark-9533 -o json | jq '.metadata.labels | with_entries(select(.key | contains("nvidia.com/gpu")))'
# Look for: nvidia.com/gpu.present: "true"
```

## Monitoring

### DCGM Exporter Metrics

GPU metrics are exported by NVIDIA DCGM Exporter on port 9400:
- Service: `nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400`
- ServiceMonitor: Configured for Prometheus scraping every 30s
- Endpoint: `http://nvidia-dcgm-exporter:9400/metrics`

### Key Metrics to Monitor

**GPU Utilization**
- `DCGM_FI_DEV_GPU_UTIL` - GPU utilization percentage
- `DCGM_FI_DEV_MEM_COPY_UTIL` - Memory controller utilization

**Memory Usage**
- `DCGM_FI_DEV_FB_USED` - Framebuffer memory used (bytes)
- `DCGM_FI_DEV_FB_FREE` - Framebuffer memory free (bytes)
- Watch for OOM errors - no memory limits with time-slicing!

**Temperature & Power**
- `DCGM_FI_DEV_GPU_TEMP` - GPU temperature (Celsius)
- `DCGM_FI_DEV_POWER_USAGE` - Power usage (watts)

**Performance**
- `DCGM_FI_DEV_SM_CLOCK` - Streaming multiprocessor clock (MHz)
- `DCGM_FI_DEV_MEM_CLOCK` - Memory clock (MHz)
- Monitor inference latency increase (context switching overhead)

### Grafana Dashboard

Import NVIDIA DCGM Exporter dashboard:
- Dashboard ID: 12239
- Or use: https://grafana.com/grafana/dashboards/12239

### Alert Recommendations

Watch for:
- GPU temperature > 85°C
- Memory usage > 90% (128GB total)
- GPU utilization consistently at 100% (may need more slices)
- Pod GPU resource requests exceeding 4 available slices
