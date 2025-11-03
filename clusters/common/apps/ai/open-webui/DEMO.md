# Open-WebUI Advanced Demo

## Overview

This Open-WebUI deployment showcases advanced AI capabilities running on NVIDIA DGX Spark (GB10 Blackwell) with exclusive GPU access.

**Demo URL**: https://chat.rajsingh.info/

## 🚀 Features Enabled

### 1. **RAG (Retrieval Augmented Generation)**
Upload and query documents directly in chat:
- **Document Upload**: Use the `#` command to reference documents
- **Web Loader**: Start prompts with `#` followed by a URL to incorporate web content
- **Embedding Model**: nomic-embed-text (274 MB, optimized for semantic search)
- **Use Cases**:
  - Upload Kubernetes YAML files and ask "What GPU operator version am I running?"
  - Upload technical documentation for context-aware responses
  - Create knowledge bases paired with specific models

**How to use**:
1. Go to Workspace → Documents
2. Upload PDFs, Word docs, Excel, PowerPoint, or text files
3. In chat, type `#` to reference uploaded documents
4. Ask questions about the document content

### 2. **Web Search Integration**
Real-time web search capabilities with DuckDuckGo:
- **Privacy-focused**: DuckDuckGo doesn't track searches
- **Real-time information**: Get current news, stock prices, weather
- **RAG Integration**: Search results fed directly into LLM context
- **No API key required**: Zero configuration web search

**How to use**:
```
User: Search for latest GPU operator releases
Model: [Automatically searches DuckDuckGo and uses results]
```

### 3. **Vision Model (Multimodal Chat)**
Image understanding with LLaVA 13B:
- **Model**: llava:13b (7.4 GB)
- **Capabilities**:
  - Describe images in detail
  - Answer questions about image content
  - OCR text extraction
  - Architecture diagram analysis
  - UI/UX mockup discussion

**How to use**:
1. Select `llava:13b` from the model dropdown
2. Upload an image in the chat
3. Ask questions about the image:
   - "What's in this image?"
   - "Read the text from this screenshot"
   - "Explain this architecture diagram"

### 4. **Multiple Models**
Switch between specialized models for different tasks:

#### **deepseek-coder:33b** (18 GB, Q4_0 quantization)
- **Best for**: Code generation, debugging, technical explanations
- **Context**: 16384 tokens (4096 configured)
- **VRAM**: 19.6 GiB (model + KV cache)
- **Speed**: ~12 tokens/sec generation

#### **deepseek-coder-fixed:33b** (18 GB)
- Fixed chat template for Open-WebUI compatibility
- Use this if regular deepseek-coder has issues

#### **llama3.2:1b** (1.3 GB)
- **Best for**: Quick responses, simple tasks, testing
- **Speed**: Fast inference (<1s response time)
- **Context**: 4096 tokens

#### **llava:13b** (8.0 GB)
- **Best for**: Image understanding, visual question answering
- **Supports**: JPG, PNG, GIF, WebP images

### 5. **Custom Kubernetes Tool** 🛠️
Query your cluster directly from chat (requires admin setup):

**Available functions**:
- `get_pods(namespace)` - List pods with status
- `get_nodes()` - Show node information with GPU count
- `get_deployments(namespace)` - View deployment status
- `get_services(namespace)` - List services and endpoints
- `get_gpu_status()` - GPU allocation across nodes
- `describe_pod(name, namespace)` - Detailed pod information

**Example queries** (once tool is installed):
```
"Show me all pods in the ai namespace"
"What's the GPU status on my nodes?"
"Describe the open-webui-ollama pod"
```

**Installation**:
1. Go to Workspace → Tools
2. Click "+" to add new tool
3. Copy content from `kubernetes-tool.py`
4. Save and enable the tool

## 📊 Hardware Configuration

- **GPU**: NVIDIA GB10 (Blackwell)
  - 128 GB unified memory
  - 6144 CUDA cores
  - Exclusive access mode (no time-slicing)
- **Platform**: ARM64 Grace Blackwell
- **Cluster**: Kubernetes with Flux GitOps
- **Storage**: 100 Gi persistent volume (Longhorn)

## 🎯 Demo Scenarios

### Scenario 1: Code Review with Context
```bash
1. Upload your codebase as a ZIP
2. Select deepseek-coder:33b
3. Ask: "Review this code for security vulnerabilities"
4. Get detailed analysis with suggestions
```

### Scenario 2: Document Q&A
```bash
1. Upload technical PDF (Kubernetes docs, RFC, etc.)
2. Use # to reference the document
3. Ask: "Summarize the key changes in this version"
4. Get accurate answers based on document content
```

### Scenario 3: Web-Enhanced Research
```bash
1. Ask: "What are the latest trends in GPU virtualization?"
2. Model searches DuckDuckGo automatically
3. Get current information with sources
4. Follow up with specific questions
```

### Scenario 4: Vision + Code
```bash
1. Upload screenshot of UI mockup
2. Select llava:13b
3. Ask: "Generate React components for this design"
4. Switch to deepseek-coder:33b
5. Refine the generated code
```

### Scenario 5: Cluster Management
```bash
1. Enable Kubernetes tool
2. Ask: "Show GPU utilization"
3. Ask: "Which pods are using GPUs?"
4. Get real-time cluster information
```

## 🔧 Advanced Configuration

### Environment Variables
```yaml
ENABLE_RAG_WEB_SEARCH: "true"
RAG_WEB_SEARCH_ENGINE: "duckduckgo"
RAG_EMBEDDING_MODEL: "nomic-embed-text:latest"
WEBUI_NAME: "AI Demo - Kubernetes on GB10"
```

### Model Management
Pull additional models via Ollama CLI:
```bash
kubectl exec -n ai deployment/open-webui-ollama -- ollama pull <model>
```

Popular models:
- `qwen2.5-coder:7b` - Alternative coding model
- `phi3:14b` - Microsoft's efficient model
- `codellama:34b` - Meta's coding specialist
- `bakllava:latest` - Vision model alternative

### RAG Configuration
Access via Admin Panel → Settings → Documents:
- Chunk size: Adjustable for better context
- Embedding model: Switch between Ollama/OpenAI
- Web loader SSL: Enabled by default

## 📈 Performance Metrics

### Inference Speed
- **DeepSeek-Coder 33B**: ~12 tokens/sec (199 tokens/sec eval)
- **Llama3.2 1B**: <1s response time
- **LLaVA 13B**: ~5-8s for image + text response

### Resource Usage
- **DeepSeek-Coder 33B**: 19.6 GiB VRAM (full model + KV cache)
- **LLaVA 13B**: ~8 GiB VRAM
- **nomic-embed-text**: ~500 MB VRAM
- **Total available**: 128 GB unified memory

### Concurrent Usage
With exclusive GPU access:
- Only one model loads at a time
- Automatic model swapping when switching
- ~8s model load time for large models
- Optimal for single-user high-performance inference

## 🔍 Monitoring

### DCGM Exporter Metrics
GPU metrics available at:
- **Endpoint**: `http://nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400/metrics`
- **Scrape interval**: 30s
- **Grafana Dashboard**: ID 12239

### Key Metrics
- `DCGM_FI_DEV_GPU_UTIL` - GPU utilization %
- `DCGM_FI_DEV_FB_USED` - VRAM usage (bytes)
- `DCGM_FI_DEV_GPU_TEMP` - GPU temperature (°C)
- `DCGM_FI_DEV_SM_CLOCK` - SM clock speed (MHz)

## 🐛 Troubleshooting

### DeepSeek-Coder "GGGG" Issue
If you see repeated "G" characters:
1. Try `deepseek-coder-fixed:33b` model instead
2. This version has a compatible chat template

### Model Not Showing
1. Check if model is pulled: `kubectl exec -n ai deployment/open-webui-ollama -- ollama list`
2. Pull manually if missing: `kubectl exec -n ai deployment/open-webui-ollama -- ollama pull <model>`

### Slow Inference
1. Check GPU allocation: Only one model should be loaded
2. Verify exclusive access: `kubectl get node spark-9533 -o json | jq '.status.capacity."nvidia.com/gpu"'`
3. Should show `"1"` not `"8"`

### Web Search Not Working
1. Verify environment variable: `ENABLE_RAG_WEB_SEARCH=true`
2. Check Open-WebUI logs: `kubectl logs -n ai deployment/open-webui-0`
3. DuckDuckGo requires no API key

## 📚 Resources

- [Open-WebUI Documentation](https://docs.openwebui.com/)
- [Ollama Model Library](https://ollama.com/library)
- [NVIDIA DCGM Exporter](https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/)
- [GPU Operator Configuration](../gpu-operator/app/README.md)

## 🎓 Next Steps

1. **Add Image Generation**:
   - Deploy Stable Diffusion or AUTOMATIC1111
   - Configure in Admin Panel → Settings → Images

2. **Custom Functions**:
   - Create Python functions for specialized tasks
   - Access via Workspace → Functions

3. **Pipelines**:
   - Deploy open-webui/pipelines for advanced workflows
   - Integrate with external APIs (Anthropic, Google, etc.)

4. **Voice I/O**:
   - Enable TTS/STT for accessibility
   - Configure in Admin Panel → Settings → Audio

---

**Maintained by**: Raj Singh
**Last Updated**: 2025-11-03
**Version**: 1.0.0
