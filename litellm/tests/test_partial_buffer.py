"""Unit tests for ToolRepairHandler._longest_partial_delimiter_suffix.

This helper is the keystone of the streaming hook's chunk-split delimiter
handling: it returns the length N of the longest trailing suffix of `text`
that is ALSO a prefix of any known delimiter token in `_DELIMITER_PREFIXES`.
The streaming hook holds back text[-N:] until the next chunk arrives so a
delimiter being assembled across a chunk boundary (e.g. `<｜DSML｜function_c`
+ `alls`) is never released to the client mid-token.

We own the buffer-state coverage; tool-call repair, regex strip, success
hook, and failure hook live in sibling test files.
"""

from __future__ import annotations

import pytest

from tool_repair import ToolRepairHandler


# ---------------------------------------------------------------------------
# Parametrized expected lengths for the canonical chunk-split scenarios.
#
# Each tuple is (text_input, expected_held_chars). The held chars are the ones
# the streaming hook will defer to the next chunk. The trailing-character count
# was computed against the actual `_DELIMITER_PREFIXES` tuple — DO NOT
# hand-tweak without running the helper to verify.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "text,expected",
    [
        # `<` is the first char of every `<｜...` and `<|...` delimiter, so any
        # trailing `<` must be held back.
        ("Hello <", 1),
        # `<｜` (U+FF5C) is the unique DeepSeek 2-char prefix.
        ("Hello <｜", 2),
        # `<｜D` matches the prefix of `<｜DSML｜...`.
        ("Hello <｜D", 3),
        # `<｜DSML` = 6 chars, prefix of `<｜DSML｜` and `<｜DSML｜function_calls`.
        ("Hello <｜DSML", 6),
        # `<｜DSML｜` = 7 chars, full short prefix.
        ("Hello <｜DSML｜", 7),
        # `<｜DSML｜function_c` = 17 chars, prefix of `<｜DSML｜function_calls`.
        # This is the EXACT chunk-split that triggered bug #3/#4 — the partial
        # MUST be held back so it doesn't get regex-stripped half-formed.
        ("Hello <｜DSML｜function_c", 17),
        # `<｜DSML｜function_calls` is the full 21-char delimiter prefix
        # (without the closing `｜>`).
        ("Hello <｜DSML｜function_calls", 21),
        # `<｜tool` = 6 chars, prefix of `<｜tool▁calls▁begin｜>` etc.
        ("Hello <｜tool", 6),
        # `<｜tool▁calls▁begin` = 18 chars, almost-full DeepSeek tool delimiter.
        ("Hello <｜tool▁calls▁begin", 18),
        # Plain text — no held bytes.
        ("Hello world", 0),
        # `_c` is NOT a delimiter prefix (delimiters start with `<`). It IS a
        # noise FRAGMENT the regex strips post-release, but the partial-suffix
        # detector should not hold it back.
        ("Hello _c", 0),
        # Empty string — guard clause returns 0 immediately.
        ("", 0),
    ],
)
def test_longest_partial_delimiter_suffix_returns_expected_length(text, expected):
    """Trailing-suffix length matches the longest delimiter-prefix overlap."""
    assert ToolRepairHandler._longest_partial_delimiter_suffix(text) == expected


def test_longest_partial_delimiter_suffix_none_text_returns_zero(repair_handler):
    """A None/empty input is handled by the guard without raising."""
    assert repair_handler._longest_partial_delimiter_suffix("") == 0


def test_longest_partial_delimiter_suffix_no_trailing_match_returns_zero(repair_handler):
    """Text containing a delimiter mid-string but ending in plain content holds 0."""
    # Delimiter sits in the middle; the trailing chars are not a delimiter prefix.
    text = "before <｜DSML｜ after"
    assert repair_handler._longest_partial_delimiter_suffix(text) == 0


def test_longest_partial_delimiter_suffix_prefers_longest_match(repair_handler):
    """When multiple delimiters share a tail prefix, the longest one wins."""
    # `<｜DSML` is a 6-char overlap with both `<｜DSML｜` (7) and the longer
    # `<｜DSML｜function_calls` (21). The helper must pick the longest possible
    # suffix-AS-prefix length across all known delimiters.
    text = "junk <｜DSML"
    # Both candidates have `<｜DSML` as a 6-char prefix; no longer overlap is
    # possible from this input, so the result is 6.
    assert repair_handler._longest_partial_delimiter_suffix(text) == 6


# ---------------------------------------------------------------------------
# Function-level guarantees: the returned N must always satisfy
# `text[-N:] is a prefix of SOME delimiter in _DELIMITER_PREFIXES`.
# This is the contract the streaming hook depends on. If it ever breaks,
# the buffer can leak garbage to the client.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "text",
    [
        "Hello <",
        "Hello <｜",
        "Hello <｜D",
        "Hello <｜DSML",
        "Hello <｜DSML｜",
        "Hello <｜DSML｜function_c",
        "Hello <｜DSML｜function_calls",
        "Hello <｜tool",
        "Hello <｜tool▁calls▁begin",
        "Hello <|tool_calls",
        "Hello <|function_calls",
        "Hello <|begin_of_function",
    ],
)
def test_held_suffix_is_prefix_of_some_known_delimiter(text):
    """For any positive N returned, text[-N:] is a prefix of a known delimiter."""
    n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
    assert n > 0, f"Expected a positive hold for {text!r}"
    held = text[-n:]
    matches = [d for d in ToolRepairHandler._DELIMITER_PREFIXES if d.startswith(held)]
    assert matches, (
        f"Held suffix {held!r} (n={n}) is not a prefix of any known delimiter; "
        f"streaming hook would leak it to the client."
    )


@pytest.mark.parametrize(
    "text",
    [
        "Hello world",
        "Hello _c",
        "",
        "completely benign content",
        "trailing whitespace   ",
        "no angle bracket here at all",
    ],
)
def test_zero_hold_means_no_delimiter_prefix_overlap(text):
    """When the helper returns 0, no non-empty suffix should match any prefix."""
    n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
    assert n == 0
    # Confirm the contract from the other side: there is genuinely no delimiter
    # whose non-empty prefix the text ends with. (We test up to len(delim)
    # trailing chars per delimiter — same range the helper searches.)
    for delim in ToolRepairHandler._DELIMITER_PREFIXES:
        limit = min(len(text), len(delim))
        for i in range(1, limit + 1):
            assert not text.endswith(delim[:i]), (
                f"Helper returned 0 but text ends with delimiter prefix {delim[:i]!r}"
            )


def test_held_length_never_exceeds_text_length():
    """The held suffix length must be bounded by the input length."""
    for text in ["", "<", "<｜", "<｜DSML｜function_c"]:
        n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
        assert 0 <= n <= len(text)


def test_held_length_never_exceeds_longest_delimiter():
    """N is bounded above by the longest delimiter's length."""
    longest = max(len(d) for d in ToolRepairHandler._DELIMITER_PREFIXES)
    # Stuff a long text in — even if every char looked like a delimiter prefix,
    # the helper cannot return more than the longest known delimiter's length.
    text = "x" * (longest * 3) + "<｜DSML｜function_calls"
    n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
    assert n <= longest


def test_full_delimiter_in_text_is_held_back():
    """A fully-formed `<｜DSML｜function_calls` at end of text is held entirely.

    Rationale: even when the delimiter is complete, the helper can't know
    whether the NEXT chunk extends it (e.g. into `<｜DSML｜function_calls｜>`
    or a longer variant), so it holds the largest-overlap suffix. The
    downstream regex strip handles the actual removal once enough has buffered.
    """
    text = "content <｜DSML｜function_calls"
    n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
    # 21 chars = full `<｜DSML｜function_calls` prefix.
    assert n == 21
    assert text[-n:] == "<｜DSML｜function_calls"


def test_ascii_pipe_variants_also_detected():
    """ASCII `<|...|>` variants (Llama-style) are also held when partial."""
    # `<|tool_calls` is a 12-char prefix of `<|tool_calls|>`.
    text = "blob <|tool_calls"
    n = ToolRepairHandler._longest_partial_delimiter_suffix(text)
    assert n == len("<|tool_calls")
    assert text[-n:] == "<|tool_calls"
