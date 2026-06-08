"""End-to-end tests against the live LiteLLM proxy at localhost:4000.

Exercises the MANAGED-API routes (those that need no self-hosted GPU). For
each route, we verify the three behaviors the tool_repair hook is meant to
preserve:

  1. Plain single-turn chat returns 200 with non-empty assistant content.
  2. A tool-call request returns a well-formed ``tool_calls[]`` array
     (or politely ``finish_reason == 'stop'`` if the model declines) — but
     never a 500. This is the regression for Groq's ``tool_use_failed``
     int-parse crash.
  3. A multi-turn STREAMING conversation with tools defined never leaks
     DeepSeek/DSML delimiter fragments (``<｜DSML｜``, ``function_calls``,
     a trailing ``_calls``) into any visible chunk. This is the regression
     for the chunk-split delimiter bugs.

The whole module is marked ``integration``. If the proxy health check fails
(no docker compose running), every test in this file is skipped so the suite
remains green for collaborators who haven't booted the stack.
"""

from __future__ import annotations

import json
from typing import Iterable

import httpx
import pytest


# Routes that are MANAGED (Groq, Bedrock) — no GPU pod required to be running.
# These are the only routes safe to hit from CI / a clean workstation.
MANAGED_ROUTES = [
    "haiku-api",
    "sonnet-api",
    "haiku-llama",
    "sonnet-llama",
    "opus-bedrock",
    "vision-bedrock",
    "sonnet-deepseek-bedrock",
]


# The single tool we declare for the tool-call tests. Picking something
# unambiguous and trivially-schema'd so any half-competent tool-using model
# emits a call rather than refusing.
WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather in a given location.",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {
                    "type": "string",
                    "description": "City name, e.g. 'San Francisco'",
                }
            },
            "required": ["location"],
        },
    },
}


# Chunk-content fragments that must NEVER appear in any streamed delta after
# tool_repair has done its job. These are the exact leakage patterns the
# streaming hook is responsible for suppressing.
FORBIDDEN_DELIMITER_FRAGMENTS = ("<｜DSML｜", "function_calls")


# ---------------------------------------------------------------------------
# Module-level skip: if the proxy isn't responding, skip everything below.
# ---------------------------------------------------------------------------
pytestmark = pytest.mark.integration


def _proxy_healthy(base_url: str) -> bool:
    """Best-effort liveness probe. Any reachable response counts as 'up'
    because LiteLLM's /health endpoint may itself 4xx without auth — we
    only care that something is listening on the port."""
    try:
        r = httpx.get(f"{base_url}/health/readiness", timeout=2.0)
        if r.status_code < 500:
            return True
        # Fall back to root — if anything answers, the proxy is up.
        httpx.get(f"{base_url}/", timeout=2.0)
        return True
    except (httpx.ConnectError, httpx.ReadTimeout, httpx.TimeoutException):
        return False
    except httpx.HTTPError:
        return False


@pytest.fixture(scope="module")
def proxy_or_skip(litellm_url):
    """Skip the whole module if the local LiteLLM proxy isn't reachable."""
    if not _proxy_healthy(litellm_url):
        pytest.skip(f"LiteLLM proxy at {litellm_url} not reachable — start docker compose first")
    return litellm_url


@pytest.fixture
def auth_headers(litellm_key):
    """OpenAI-compatible bearer header for the proxy."""
    return {
        "Authorization": f"Bearer {litellm_key}",
        "Content-Type": "application/json",
    }


def _post_chat(
    base_url: str,
    headers: dict,
    model: str,
    messages: list,
    *,
    tools: list | None = None,
    stream: bool = False,
    timeout: float = 60.0,
) -> httpx.Response:
    """Single source of truth for hitting /v1/chat/completions on the proxy."""
    payload: dict = {"model": model, "messages": messages}
    if tools is not None:
        payload["tools"] = tools
    if stream:
        payload["stream"] = True
    return httpx.post(
        f"{base_url}/v1/chat/completions",
        headers=headers,
        json=payload,
        timeout=timeout,
    )


def _iter_sse_chunks(resp: httpx.Response) -> Iterable[dict]:
    """Yield parsed JSON objects from an OpenAI-style SSE stream response.

    Skips ``[DONE]`` sentinel and any non-data lines. Tolerates blank lines."""
    for raw_line in resp.iter_lines():
        if not raw_line:
            continue
        line = raw_line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            yield json.loads(payload)
        except json.JSONDecodeError:
            # tool_repair bug #2 was about Python-repr (single-quote) chunks
            # breaking client JSON parsing — a JSONDecodeError here means
            # the hook regressed. Re-raise as a clear assertion failure.
            raise AssertionError(
                f"streamed chunk is not valid JSON (single-quote regression?): {payload!r}"
            )


# ---------------------------------------------------------------------------
# Test 1: single-turn 'reply ok' — proxy responds 200, non-empty content.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("model", MANAGED_ROUTES)
def test_single_turn_reply_returns_200_with_content(
    proxy_or_skip, auth_headers, model
):
    """Plain single-turn chat returns 200 with non-empty assistant content."""
    resp = _post_chat(
        proxy_or_skip,
        auth_headers,
        model,
        messages=[{"role": "user", "content": "Reply with exactly: ok"}],
    )
    # Route may be unconfigured (env var missing → 502) or vision-only routes
    # may refuse text — skip those rather than fail the suite.
    if resp.status_code in (404, 502, 503):
        pytest.skip(f"route {model!r} not configured / upstream unreachable ({resp.status_code})")
    if resp.status_code == 400 and "vision" in model:
        pytest.skip(f"route {model!r} appears to be vision-only — text refused")
    assert resp.status_code == 200, (
        f"{model}: expected 200, got {resp.status_code}: {resp.text[:300]}"
    )
    body = resp.json()
    choices = body.get("choices") or []
    assert choices, f"{model}: empty choices in response body"
    content = (choices[0].get("message") or {}).get("content")
    assert content and isinstance(content, str) and content.strip(), (
        f"{model}: empty assistant content: {body!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: tool-call — 200 + finish_reason in {tool_calls, stop}. No 500.
# Regression for Groq's `tool_use_failed` int-parse crash.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("model", MANAGED_ROUTES)
def test_tool_call_request_does_not_crash_and_returns_clean_finish(
    proxy_or_skip, auth_headers, model
):
    """Tool-call request returns 200 with finish_reason tool_calls|stop, never 500."""
    resp = _post_chat(
        proxy_or_skip,
        auth_headers,
        model,
        messages=[
            {
                "role": "user",
                "content": (
                    "What's the weather in Paris? Use the get_weather tool."
                ),
            }
        ],
        tools=[WEATHER_TOOL],
    )
    if resp.status_code in (404, 502, 503):
        pytest.skip(f"route {model!r} not configured / upstream unreachable ({resp.status_code})")
    # The Groq tool_use_failed bug used to surface as a raw 500 here. The
    # repair hook re-raises as 400 with a clean JSON body. Accept both as
    # 'not a crash' but FAIL on a raw 500.
    assert resp.status_code != 500, (
        f"{model}: got HTTP 500 — tool_repair failure hook regressed? "
        f"body={resp.text[:500]}"
    )
    if resp.status_code == 400:
        # The hook converted the upstream tool_use_failed into a clean 400 —
        # that's the desired behavior for the Groq path. Verify the body
        # is well-formed JSON (not Python repr).
        body = resp.json()
        assert "error" in body or "detail" in body, (
            f"{model}: 400 missing structured error body: {body!r}"
        )
        return
    assert resp.status_code == 200, (
        f"{model}: unexpected status {resp.status_code}: {resp.text[:300]}"
    )
    body = resp.json()
    choices = body.get("choices") or []
    assert choices, f"{model}: empty choices in tool-call response"
    choice = choices[0]
    finish = choice.get("finish_reason")
    assert finish in ("tool_calls", "stop", "end_turn"), (
        f"{model}: unexpected finish_reason {finish!r}, body={body!r}"
    )
    if finish == "tool_calls":
        tool_calls = (choice.get("message") or {}).get("tool_calls") or []
        assert tool_calls, (
            f"{model}: finish_reason=tool_calls but tool_calls[] is empty: {body!r}"
        )
        # Each tool_call must have the OpenAI-shape ``function.name``+``arguments``.
        for tc in tool_calls:
            fn = tc.get("function") or {}
            assert fn.get("name"), f"{model}: tool_call missing function.name: {tc!r}"
            assert "arguments" in fn, f"{model}: tool_call missing function.arguments: {tc!r}"


# ---------------------------------------------------------------------------
# Test 3: multi-turn STREAMING with tools — no 500, no delimiter leakage.
# Regression for chunk-split DSML + greedy-strip-eats-partial bugs.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("model", MANAGED_ROUTES)
def test_multi_turn_streaming_no_delimiter_leakage(
    proxy_or_skip, auth_headers, model
):
    """Streaming multi-turn-with-tools never leaks DSML/function_calls fragments."""
    messages = [
        {"role": "user", "content": "Hi. I'll ask about weather next."},
        {
            "role": "assistant",
            "content": "Sure — what city would you like the weather for?",
        },
        {
            "role": "user",
            "content": (
                "Tokyo, please. Then briefly explain what you did in one sentence."
            ),
        },
    ]
    with httpx.stream(
        "POST",
        f"{proxy_or_skip}/v1/chat/completions",
        headers=auth_headers,
        json={
            "model": model,
            "messages": messages,
            "tools": [WEATHER_TOOL],
            "stream": True,
        },
        timeout=60.0,
    ) as resp:
        if resp.status_code in (404, 502, 503):
            pytest.skip(
                f"route {model!r} not configured / upstream unreachable ({resp.status_code})"
            )
        assert resp.status_code != 500, (
            f"{model}: streaming got HTTP 500 — tool_repair streaming hook regressed? "
            f"body={resp.read()[:500]!r}"
        )
        # Anything other than 200 here is a route config issue, not a hook
        # regression — skip so the rest of the matrix still runs.
        if resp.status_code != 200:
            body_snip = resp.read()[:300]
            pytest.skip(
                f"route {model!r} returned {resp.status_code} for streaming: {body_snip!r}"
            )

        # Collect every visible delta-content fragment from the stream.
        collected: list[str] = []
        for obj in _iter_sse_chunks(resp):
            choices = obj.get("choices") or []
            for ch in choices:
                delta = ch.get("delta") or {}
                content = delta.get("content")
                if content:
                    collected.append(content)
                    # Per-chunk guards: no delimiter fragment should ever
                    # appear in any single delta, AND no chunk should end
                    # in `_calls` (the chunk-split orphan symptom).
                    for forbidden in FORBIDDEN_DELIMITER_FRAGMENTS:
                        assert forbidden not in content, (
                            f"{model}: delimiter fragment {forbidden!r} leaked "
                            f"into streamed chunk: {content!r}"
                        )
                    stripped = content.rstrip()
                    assert not stripped.endswith("_calls"), (
                        f"{model}: chunk ends with orphaned '_calls' — "
                        f"chunk-split partial leaked: {content!r}"
                    )

        # Belt-and-braces: also check the JOINED content for any forbidden
        # fragment (in case one slipped across a chunk boundary).
        joined = "".join(collected)
        for forbidden in FORBIDDEN_DELIMITER_FRAGMENTS:
            assert forbidden not in joined, (
                f"{model}: delimiter fragment {forbidden!r} present in joined "
                f"streamed content: {joined[:300]!r}"
            )
