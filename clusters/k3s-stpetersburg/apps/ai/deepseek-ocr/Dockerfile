FROM pytorch/pytorch:2.6.0-cuda12.8-cudnn9-runtime

WORKDIR /app

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CUDA_VISIBLE_DEVICES=0 \
    HF_HOME=/tmp/huggingface \
    HF_HUB_CACHE=/tmp/huggingface

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    transformers==4.46.3 \
    tokenizers==0.20.3 \
    fastapi==0.115.0 \
    uvicorn[standard]==0.32.0 \
    pillow==11.0.0 \
    accelerate==1.2.1 \
    einops==0.8.0

RUN pip install --no-cache-dir flash-attn==2.7.3 --no-build-isolation || \
    echo "Flash Attention installation failed, will fall back to eager attention"

COPY server.py /app/server.py

RUN chmod +x /app/server.py

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8000/health').raise_for_status()"

CMD ["python", "/app/server.py"]
