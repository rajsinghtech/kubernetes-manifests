#!/usr/bin/env python3
"""
DeepSeek-OCR Ray Serve Application
OpenAI-compatible OCR inference using HuggingFace Transformers
"""
import os
import io
import base64
import logging
from typing import Optional, List, Dict, Any

from ray import serve
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from PIL import Image
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, AutoProcessor

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="DeepSeek-OCR API",
    description="OpenAI-compatible OCR inference server powered by HuggingFace Transformers and Ray Serve",
    version="1.0.0"
)


class ChatMessage(BaseModel):
    role: str
    content: str | List[Dict[str, Any]]


class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.0
    max_tokens: Optional[int] = 8192
    stream: Optional[bool] = False


class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[Dict[str, Any]]
    usage: Dict[str, int]


@serve.deployment(
    name="deepseek-ocr",
    ray_actor_options={
        "num_gpus": 1,
        "num_cpus": 4,
        "memory": 24 * 1024 * 1024 * 1024,  # 24GB
    },
    autoscaling_config={
        "min_replicas": 0,
        "max_replicas": 2,
        "target_ongoing_requests": 1,
        "upscale_delay_s": 30,
        "downscale_delay_s": 300,
    },
    health_check_period_s=30,
    health_check_timeout_s=30,
)
@serve.ingress(app)
class DeepSeekOCRServe:
    def __init__(self):
        logger.info("Initializing DeepSeek-OCR model with Transformers...")

        model_name = "deepseek-ai/DeepSeek-OCR"

        # Load model and processor
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.bfloat16,
            device_map="auto",
            trust_remote_code=True,
        )

        self.processor = AutoProcessor.from_pretrained(
            model_name,
            trust_remote_code=True
        )

        self.tokenizer = AutoTokenizer.from_pretrained(
            model_name,
            trust_remote_code=True
        )

        logger.info("DeepSeek-OCR model loaded successfully")

    @app.get("/health")
    async def health(self):
        """Health check endpoint"""
        return {"status": "healthy", "model": "deepseek-ocr"}

    @app.get("/v1/models")
    async def list_models(self):
        """OpenAI-compatible models endpoint"""
        return {
            "object": "list",
            "data": [
                {
                    "id": "deepseek-ocr",
                    "object": "model",
                    "created": 1730000000,
                    "owned_by": "deepseek-ai",
                    "permission": [],
                    "root": "deepseek-ocr",
                    "parent": None
                }
            ]
        }

    @app.post("/v1/chat/completions")
    async def chat_completions(self, request: ChatCompletionRequest):
        """OpenAI-compatible chat completions endpoint"""
        try:
            messages = request.messages
            if not messages:
                raise HTTPException(status_code=400, detail="No messages provided")

            last_message = messages[-1]

            image_data = None
            prompt_text = ""

            if isinstance(last_message.content, list):
                for content in last_message.content:
                    if content.get("type") == "image_url":
                        image_url = content["image_url"]["url"]
                        if image_url.startswith("data:image"):
                            base64_data = image_url.split(",")[1]
                            image_bytes = base64.b64decode(base64_data)
                            image_data = Image.open(io.BytesIO(image_bytes)).convert("RGB")
                        else:
                            raise HTTPException(
                                status_code=400,
                                detail="Only base64 encoded images are supported"
                            )
                    elif content.get("type") == "text":
                        prompt_text = content["text"]
            else:
                prompt_text = last_message.content

            if image_data is None:
                raise HTTPException(
                    status_code=400,
                    detail="No image provided in message content"
                )

            if not prompt_text:
                prompt_text = "<image>\nFree OCR."
            elif not prompt_text.startswith("<image>"):
                prompt_text = f"<image>\n{prompt_text}"

            logger.info(f"Processing OCR request: {prompt_text[:100]}...")

            # Process the inputs
            inputs = self.processor(
                text=prompt_text,
                images=image_data,
                return_tensors="pt"
            ).to(self.model.device)

            # Generate response
            with torch.no_grad():
                outputs = self.model.generate(
                    **inputs,
                    max_new_tokens=request.max_tokens,
                    temperature=request.temperature if request.temperature > 0 else None,
                    do_sample=request.temperature > 0,
                )

            # Decode response
            response_text = self.tokenizer.decode(
                outputs[0][inputs["input_ids"].shape[1]:],
                skip_special_tokens=True
            )

            # Calculate token counts (approximate)
            prompt_tokens = inputs["input_ids"].shape[1]
            completion_tokens = outputs.shape[1] - prompt_tokens

            return ChatCompletionResponse(
                id=f"chatcmpl-{os.urandom(12).hex()}",
                created=int(os.times().elapsed),
                model=request.model,
                choices=[
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": response_text
                        },
                        "finish_reason": "stop"
                    }
                ],
                usage={
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                    "total_tokens": prompt_tokens + completion_tokens
                }
            )

        except Exception as e:
            logger.error(f"Error processing request: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail=str(e))

    @app.get("/")
    async def root(self):
        """Root endpoint"""
        return {
            "message": "DeepSeek-OCR API Server (Ray Serve + Transformers)",
            "docs": "/docs",
            "health": "/health"
        }


deployment = DeepSeekOCRServe.bind()
