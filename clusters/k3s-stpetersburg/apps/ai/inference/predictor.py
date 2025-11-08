#!/usr/bin/env python3
"""
DeepSeek-OCR Custom Predictor for KServe
OpenAI-compatible OCR inference using HuggingFace Transformers
"""
import os
import io
import base64
import logging
import time
from typing import Dict, Any, List, Optional

from kserve import Model, ModelServer
from kserve.protocol.rest.openai import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatMessage,
    CompletionChoice,
    CompletionUsage,
)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DeepSeekOCRModel(Model):
    def __init__(self, name: str):
        super().__init__(name)
        self.name = name
        self.ready = False
        self.model = None
        self.processor = None
        self.tokenizer = None
        self.Image = None
        self.torch = None

    def load(self):
        """Load the DeepSeek-OCR model"""
        logger.info("Loading DeepSeek-OCR model with HuggingFace Transformers...")

        from PIL import Image as PILImage
        import torch as torch_module
        from transformers import AutoModelForCausalLM, AutoTokenizer, AutoProcessor

        self.Image = PILImage
        self.torch = torch_module

        model_name = "deepseek-ai/DeepSeek-OCR"

        try:
            # Load model
            logger.info(f"Loading model from {model_name}...")
            self.model = AutoModelForCausalLM.from_pretrained(
                model_name,
                torch_dtype=torch_module.bfloat16,
                device_map="auto",
                trust_remote_code=True,
            )

            # Load processor
            logger.info("Loading processor...")
            self.processor = AutoProcessor.from_pretrained(
                model_name,
                trust_remote_code=True
            )

            # Load tokenizer
            logger.info("Loading tokenizer...")
            self.tokenizer = AutoTokenizer.from_pretrained(
                model_name,
                trust_remote_code=True
            )

            self.ready = True
            logger.info("DeepSeek-OCR model loaded successfully")

        except Exception as e:
            logger.error(f"Failed to load model: {e}", exc_info=True)
            raise

    def predict(self, request: Dict, headers: Dict[str, str] = None) -> Dict:
        """
        Handle prediction requests
        Supports both OpenAI chat completion format and direct OCR format
        """
        try:
            # Handle OpenAI chat completion format
            if "messages" in request:
                return self._handle_chat_completion(request)

            # Handle direct OCR format
            elif "image" in request:
                return self._handle_direct_ocr(request)

            else:
                raise ValueError("Request must contain either 'messages' or 'image' field")

        except Exception as e:
            logger.error(f"Prediction error: {e}", exc_info=True)
            raise

    def _handle_chat_completion(self, request: Dict) -> Dict:
        """Handle OpenAI-style chat completion request"""
        messages = request.get("messages", [])
        temperature = request.get("temperature", 0.0)
        max_tokens = request.get("max_tokens", 8192)
        model_name = request.get("model", self.name)

        if not messages:
            raise ValueError("No messages provided")

        last_message = messages[-1]
        content = last_message.get("content", "")

        image_data = None
        prompt_text = ""

        # Parse message content
        if isinstance(content, list):
            for item in content:
                if item.get("type") == "image_url":
                    image_url = item["image_url"]["url"]
                    if image_url.startswith("data:image"):
                        base64_data = image_url.split(",")[1]
                        image_bytes = base64.b64decode(base64_data)
                        image_data = self.Image.open(io.BytesIO(image_bytes)).convert("RGB")
                    else:
                        raise ValueError("Only base64 encoded images are supported")
                elif item.get("type") == "text":
                    prompt_text = item["text"]
        else:
            prompt_text = content

        if image_data is None:
            raise ValueError("No image provided in message content")

        # Ensure prompt has <image> token
        if not prompt_text:
            prompt_text = "<image>\nFree OCR."
        elif not prompt_text.startswith("<image>"):
            prompt_text = f"<image>\n{prompt_text}"

        # Run OCR
        response_text, prompt_tokens, completion_tokens = self._run_ocr(
            image_data, prompt_text, temperature, max_tokens
        )

        # Return OpenAI-compatible response
        return {
            "id": f"chatcmpl-{os.urandom(12).hex()}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_name,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": response_text
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens
            }
        }

    def _handle_direct_ocr(self, request: Dict) -> Dict:
        """Handle direct OCR request with base64 image"""
        image_b64 = request["image"]
        prompt = request.get("prompt", "Free OCR.")
        temperature = request.get("temperature", 0.0)
        max_tokens = request.get("max_tokens", 8192)

        # Decode image
        image_bytes = base64.b64decode(image_b64)
        image_data = self.Image.open(io.BytesIO(image_bytes)).convert("RGB")

        # Ensure prompt has <image> token
        if not prompt.startswith("<image>"):
            prompt = f"<image>\n{prompt}"

        # Run OCR
        response_text, prompt_tokens, completion_tokens = self._run_ocr(
            image_data, prompt, temperature, max_tokens
        )

        return {
            "text": response_text,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens
        }

    def _run_ocr(self, image, prompt: str, temperature: float, max_tokens: int):
        """Run OCR inference on image"""
        logger.info(f"Processing OCR request: {prompt[:100]}...")

        # Process inputs
        inputs = self.processor(
            text=prompt,
            images=image,
            return_tensors="pt"
        ).to(self.model.device)

        # Generate response
        with self.torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature if temperature > 0 else None,
                do_sample=temperature > 0,
            )

        # Decode response
        response_text = self.tokenizer.decode(
            outputs[0][inputs["input_ids"].shape[1]:],
            skip_special_tokens=True
        )

        # Calculate token counts
        prompt_tokens = inputs["input_ids"].shape[1]
        completion_tokens = outputs.shape[1] - prompt_tokens

        return response_text, prompt_tokens, completion_tokens


if __name__ == "__main__":
    model = DeepSeekOCRModel("deepseek-ocr")
    ModelServer().start([model])
