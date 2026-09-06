#!/usr/bin/env python3
"""WebP -> PNG transcoding reverse proxy for GJC vision.

    gjc  ->  (this, :8081)  ->  llama-server (:8080)

GJC re-encodes every attached image to WebP, but llama.cpp's multimodal loader
uses stb_image, which decodes jpg/png/bmp/gif but NOT webp -> "400 Failed to
load image". This rewrites `data:image/webp;base64,...` to PNG in JSON request
bodies in-flight. Everything else (streaming SSE, headers) passes through.

Env: UPSTREAM (default http://127.0.0.1:8080), PROXY_HOST (127.0.0.1), PROXY_PORT (8081).
Text-only models don't need this — point GJC straight at the llama-server port.
"""
import base64, io, json, os
from aiohttp import web, ClientSession, ClientTimeout
from PIL import Image

UPSTREAM = os.environ.get("UPSTREAM", "http://127.0.0.1:8080")
LISTEN   = os.environ.get("PROXY_HOST", "127.0.0.1")
PORT     = int(os.environ.get("PROXY_PORT", "8081"))
WEBP     = "data:image/webp;base64,"


def _webp_png(u):
    img = Image.open(io.BytesIO(base64.b64decode(u[len(WEBP):]))).convert("RGB")
    o = io.BytesIO(); img.save(o, format="PNG")
    return "data:image/png;base64," + base64.b64encode(o.getvalue()).decode()


def _conv(o):
    n = 0
    if isinstance(o, dict):
        for k, v in o.items(): o[k], c = _conv(v); n += c
    elif isinstance(o, list):
        for i, v in enumerate(o): o[i], c = _conv(v); n += c
    elif isinstance(o, str) and o.startswith(WEBP):
        try: o = _webp_png(o); n += 1
        except Exception as e: print("[proxy] webp->png failed:", e)
    return o, n


async def handler(req):
    url  = UPSTREAM + req.rel_url.path_qs
    body = await req.read()
    hdrs = {k: v for k, v in req.headers.items()
            if k.lower() not in ("host", "content-length")}
    if body and "application/json" in req.headers.get("Content-Type", ""):
        try:
            data, n = _conv(json.loads(body))
            if n:
                body = json.dumps(data).encode()
                print(f"[proxy] converted {n} webp->png")
        except json.JSONDecodeError:
            pass
    async with ClientSession(timeout=ClientTimeout(total=None, sock_read=None)) as s:
        async with s.request(req.method, url, data=body, headers=hdrs) as up:
            resp = web.StreamResponse(status=up.status)
            for k, v in up.headers.items():
                if k.lower() not in ("content-length", "transfer-encoding", "content-encoding"):
                    resp.headers[k] = v
            await resp.prepare(req)
            async for chunk in up.content.iter_any():
                await resp.write(chunk)
            await resp.write_eof()
            return resp


app = web.Application(client_max_size=1024 ** 3)
app.router.add_route("*", "/{tail:.*}", handler)
print(f"[proxy] {LISTEN}:{PORT} -> {UPSTREAM}")
web.run_app(app, host=LISTEN, port=PORT, print=None)
