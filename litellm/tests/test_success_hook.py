"""Tests for ToolRepairHandler.async_post_call_success_hook.

This hook runs on NON-STREAMING successful responses. It scans
`message.content` for four known malformed tool-call shapes and rewrites
them into a proper OpenAI `tool_calls[]` block, clears `content`, and
sets `finish_reason='tool_calls'`. It also cleans leaked DSML delimiter
noise from `content` when `tool_calls` is already populated.

Covered cases:
  1. Hermes/Qwen <tool_call>{...}</tool_call> XML wrap
  2. Llama 3.x <|python_tag|>{...} JSON tag
  3. Llama raw key=value: web_search={"query": "..."}
  4. Pythonic list: [search(q="hello")]
  5. Delimiter leakage with tool_calls already populated -> strip-only
  6. Plain text + tool_calls=None -> no modification
"""

from __future__ import annotations

import json

import pytest


def _make_response(content, tool_calls=None, finish_reason="stop"):
    """Build a dict-shaped fake LiteLLM response matching what the proxy
    passes into the success hook. Dict form is fine — the handler's
    `_get`/`_set` helpers transparently support both dict and attr access."""
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "model": "test-model",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": content,
                    "tool_calls": tool_calls,
                },
                "finish_reason": finish_reason,
            }
        ],
    }


def _msg(response):
    return response["choices"][0]["message"]


def _choice(response):
    return response["choices"][0]


# ---------------------------------------------------------------------------
# Cases 1-4: malformed tool-call shapes in content get rewritten
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "case_id, content, expected_name, expected_args",
    [
        (
            "hermes_xml",
            '<tool_call>{"name": "web_search", "arguments": {"q": "x"}}</tool_call>',
            "web_search",
            {"q": "x"},
        ),
        (
            "llama_python_tag",
            '<|python_tag|>{"name": "foo", "parameters": {}}',
            "foo",
            {},
        ),
        (
            "raw_kv",
            'web_search={"query": "hello"}',
            "web_search",
            {"query": "hello"},
        ),
        (
            "pythonic",
            '[search(q="hello")]',
            "search",
            {"q": "hello"},
        ),
    ],
)
async def test_success_hook_repairs_malformed_tool_call(
    repair_handler, case_id, content, expected_name, expected_args
):
    """Each malformed shape gets rewritten into tool_calls[] with content cleared."""
    response = _make_response(content=content, tool_calls=None)

    # Before: content is the raw string, tool_calls is None, finish_reason=stop
    assert _msg(response)["content"] == content
    assert _msg(response)["tool_calls"] is None
    assert _choice(response)["finish_reason"] == "stop"

    result = await repair_handler.async_post_call_success_hook(
        data={}, user_api_key_dict=None, response=response
    )

    # After: tool_calls populated, content cleared, finish_reason switched
    msg = _msg(result)
    assert msg["content"] is None, f"[{case_id}] content should be cleared"
    assert msg["tool_calls"] is not None, f"[{case_id}] tool_calls should be set"
    assert len(msg["tool_calls"]) == 1
    call = msg["tool_calls"][0]
    assert call["type"] == "function"
    assert call["id"].startswith("call_")
    assert call["function"]["name"] == expected_name
    parsed_args = json.loads(call["function"]["arguments"])
    assert parsed_args == expected_args
    assert _choice(result)["finish_reason"] == "tool_calls"


# ---------------------------------------------------------------------------
# Case 5: tool_calls already populated + leaked delimiter noise in content
# ---------------------------------------------------------------------------


async def test_success_hook_strips_delimiter_noise_when_tool_calls_present(
    repair_handler,
):
    """When tool_calls is already populated, just clean DSML noise from content."""
    existing_tool_calls = [
        {
            "id": "call_existing123",
            "type": "function",
            "function": {
                "name": "real_tool",
                "arguments": json.dumps({"x": 1}),
            },
        }
    ]
    noisy_content = "Some assistant text<｜DSML｜function_calls｜>"
    response = _make_response(
        content=noisy_content,
        tool_calls=existing_tool_calls,
        finish_reason="tool_calls",
    )

    # Before: noisy content visible, tool_calls already set
    assert "｜" in _msg(response)["content"]
    assert _msg(response)["tool_calls"] == existing_tool_calls

    result = await repair_handler.async_post_call_success_hook(
        data={}, user_api_key_dict=None, response=response
    )

    msg = _msg(result)
    # After: tool_calls left untouched, content stripped of the DSML noise
    assert msg["tool_calls"] == existing_tool_calls
    assert "｜" not in (msg["content"] or "")
    assert "DSML" not in (msg["content"] or "")
    # The real prose survives.
    assert "Some assistant text" in (msg["content"] or "")
    # finish_reason should NOT have been clobbered to "tool_calls" by repair
    # path — it was already tool_calls coming in, and we shouldn't touch it.
    assert _choice(result)["finish_reason"] == "tool_calls"


# ---------------------------------------------------------------------------
# Case 6: plain text with no tool_calls -> no-op
# ---------------------------------------------------------------------------


async def test_success_hook_leaves_plain_text_untouched(repair_handler):
    """Plain assistant prose with no tool-call markers should pass through unchanged."""
    response = _make_response(content="Hello world", tool_calls=None)

    # Before
    assert _msg(response)["content"] == "Hello world"
    assert _msg(response)["tool_calls"] is None
    assert _choice(response)["finish_reason"] == "stop"

    result = await repair_handler.async_post_call_success_hook(
        data={}, user_api_key_dict=None, response=response
    )

    # After: untouched
    msg = _msg(result)
    assert msg["content"] == "Hello world"
    assert msg["tool_calls"] is None
    assert _choice(result)["finish_reason"] == "stop"


# ---------------------------------------------------------------------------
# Defensive: no choices / empty response shouldn't crash
# ---------------------------------------------------------------------------


async def test_success_hook_handles_empty_choices(repair_handler):
    """Missing/empty choices is best-effort — return response unmodified."""
    response = {"id": "chatcmpl-test", "choices": []}
    result = await repair_handler.async_post_call_success_hook(
        data={}, user_api_key_dict=None, response=response
    )
    assert result == {"id": "chatcmpl-test", "choices": []}


async def test_success_hook_skips_when_no_content_and_no_tool_calls(repair_handler):
    """Message with content=None and tool_calls=None is a no-op (nothing to repair)."""
    response = _make_response(content=None, tool_calls=None)
    result = await repair_handler.async_post_call_success_hook(
        data={}, user_api_key_dict=None, response=response
    )
    msg = _msg(result)
    assert msg["content"] is None
    assert msg["tool_calls"] is None
    assert _choice(result)["finish_reason"] == "stop"
