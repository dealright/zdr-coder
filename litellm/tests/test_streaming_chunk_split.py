"""Streaming chunk-split regression tests for tool_repair.

Exercises ``async_post_call_streaming_iterator_hook`` end-to-end against
``simulate_chunks`` from conftest. Each scenario captures a bug we hit in
production where the DeepSeek-style ``<｜DSML｜...｜>`` delimiter tokens
were split across chunk boundaries — leaking partial fragments (e.g. ``alls``)
into the user-visible content, or letting the greedy strip-regex eat half of
a token before the next chunk had arrived.

These are unit-level integration tests: they drive the hook directly, no
HTTP server required. They are intentionally separate from the non-streaming
content-repair tests (those live in their own file).
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Chunk-split scenarios
#
# Each entry: (test-id, chunks-in, expected-released-text).
# The ``chunks-in`` list is fed one-at-a-time as ``delta.content`` strings;
# the hook is expected to release ``expected-released-text`` (joined across
# all yielded chunks INCLUDING any end-of-stream flush chunk).
# ---------------------------------------------------------------------------
CHUNK_SPLIT_CASES = [
    pytest.param(
        ["commentary.<｜DSML｜function_c", "alls\n\nNext"],
        "commentary.\n\nNext",
        id="split_mid_word_DSML_function_calls",
    ),
    pytest.param(
        ["I'll write it.<｜DSML｜", ""],
        "I'll write it.",
        id="bare_DSML_delimiter_at_end",
    ),
    pytest.param(
        ["Now let me run it:", "function_calls"],
        "Now let me run it:",
        id="standalone_function_calls_fragment_in_own_chunk",
    ),
    pytest.param(
        ["Hello <", "｜DSML｜function_calls and more"],
        "Hello and more",
        id="bare_lt_at_end_assembles_into_full_delimiter",
    ),
    pytest.param(
        ["Hello world", " how are you"],
        "Hello world how are you",
        id="plain_content_negative_no_delimiter",
    ),
]


@pytest.mark.asyncio
@pytest.mark.parametrize("chunks,expected", CHUNK_SPLIT_CASES)
async def test_streaming_releases_clean_content_across_chunk_splits(
    simulate_chunks, chunks, expected
):
    """Streaming hook reassembles & strips DSML delimiters across chunk boundaries."""
    released = await simulate_chunks(chunks)
    assert released == expected, (
        f"chunks={chunks!r} released={released!r} expected={expected!r}"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("chunks,_expected", CHUNK_SPLIT_CASES)
async def test_streaming_hook_does_not_raise(simulate_chunks, chunks, _expected):
    """Streaming hook never propagates exceptions for any chunk-split scenario."""
    # If the hook raises, simulate_chunks would surface it here.
    await simulate_chunks(chunks)


# ---------------------------------------------------------------------------
# Direct-method tests for the partial-delimiter helper. These are not
# strictly chunk-split scenarios per se, but they pin down the contract
# the streaming hook depends on: any tail that is a PREFIX of a known
# delimiter must be held back.
# ---------------------------------------------------------------------------
PARTIAL_SUFFIX_CASES = [
    pytest.param("commentary.<｜DSML｜function_c", 17, id="DSML_function_c_17chars"),
    pytest.param("I'll write it.<｜DSML｜", 7, id="full_DSML_open_token_7chars"),
    pytest.param("Hello <", 1, id="bare_lt_1char"),
    pytest.param("Hello world", 0, id="plain_text_zero_hold"),
    pytest.param("", 0, id="empty_text_zero_hold"),
]


@pytest.mark.parametrize("text,expected_hold", PARTIAL_SUFFIX_CASES)
def test_longest_partial_delimiter_suffix_holds_expected_chars(
    repair_handler, text, expected_hold
):
    """_longest_partial_delimiter_suffix returns the correct hold-back length."""
    assert repair_handler._longest_partial_delimiter_suffix(text) == expected_hold


# ---------------------------------------------------------------------------
# Edge cases the streaming hook must handle without exploding.
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_streaming_handles_none_content_chunks(simulate_chunks):
    """Chunks with delta.content=None (tool_calls-only deltas) pass through silently."""
    released = await simulate_chunks(["Hello", None, " world"])
    assert released == "Hello world"


@pytest.mark.asyncio
async def test_streaming_handles_empty_chunk_stream(simulate_chunks):
    """Zero-chunk stream yields nothing and does not raise."""
    released = await simulate_chunks([])
    assert released == ""


@pytest.mark.asyncio
async def test_streaming_flushes_buffer_at_end_of_stream(simulate_chunks):
    """A trailing partial-delimiter that never resolves gets flushed (after final strip)."""
    # `<｜DSML｜` is a complete delimiter — held back as a partial through the
    # stream, then stripped clean at end-of-stream flush, so nothing leaks.
    released = await simulate_chunks(["Goodbye.", "<｜DSML｜"])
    assert released == "Goodbye."


@pytest.mark.asyncio
async def test_streaming_preserves_identifier_with_function_calls_substring(
    simulate_chunks,
):
    """The bare-fragment regex must NOT eat ``function_calls`` inside an identifier."""
    released = await simulate_chunks(
        ["use legitimate_", "function_calls_to_make here"]
    )
    assert released == "use legitimate_function_calls_to_make here"
