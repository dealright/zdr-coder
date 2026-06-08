"""Tests for ToolRepairHandler.async_post_call_failure_hook.

The non-streaming failure hook's job is to convert two specific upstream-error
shapes into a clean HTTP 400 before LiteLLM's int-cast crashes the response:

  - Groq's `tool_use_failed` (a STRING error code) which LiteLLM tries to int()
  - The resulting `invalid literal for int() with base 10: 'tool_use_failed'`

Anything else must propagate unchanged so we don't accidentally swallow real
infrastructure errors (network, auth, etc.).
"""

from __future__ import annotations

import pytest

# fastapi is optional in tool_repair (try/except ImportError). The hook only
# raises HTTPException when fastapi IS importable; if not, it falls through to
# re-raising the original. Skip the whole module if fastapi is absent so tests
# match the real production path (proxy always has fastapi installed).
try:
    from fastapi import HTTPException
except ImportError:  # pragma: no cover
    pytest.skip("fastapi not installed — skipping failure_hook tests", allow_module_level=True)


# ---------------------------------------------------------------------------
# Match cases — exceptions that SHOULD be re-raised as HTTPException 400
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "exc",
    [
        pytest.param(
            Exception(
                "litellm.BadRequestError: GroqException - "
                "{'error': {'message': 'tool_use_failed', 'code': 'tool_use_failed'}}"
            ),
            id="groq_tool_use_failed",
        ),
        pytest.param(
            ValueError("invalid literal for int() with base 10: 'tool_use_failed'"),
            id="int_cast_value_error",
        ),
        pytest.param(
            Exception("tool_use_failed"),
            id="bare_tool_use_failed_string",
        ),
        pytest.param(
            ValueError("invalid literal for int() with base 10: 'context_length_exceeded'"),
            id="int_cast_with_other_code",
        ),
    ],
)
async def test_failure_hook_converts_known_errors_to_http_400(repair_handler, exc):
    """Known upstream patterns get rewritten as a clean HTTPException(400)."""
    with pytest.raises(HTTPException) as exc_info:
        await repair_handler.async_post_call_failure_hook(
            request_data={"model": "sonnet-llama-groq"},
            original_exception=exc,
            user_api_key_dict=None,
        )

    raised = exc_info.value
    assert raised.status_code == 400
    assert isinstance(raised.detail, dict)
    err = raised.detail.get("error")
    assert isinstance(err, dict)
    assert err.get("code") == "tool_use_failed"
    assert err.get("type") == "tool_use_failed"
    # Human-readable message must mention the error so clients see useful diag
    msg = err.get("message", "").lower()
    assert "tool_use_failed" in msg or "tool call" in msg
    # The upstream excerpt should be present and truncated to <= 300 chars
    assert "upstream" in err
    assert len(err["upstream"]) <= 300


async def test_failure_hook_preserves_upstream_message_excerpt(repair_handler):
    """The original exception string is embedded in detail.error.upstream."""
    exc = Exception("tool_use_failed: model emitted bad args for web_search")
    with pytest.raises(HTTPException) as exc_info:
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )
    assert "tool_use_failed" in exc_info.value.detail["error"]["upstream"]


async def test_failure_hook_truncates_long_upstream_to_300_chars(repair_handler):
    """Very long upstream errors get sliced to 300 chars so detail stays small."""
    long_tail = "x" * 5000
    exc = Exception(f"tool_use_failed {long_tail}")
    with pytest.raises(HTTPException) as exc_info:
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )
    assert len(exc_info.value.detail["error"]["upstream"]) == 300


# ---------------------------------------------------------------------------
# Non-matching cases — exception must propagate AS-IS, NOT be swallowed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "exc",
    [
        pytest.param(ConnectionError("upstream unreachable"), id="connection_error"),
        pytest.param(TimeoutError("read timeout after 60s"), id="timeout"),
        pytest.param(RuntimeError("rate limit exceeded"), id="runtime_error"),
        pytest.param(
            Exception("litellm.AuthenticationError - invalid api key"),
            id="auth_error",
        ),
        pytest.param(ValueError("some unrelated value error"), id="unrelated_value_error"),
    ],
)
async def test_failure_hook_propagates_unknown_errors_unchanged(repair_handler, exc):
    """Errors not matching the known patterns must re-raise as the SAME object."""
    with pytest.raises(type(exc)) as exc_info:
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )
    # The exact same object should propagate — not a new wrapper
    assert exc_info.value is exc


async def test_failure_hook_does_not_convert_connection_error_to_400(repair_handler):
    """Regression: don't accidentally turn infra errors into 400 client errors."""
    exc = ConnectionError("backend down")
    with pytest.raises(ConnectionError):
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )


# ---------------------------------------------------------------------------
# Defensive — None and other oddballs
# ---------------------------------------------------------------------------


async def test_failure_hook_with_none_exception_raises(repair_handler):
    """Passing None as original_exception should not silently succeed."""
    # str(None) == "None", which does NOT contain the target substrings, so the
    # hook reaches `raise original_exception` and Python raises TypeError on
    # `raise None`.
    with pytest.raises(TypeError):
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=None,
            user_api_key_dict=None,
        )


async def test_failure_hook_substring_match_is_case_sensitive(repair_handler):
    """Sanity: 'TOOL_USE_FAILED' (uppercase) does NOT trigger the rewrite.

    The hook uses literal `in` checks, so casing matters. This documents the
    current behavior and guards against accidentally broadening the match.
    """
    exc = Exception("TOOL_USE_FAILED in uppercase should not match")
    with pytest.raises(Exception) as exc_info:
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )
    # Should propagate unchanged, NOT become HTTPException
    assert not isinstance(exc_info.value, HTTPException)
    assert exc_info.value is exc
