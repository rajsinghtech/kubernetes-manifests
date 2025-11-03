#!/usr/bin/env python3
"""
DeepSeek-OCR FastAPI Server
OpenAI-compatible API for OCR inference
"""
import os
import io
import base64
import logging
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager

import torch
from transformers import AutoModel, AutoTokenizer
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from PIL import Image

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

model = None
tokenizer = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, tokenizer
    logger.info("Loading DeepSeek-OCR model...")

    os.environ["CUDA_VISIBLE_DEVICES"] = '0'
    model_name = 'deepseek-ai/DeepSeek-OCR'

    try:
        tokenizer = AutoTokenizer.from_pretrained(
            model_name,
            trust_remote_code=True,
            token=os.getenv('HF_TOKEN')
        )

        model = AutoModel.from_pretrained(
            model_name,
            _attn_implementation='flash_attention_2',
            trust_remote_code=True,
            use_safetensors=True,
            torch_dtype=torch.bfloat16,
            token=os.getenv('HF_TOKEN')
        )

        model = model.eval().cuda()
        logger.info("Model loaded successfully on GPU")

    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        raise

    yield

    logger.info("Shutting down...")
    del model
    del tokenizer
    torch.cuda.empty_cache()


app = FastAPI(
    title="DeepSeek-OCR API",
    description="OpenAI-compatible OCR inference server",
    version="1.0.0",
    lifespan=lifespan
)


class ChatMessage(BaseModel):
    role: str
    content: str | List[Dict[str, Any]]


class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 8192
    stream: Optional[bool] = False


class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[Dict[str, Any]]
    usage: Dict[str, int]


@app.get("/health")
async def health():
    """Health check endpoint"""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"status": "healthy", "model": "deepseek-ocr"}


@app.get("/v1/models")
async def list_models():
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
async def chat_completions(request: ChatCompletionRequest):
    """OpenAI-compatible chat completions endpoint"""
    if model is None or tokenizer is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

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
                        image_data = Image.open(io.BytesIO(image_bytes))
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
            prompt_text = "Extract all text from this document."

        logger.info(f"Processing OCR request with prompt: {prompt_text[:100]}...")

        inputs = tokenizer(
            prompt_text,
            images=image_data,
            return_tensors="pt"
        ).to(model.device)

        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=request.max_tokens,
                temperature=request.temperature,
                do_sample=request.temperature > 0,
                pad_token_id=tokenizer.pad_token_id,
                eos_token_id=tokenizer.eos_token_id
            )

        response_text = tokenizer.decode(
            outputs[0],
            skip_special_tokens=True
        )

        prompt_tokens = inputs['input_ids'].shape[1]
        completion_tokens = outputs.shape[1] - prompt_tokens

        return ChatCompletionResponse(
            id=f"chatcmpl-{os.urandom(12).hex()}",
            created=int(torch.cuda.Event().query()),
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
async def root():
    """Root endpoint"""
    return {
        "message": "DeepSeek-OCR API Server",
        "docs": "/docs",
        "health": "/health"
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )
