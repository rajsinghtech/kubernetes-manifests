# DeepSeek-OCR KServe Deployment

This directory contains KServe manifests for deploying DeepSeek-OCR (3B parameter vision-language OCR model) optimized for **GB10 GPU** compatibility.

## Why Not vLLM?

The **GB10 GPU** has compute capability `sm_121` (Blackwell architecture) which has a **known incompatibility with the Triton compiler**. Since KServe's default HuggingFace runtime uses vLLM (which requires Triton), we created a custom deployment using:

- ✅ **HuggingFace Transformers** (pure PyTorch, no Triton)
- ✅ **FastAPI server** with OpenAI-compatible API
- ✅ **KServe InferenceService** in RawDeployment mode
- ✅ **ARM64 and CUDA 12.4+ compatible** base images

This approach avoids vLLM while maintaining full KServe integration and OpenAI API compatibility.

## Architecture

### Components

- **InferenceService**: KServe custom resource managing the deployment
- **FastAPI Server**: OpenAI-compatible `/v1/chat/completions` endpoint
- **HuggingFace Transformers**: Direct model inference without vLLM
- **Tailscale LoadBalancer**: External access via Tailscale network

### Resource Allocation

- **GPU**: 1x NVIDIA GB10 (128GB unified memory)
- **CPU**: 8-16 cores
- **Memory**: 16-24GB RAM
- **Storage**:
  - 20GB HuggingFace model cache
  - 10GB PyTorch cache
  - 8GB shared memory (/dev/shm)
  - 5GB pip packages

### Scaling

- **Min Replicas**: 1
- **Max Replicas**: 2
- **Autoscaling**: HPA based on concurrency (target: 80%)
- **Concurrency**: 1 concurrent request per replica

## Deployment

### Prerequisites

1. **KServe installed** in your cluster
2. **NVIDIA GPU Operator** running
3. **HuggingFace token** (for private models) in `hf-secret`:
   ```bash
   kubectl create secret generic hf-secret \
     --from-literal=HF_TOKEN=<your-token> \
     -n ai
   ```
4. **Tailscale Operator** for LoadBalancer (optional)

### Deploy

```bash
# From the kserve/deepseek-ocr directory
kubectl apply -k .

# Or using Flux (recommended)
# Update ks.yaml to uncomment the deepseek-ocr kustomization
```

### Verify Deployment

```bash
# Check InferenceService status
kubectl get inferenceservice -n ai deepseek-ocr
kubectl describe inferenceservice -n ai deepseek-ocr

# Check pods
kubectl get pods -n ai -l serving.kserve.io/inferenceservice=deepseek-ocr

# Check logs
kubectl logs -n ai -l serving.kserve.io/inferenceservice=deepseek-ocr -f

# Wait for model to load (takes 5-10 minutes on first run)
```

## Usage

### Endpoints

The service exposes these OpenAI-compatible endpoints:

- `GET /health` - Health check
- `GET /v1/models` - List available models
- `POST /v1/chat/completions` - OCR inference

### Access via Tailscale

```bash
# Service available at (if Tailscale is configured):
curl http://${LOCATION}-ai-kserve-deepseek-ocr/health
```

### Access via kubectl port-forward

```bash
# Port forward to local machine
kubectl port-forward -n ai svc/deepseek-ocr-predictor 8080:80

# Test health
curl http://localhost:8080/health
```

### OCR Inference Example

```bash
# Convert image to base64
BASE64_IMAGE=$(base64 -i /path/to/image.png | tr -d '\n')

# Send OCR request
curl -X POST http://localhost:8080/v1/chat/completions \
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
              "url": "data:image/png;base64,'"${BASE64_IMAGE}"'"
            }
          }
        ]
      }
    ],
    "temperature": 0.0,
    "max_tokens": 8192
  }'
```

### Python Client Example

```python
import base64
import requests
from pathlib import Path

# Read and encode image
image_path = Path("document.png")
image_data = base64.b64encode(image_path.read_bytes()).decode('utf-8')

# Prepare request
url = "http://localhost:8080/v1/chat/completions"
payload = {
    "model": "deepseek-ocr",
    "messages": [
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Convert this image to markdown format"
                },
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/png;base64,{image_data}"
                    }
                }
            ]
        }
    ],
    "temperature": 0.0,
    "max_tokens": 8192
}

# Send request
response = requests.post(url, json=payload)
result = response.json()

# Extract text
ocr_text = result["choices"][0]["message"]["content"]
print(ocr_text)
```

### OpenAI Python Client

```python
from openai import OpenAI

# Initialize client
client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="not-needed"  # API key not required
)

# Read image
with open("document.png", "rb") as f:
    image_data = base64.b64encode(f.read()).decode('utf-8')

# Send request
response = client.chat.completions.create(
    model="deepseek-ocr",
    messages=[
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Extract all text"
                },
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/png;base64,{image_data}"
                    }
                }
            ]
        }
    ],
    temperature=0.0,
    max_tokens=8192
)

print(response.choices[0].message.content)
```

## Monitoring

### Check Model Loading

```bash
# Watch logs during startup (model download takes 5-10 minutes)
kubectl logs -n ai -l serving.kserve.io/inferenceservice=deepseek-ocr -f | grep -E "Loading|loaded|ERROR"
```

### Resource Usage

```bash
# Check GPU utilization
kubectl exec -n ai -it <pod-name> -- nvidia-smi

# Check memory usage
kubectl top pod -n ai -l serving.kserve.io/inferenceservice=deepseek-ocr
```

### Performance Metrics

```bash
# Get metrics from KServe
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/ai/pods/*/inference_request_duration_seconds
```

## Troubleshooting

### Pod Stuck in Init:0/1

**Symptom**: InitContainer installing dependencies takes too long

**Solution**:
```bash
# Check initContainer logs
kubectl logs -n ai <pod-name> -c install-deps

# Increase timeout if needed (edit inferenceservice.yaml)
```

### Model Download Fails

**Symptom**: "Could not connect to HuggingFace Hub"

**Solutions**:
```bash
# Verify HF_TOKEN secret exists
kubectl get secret -n ai hf-secret

# Check network connectivity
kubectl exec -n ai <pod-name> -- curl -I https://huggingface.co

# Verify token has access to model
# (DeepSeek-OCR is public, so token might not be needed)
```

### GPU Not Found

**Symptom**: "CUDA not available" or "No GPU found"

**Solutions**:
```bash
# Check GPU operator
kubectl get pods -n gpu-operator

# Verify GPU resources
kubectl describe node <node-name> | grep nvidia.com/gpu

# Check GPU allocation
kubectl get pods -n ai -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources}{"\n"}{end}'
```

### Out of Memory (OOM)

**Symptom**: Pod gets OOMKilled

**Solutions**:
```bash
# Increase memory limits in inferenceservice.yaml
resources:
  limits:
    memory: 32Gi  # Increase from 24Gi

# Or reduce GPU memory usage
env:
- name: PYTORCH_CUDA_ALLOC_CONF
  value: "max_split_size_mb:256"  # Reduce from 512
```

### Slow Inference

**Symptom**: Requests take too long

**Solutions**:
1. **Enable Flash Attention** (requires recompiling PyTorch for GB10)
2. **Reduce max_tokens** in requests
3. **Use smaller image sizes** (resize images before sending)
4. **Scale up replicas**:
   ```bash
   kubectl patch inferenceservice deepseek-ocr -n ai --type=merge -p '{"spec":{"predictor":{"maxReplicas":3}}}'
   ```

### Triton Compilation Errors

**Symptom**: Errors mentioning "Triton", "NVRTC", or "sm_121a" in logs

**Expected**: This deployment **should not** use Triton. If you see these errors:

1. **Verify you're using this custom deployment** (not the standard HuggingFace runtime)
2. **Check the container image** - should be `pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel`
3. **Verify no vLLM installation** in the initContainer logs

If Triton errors persist, this means vLLM was accidentally installed. Rebuild with dependencies list from `inferenceservice.yaml`.

## GB10 GPU Specific Notes

The GB10 GPU (Grace Blackwell Superchip) has unique requirements:

### Architecture
- **Compute Capability**: `sm_121` (Blackwell)
- **ARM64 CPU**: All containers must be ARM64-compatible
- **CUDA Version**: Requires CUDA 12.8+ (we use 12.4 as baseline)
- **Memory**: 128GB unified memory (shared CPU/GPU)

### Compatibility

✅ **Works**:
- PyTorch 2.6.0+ with native ARM64 builds
- HuggingFace Transformers
- Flash Attention 2 (with recompilation)
- TensorRT (requires CUDA 12.8+)

❌ **Doesn't Work**:
- vLLM (Triton compiler incompatibility with sm_121)
- Pre-compiled x86_64 binaries
- CUDA < 12.4
- Triton-based kernels without recompilation

### Performance Optimization

For maximum performance on GB10:

1. **Use NGC containers**: `nvcr.io/nvidia/pytorch:25.01-py3` (ARM64-native)
2. **Compile PyTorch with sm_121 support**:
   ```bash
   TORCH_CUDA_ARCH_LIST="12.1" pip install torch --no-binary torch
   ```
3. **Enable Flash Attention 2**:
   ```bash
   pip install flash-attn==2.7.3 --no-build-isolation
   ```
4. **Use BF16 precision** (native to model)
5. **Leverage unified memory** for larger batch sizes

## Comparison: KServe vs Ray Serve

Both deployments of DeepSeek-OCR exist in this repo:

| Feature | KServe (this) | Ray Serve |
|---------|---------------|-----------|
| **Location** | `kserve/deepseek-ocr/` | `deepseek-ocr/` |
| **Framework** | KServe InferenceService | RayService |
| **Backend** | Transformers + FastAPI | Transformers + Ray |
| **Autoscaling** | HPA (concurrency-based) | Ray autoscaling |
| **API** | OpenAI-compatible | OpenAI-compatible |
| **Dashboard** | KServe metrics | Ray Dashboard (port 8265) |
| **Cold Start** | ~2-3 minutes | ~3-5 minutes |
| **Complexity** | Medium | Medium |
| **GPU Support** | Native (RawDeployment) | Native (Ray actors) |

**Choose KServe if**: You want standard inference serving with Kubernetes-native autoscaling

**Choose Ray if**: You need distributed serving, Ray ecosystem integration, or built-in dashboard

## Model Information

- **Model**: [deepseek-ai/DeepSeek-OCR](https://huggingface.co/deepseek-ai/DeepSeek-OCR)
- **Size**: 3B parameters (~6GB VRAM in BF16)
- **Architecture**: Vision-Language Model (VLM)
- **Input**: Images + text prompts
- **Output**: Text (markdown, plain text, structured data)
- **Max Tokens**: 8192
- **Precision**: BF16 (native)

## References

- [DeepSeek-OCR GitHub](https://github.com/deepseek-ai/DeepSeek-OCR)
- [DeepSeek-OCR HuggingFace](https://huggingface.co/deepseek-ai/DeepSeek-OCR)
- [KServe Documentation](https://kserve.github.io/website/)
- [NVIDIA GB10 Specifications](https://www.nvidia.com/en-us/data-center/grace-blackwell-superchip/)
- [HuggingFace Transformers](https://huggingface.co/docs/transformers)
