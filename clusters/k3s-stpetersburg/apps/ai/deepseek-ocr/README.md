# DeepSeek-OCR Ray Serve Deployment

This directory contains the Kubernetes manifests for deploying DeepSeek-OCR using Ray Serve and vLLM.

## Architecture

- **Ray Serve**: Distributed inference platform with autoscaling
- **vLLM**: High-performance LLM inference engine (~2500 tokens/s on A100)
- **KubeRay**: Kubernetes operator managing Ray clusters
- **OpenAI-compatible API**: Standard `/v1/chat/completions` endpoint

## Components

### RayService (`rayservice.yaml`)
- **Head Node**: Dashboard and orchestration (no GPU)
  - 2-4 CPU, 8-16GB RAM
  - Ray Dashboard on port 8265
  - Serve API on port 8000

- **Worker Nodes**: GPU-powered inference (0-2 replicas, autoscaling)
  - 1 GPU, 4-8 CPU, 24-32GB RAM
  - CUDA 11.8+ support
  - Auto-download model from HuggingFace

### Application Code (`serve_app.py` in ConfigMap)
- FastAPI server with OpenAI-compatible endpoints
- Automatic image decoding from base64
- NGramPerReqLogitsProcessor for controlled generation
- Built-in health checks and model listing

### Configuration
- **serveConfigV2**: Ray Serve application definition
- **Autoscaling**: 0-2 replicas based on request load
- **GPU Sharing**: One GPU per replica, time-sliced if needed

## Endpoints

### Health Check
```bash
curl http://deepseek-ocr-head-svc.ai.svc.cluster.local:8000/health
```

### List Models
```bash
curl http://deepseek-ocr-head-svc.ai.svc.cluster.local:8000/v1/models
```

### OCR Inference
```bash
curl -X POST http://deepseek-ocr-head-svc.ai.svc.cluster.local:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ocr",
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "text",
            "text": "Extract all text from this document"
          },
          {
            "type": "image_url",
            "image_url": {
              "url": "data:image/png;base64,<BASE64_IMAGE>"
            }
          }
        ]
      }
    ],
    "temperature": 0.0,
    "max_tokens": 8192
  }'
```

## Tailscale Access

The service is exposed via Tailscale LoadBalancer at:
```
${LOCATION}-ai-deepseek-ocr (port 80)
```

## Resource Requirements

- **Minimum**: 1 GPU, 4 CPU, 24GB RAM (worker) + 2 CPU, 8GB RAM (head)
- **Storage**: 30GB for model cache
- **Network**: HuggingFace access for model download

## Monitoring

### Ray Dashboard
Access via port-forward:
```bash
kubectl port-forward -n ai svc/deepseek-ocr-head-svc 8265:8265
```
Then visit: http://localhost:8265

### Check RayService Status
```bash
kubectl get rayservice -n ai deepseek-ocr
kubectl describe rayservice -n ai deepseek-ocr
```

### View Logs
```bash
# Head node
kubectl logs -n ai -l ray.io/node-type=head -c ray-head

# Worker nodes
kubectl logs -n ai -l ray.io/node-type=worker -c ray-worker
```

## Scaling

The deployment automatically scales between 0-2 replicas based on request load:
- **Scale up delay**: 30 seconds
- **Scale down delay**: 300 seconds (5 minutes)
- **Target**: 1 ongoing request per replica

## Troubleshooting

### Model Download Issues
- Ensure HF_TOKEN secret is set correctly
- Check HuggingFace model availability
- Verify network connectivity from pods

### GPU Not Found
- Confirm NVIDIA GPU Operator is running
- Check GPU resource quotas
- Verify node has available GPUs

### High Memory Usage
- Model requires ~20-24GB VRAM
- Increase worker memory limits if OOM occurs
- Check `/dev/shm` size (8GB allocated)

## References

- [Ray Serve Documentation](https://docs.ray.io/en/latest/serve/index.html)
- [vLLM Documentation](https://docs.vllm.ai/)
- [DeepSeek-OCR GitHub](https://github.com/deepseek-ai/DeepSeek-OCR)
- [KubeRay Documentation](https://docs.ray.io/en/latest/cluster/kubernetes/index.html)
