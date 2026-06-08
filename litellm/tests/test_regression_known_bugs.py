"""Regression coverage for every distinct bug class we've hit in this session.

One test per bug. Each docstring quotes the originating session log so we
remember WHY the test exists. If any of these tests starts failing the bug
is back — don't delete the test, fix the regression.

The four bugs:

  1. Groq's `tool_use_failed` is a STRING error code. LiteLLM's Groq adapter
     calls `int(status_code)` on it and raises ValueError, which surfaces to
     the client as a confusing HTTP 500 ("invalid literal for int() with
     base 10: 'tool_use_failed'") instead of a clean 400.

  2. The streaming iterator hook used to yield a RAW DICT for synthetic error
     chunks. LiteLLM's downstream serializer falls back to `str(obj)` which
     produces Python repr with single quotes, breaking the OpenAI client's
     JSON parser with "Expecting property name enclosed in double quotes".
     Must yield a real ModelResponseStream (Pydantic) so .model_dump_json()
     fires the right path.

  3. DSML delimiter tokens (e.g. `<｜DSML｜function_calls`) split across
     streaming chunks at arbitrary char boundaries — `<｜DSML｜function_c`
     then `alls X`. Without a per-stream hold-buffer, the tail leaks
     through cleanly while the head gets stripped, leaving `alls X` in
     the user-visible content.

  4. Even WITH a buffer, if you strip BEFORE you hold, the regex greedily
     matches the partial form `<｜DSML｜function_c` (because we added
     bare-fragment matches like `function_calls?` to handle case-3 split
     tails). That eats the partial, and the next chunk's `alls` arrives
     with no preceding `｜` to gate on — so `alls` leaks. The fix is to
     ALWAYS hold the longest delimiter-prefix tail BEFORE running the
     strip regex on what's released.
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Bug 1: Groq tool_use_failed string status code → HTTP 500
# ---------------------------------------------------------------------------

async def test_bug_groq_tool_use_failed_str_status_code(repair_handler):
    """Originating log: 'invalid literal for int() with base 10:
    tool_use_failed' returned as HTTP 500 from groq via sonnet-llama-groq.
    Hook must intercept and re-raise as a clean HTTPException 400 so the
    client sees a useful diagnostic instead of an opaque server error."""
    from fastapi import HTTPException

    exc = Exception(
        "litellm.BadRequestError: GroqException - "
        "{'error': {'message': 'tool_use_failed', 'type': 'invalid_request_error', "
        "'code': 'tool_use_failed'}}"
    )

    with pytest.raises(HTTPException) as excinfo:
        await repair_handler.async_post_call_failure_hook(
            request_data={},
            original_exception=exc,
            user_api_key_dict=None,
        )

    assert excinfo.value.status_code == 400, (
        "tool_use_failed must surface as 400, not 500 — "
        f"got {excinfo.value.status_code}"
    )
    detail = excinfo.value.detail
    assert isinstance(detail, dict) and "error" in detail
    assert detail["error"].get("code") == "tool_use_failed"


# ---------------------------------------------------------------------------
# Bug 2: streaming iterator yields raw dict → Python repr → JSON parse error
# ---------------------------------------------------------------------------

async def test_bug_streaming_yields_dict_not_pydantic(repair_handler):
    """Originating log: client JSONDecodeError 'Expecting property name
    enclosed in double quotes' when LiteLLM stringified our raw-dict error
    chunk via Python's repr() (single quotes). Synthetic error chunk MUST
    be a ModelResponseStream / StreamingChoices / Delta Pydantic so the
    downstream JSON encoder produces valid JSON."""
    from litellm.types.utils import ModelResponseStream

    async def _erroring_source():
        # Required for async-generator semantics — must yield at least
        # nothing before raising so the iterator hook's `async for` enters.
        if False:
            yield  # pragma: no cover
        raise Exception(
            "OpenAIError: invalid literal for int() with base 10: 'tool_use_failed'"
        )

    yielded = []
    async for chunk in repair_handler.async_post_call_streaming_iterator_hook(
        user_api_key_dict=None,
        response=_erroring_source(),
        request_data={},
    ):
        yielded.append(chunk)

    assert yielded, "Hook must yield a synthetic error chunk, not swallow the error"
    err_chunk = yielded[-1]
    assert not isinstance(err_chunk, dict), (
        "BUG REGRESSED: streaming hook yielded a raw dict — downstream "
        "Python repr() will produce single-quoted JSON that breaks the "
        "client. Must yield a ModelResponseStream Pydantic object."
    )
    assert isinstance(err_chunk, ModelResponseStream), (
        f"Expected ModelResponseStream, got {type(err_chunk).__name__}"
    )


# ---------------------------------------------------------------------------
# Bug 3: chunk-split DSML token leaks across chunks
# ---------------------------------------------------------------------------

async def test_bug_chunk_split_dsml_function_calls(simulate_chunks):
    """Originating log: user saw 'alls' appear in displayed content after
    the upstream sent `<｜DSML｜function_calls X` chopped into chunks
    `<｜DSML｜function_c` + `alls X`. Without a hold-buffer the first chunk's
    `<｜DSML｜function_c` survives the regex (no full delimiter match),
    second chunk's `alls X` has no `｜` so nothing strips it — leaks as
    `<｜DSML｜function_calls X`. With the fix, only ` X` should release."""
    released = await simulate_chunks(["<｜DSML｜function_c", "alls X"])

    assert "<｜DSML｜" not in released, f"DSML head leaked: {released!r}"
    assert "function_c" not in released, f"split-token head leaked: {released!r}"
    assert "alls" not in released, f"split-token tail leaked: {released!r}"
    # Only the trailing real content should remain.
    assert released.strip() == "X", f"expected only 'X', got {released!r}"


# ---------------------------------------------------------------------------
# Bug 4: strip-then-hold ordering — greedy regex eats the partial, tail orphans
# ---------------------------------------------------------------------------

async def test_bug_greedy_regex_strip_eats_partial(simulate_chunks):
    """Originating log: after we added bare-fragment matches (`function_calls?`)
    to fix bug 3, a NEW regression appeared. If `_strip_delimiter_noise` runs
    BEFORE `_longest_partial_delimiter_suffix`, the regex greedily strips the
    partial `<｜DSML｜function_c` from chunk 1 (matches `<｜DSML｜\\w*`),
    leaving nothing to hold. Chunk 2's `alls` then arrives with no preceding
    `｜` to gate on and falls through `_calls?` bare-fragment match too late
    — but only if there's a word boundary. The OBSERVED bug was that
    `alls` (no underscore) doesn't hit `_calls` and leaks raw.

    Correct ordering: hold the partial-prefix tail FIRST, then strip the
    portion to release. The held partial accumulates in the buffer, merges
    with the next chunk's content, and gets recognized as a full delimiter.
    Final released text from this chunk sequence must be empty/whitespace."""
    released = await simulate_chunks(["<｜DSML｜function_c", "alls"])

    assert "alls" not in released, (
        "BUG REGRESSED: greedy strip ate the partial head and `alls` orphaned. "
        f"Released: {released!r}"
    )
    assert "function" not in released, f"head leaked: {released!r}"
    # After flushing the buffer through a final strip, only whitespace (or
    # nothing) should remain.
    assert released.strip() == "", (
        f"expected empty/whitespace after full-delimiter assembly, got {released!r}"
    )
