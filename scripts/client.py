#!/usr/bin/env python3
"""Direct OpenAI client to the local llama-server — bypasses GJC's webp/downscale
for highest-fidelity vision. Reasoning (if any) prints separately from the answer.

    python scripts/client.py "prompt"                       # text
    python scripts/client.py "what is this?" ./photo.jpg    # local image
    python scripts/client.py "describe" https://host/x.png  # remote image

Env: SPORT (server port, default 8080), ALIAS (model id; auto-detected if unset).
"""
import os, sys, base64, mimetypes
from openai import OpenAI

PORT  = os.environ.get("SPORT", "8080")
ALIAS = os.environ.get("ALIAS", "")
client = OpenAI(base_url=f"http://127.0.0.1:{PORT}/v1", api_key="none")
model = ALIAS or client.models.list().data[0].id

prompt = sys.argv[1] if len(sys.argv) > 1 else "Hello!"
content = [{"type": "text", "text": prompt}]
if len(sys.argv) > 2:
    src = sys.argv[2]
    if src.startswith(("http://", "https://")):
        url = src
    else:
        mt = mimetypes.guess_type(src)[0] or "image/png"
        with open(src, "rb") as f:
            url = f"data:{mt};base64," + base64.b64encode(f.read()).decode()
    content.insert(0, {"type": "image_url", "image_url": {"url": url}})

r = client.chat.completions.create(
    model=model,
    messages=[{"role": "user", "content": content}],
    max_tokens=int(os.environ.get("MAXTOKENS", "1024")),
)
msg = r.choices[0].message
if getattr(msg, "reasoning_content", None):
    print("--- reasoning ---\n" + msg.reasoning_content + "\n--- answer ---")
print(msg.content)
