"""In-process OpenAI-compatible /v1/chat/completions stub for streaming tests.

Pattern borrowed from Hermes's tests/fakes/fake_ha_server.py — an aiohttp.web
app bound to an ephemeral port. The test code points LiteLLM (or a raw httpx
client) at the resulting URL and the server emits a pre-canned sequence of
SSE chunks.

Usage:
    async with FakeBedrockServer(chunks=["hello ", "world"]) as server:
        # server.url -> http://127.0.0.1:<port>
        ...

If `inject_error` is set, the server emits a single error chunk in the shape
that triggers Groq's `tool_use_failed` int-parse crash downstream.
"""

from __future__ import annotations

import asyncio
import json
import socket
from typing import Iterable

from aiohttp import web


def _pick_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeBedrockServer:
    """Lightweight OpenAI-compatible chat-completions stub.

    `chunks` is the sequence of delta-content strings to emit as SSE.
    `inject_error` (optional) is an error code string to emit instead of
    a normal stream — produces a chunk that mimics the Groq tool_use_failed
    payload that triggers the int-cast bug in LiteLLM's adapter.
    """

    def __init__(
        self,
        chunks: Iterable[str] | None = None,
        inject_error: str | None = None,
        model_name: str = "fake-model",
        host: str = "127.0.0.1",
    ) -> None:
        self.chunks = list(chunks or [])
        self.inject_error = inject_error
        self.model_name = model_name
        self.host = host
        self.port: int | None = None
        self._runner: web.AppRunner | None = None
        self._site: web.TCPSite | None = None
        self.received_requests: list[dict] = []

    @property
    def url(self) -> str:
        if self.port is None:
            raise RuntimeError("server not started — use `async with`")
        return f"http://{self.host}:{self.port}"

    async def __aenter__(self) -> "FakeBedrockServer":
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self._handle_chat)
        app.router.add_post("/chat/completions", self._handle_chat)
        self._runner = web.AppRunner(app)
        await self._runner.setup()
        self.port = _pick_free_port()
        self._site = web.TCPSite(self._runner, self.host, self.port)
        await self._site.start()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._site is not None:
            await self._site.stop()
        if self._runner is not None:
            await self._runner.cleanup()

    async def _handle_chat(self, request: web.Request) -> web.StreamResponse:
        try:
            body = await request.json()
        except Exception:
            body = {}
        self.received_requests.append(body)
        streaming = bool(body.get("stream"))

        if self.inject_error is not None:
            return await self._handle_error(request, streaming)

        if streaming:
            return await self._handle_stream(request)
        return await self._handle_non_stream()

    async def _handle_error(
        self, request: web.Request, streaming: bool
    ) -> web.StreamResponse:
        # Mimic Groq's tool_use_failed shape — the `code` is a string, which
        # is what triggers LiteLLM's int-cast crash downstream.
        payload = {
            "error": {
                "message": "Tool call generation failed.",
                "type": "invalid_request_error",
                "code": self.inject_error,  # string, not int!
            }
        }
        if not streaming:
            return web.json_response(payload, status=400)
        # Streaming error path: emit one SSE chunk with the error then close.
        resp = web.StreamResponse(
            status=400,
            headers={"Content-Type": "text/event-stream"},
        )
        await resp.prepare(request)
        await resp.write(f"data: {json.dumps(payload)}\n\n".encode())
        await resp.write(b"data: [DONE]\n\n")
        await resp.write_eof()
        return resp

    async def _handle_stream(self, request: web.Request) -> web.StreamResponse:
        resp = web.StreamResponse(
            status=200,
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
        )
        await resp.prepare(request)
        for i, content in enumerate(self.chunks):
            chunk = {
                "id": f"chatcmpl-{i}",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": self.model_name,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": content},
                        "finish_reason": None,
                    }
                ],
            }
            await resp.write(f"data: {json.dumps(chunk)}\n\n".encode())
            # tiny yield so chunks actually flush
            await asyncio.sleep(0)
        # Final chunk with finish_reason=stop
        final = {
            "id": "chatcmpl-final",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": self.model_name,
            "choices": [
                {
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop",
                }
            ],
        }
        await resp.write(f"data: {json.dumps(final)}\n\n".encode())
        await resp.write(b"data: [DONE]\n\n")
        await resp.write_eof()
        return resp

    async def _handle_non_stream(self) -> web.Response:
        text = "".join(self.chunks)
        body = {
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "created": 0,
            "model": self.model_name,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        return web.json_response(body)
