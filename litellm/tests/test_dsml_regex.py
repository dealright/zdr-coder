"""Unit tests for ToolRepairHandler._strip_delimiter_noise.

The regex must aggressively strip DeepSeek/DSML delimiter tokens (and the bare
fragments that leak when those tokens get chunk-split) while NOT damaging
normal English prose or legitimate snake_case identifiers that happen to
contain `function_calls` / `_calls` substrings.

The ｜ chars below are U+FF5C (full-width vertical bar) — what DeepSeek uses.
The ▁ chars are U+2581 (lower one eighth block) — used in tokenizer-style
delimiters like `<｜tool▁calls▁begin｜>`.
"""

from __future__ import annotations

import pytest

from tool_repair import ToolRepairHandler


# --------------------------------------------------------------------------
# Cases the regex MUST STRIP. Each is (label, input_text, expected_output).
# Expected output already accounts for `_strip_delimiter_noise`'s trailing
# `.rstrip(" \n\t")` cleanup.
# --------------------------------------------------------------------------
STRIP_CASES = [
    pytest.param(
        "Hello there.<｜DSML｜function_calls",
        "Hello there.",
        id="strips_full_dsml_function_calls",
    ),
    pytest.param(
        "Hello there.<｜DSML｜",
        "Hello there.",
        id="strips_bare_dsml_no_trailing_word",
    ),
    pytest.param(
        "Here are the results. function_calls",
        "Here are the results.",
        id="strips_trailing_function_calls_at_sentence_boundary",
    ),
    pytest.param(
        "Here are the results._calls",
        "Here are the results.",
        id="strips_trailing_underscore_calls_after_dot",
    ),
    pytest.param(
        "Stack Overflow.function_calls",
        "Stack Overflow.",
        id="strips_function_calls_after_dot_no_space",
    ),
    pytest.param(
        "Wrapping up <｜tool▁calls▁begin｜> here",
        "Wrapping up  here",
        id="strips_deepseek_tool_calls_begin",
    ),
    pytest.param(
        "Wrapping up <｜tool▁calls▁end｜> here",
        "Wrapping up  here",
        id="strips_deepseek_tool_calls_end",
    ),
    pytest.param(
        "Done <|tool_calls|>",
        "Done",
        id="strips_ascii_pipe_tool_calls",
    ),
    pytest.param(
        "Done <|tool_call|>",
        "Done",
        id="strips_ascii_pipe_tool_call_singular",
    ),
    pytest.param(
        "Done <|function_calls|>",
        "Done",
        id="strips_ascii_pipe_function_calls",
    ),
    pytest.param(
        "Done <|end_function_calls|>",
        "Done",
        id="strips_ascii_pipe_end_function_calls",
    ),
    pytest.param(
        "<｜DSML｜function_calls at start",
        " at start",
        id="strips_dsml_at_start_of_string",
    ),
    pytest.param(
        "leading text.end_function_calls",
        "leading text.",
        id="strips_bare_end_function_calls_at_boundary",
    ),
]


# --------------------------------------------------------------------------
# Cases the regex MUST LEAVE ALONE. Each is (label, input_text). The output
# must equal the input (modulo the unconditional trailing-whitespace rstrip).
# --------------------------------------------------------------------------
PRESERVE_CASES = [
    pytest.param(
        "I want to discuss function calls in Python",
        id="preserves_plain_english_with_space",
    ),
    pytest.param(
        "use legitimate_function_calls_to_make safely",
        id="preserves_snake_case_identifier_with_function_calls",
    ),
    pytest.param(
        "my _callstack value is interesting",
        id="preserves_underscore_callstack_word",
    ),
    pytest.param(
        "see content_calls here",
        id="preserves_content_calls_preceded_by_letter",
    ),
    pytest.param(
        "Look at recursive_calls in the trace",
        id="preserves_recursive_calls_identifier",
    ),
    pytest.param(
        "Refer to my_function_call variable",
        id="preserves_my_function_call_identifier",
    ),
]


@pytest.mark.parametrize("text,expected", STRIP_CASES)
def test_strip_delimiter_noise_removes_known_tokens(text, expected):
    """Delimiter tokens and chunk-split fragments at sentence boundaries are removed."""
    assert ToolRepairHandler._strip_delimiter_noise(text) == expected


@pytest.mark.parametrize("text", PRESERVE_CASES)
def test_strip_delimiter_noise_preserves_legit_text(text):
    """Plain English and snake_case identifiers are NOT damaged by the regex."""
    # The function unconditionally rstrips trailing whitespace, so compare to that.
    assert ToolRepairHandler._strip_delimiter_noise(text) == text.rstrip(" \n\t")


def test_strip_delimiter_noise_handles_empty_string():
    """Empty input returns the empty input unchanged (no crash)."""
    assert ToolRepairHandler._strip_delimiter_noise("") == ""


def test_strip_delimiter_noise_handles_none():
    """None input is passed through (the hook calls this on optional content)."""
    assert ToolRepairHandler._strip_delimiter_noise(None) is None


def test_strip_delimiter_noise_handles_non_string():
    """Non-string input is returned unchanged (defensive guard)."""
    assert ToolRepairHandler._strip_delimiter_noise(123) == 123


def test_strip_delimiter_noise_strips_multiple_occurrences():
    """Multiple delimiter tokens in one string are all stripped."""
    text = "Start <|tool_calls|> middle <|function_calls|> end"
    assert ToolRepairHandler._strip_delimiter_noise(text) == "Start  middle  end"


def test_strip_delimiter_noise_is_case_insensitive():
    """The regex carries re.IGNORECASE, so mixed-case fragments match too."""
    text = "Done.FUNCTION_CALLS"
    assert ToolRepairHandler._strip_delimiter_noise(text) == "Done."


def test_strip_delimiter_noise_rstrips_trailing_whitespace_left_behind():
    """After removing a trailing delimiter, dangling spaces/newlines get cleaned."""
    text = "Hello there.   <｜DSML｜function_calls   \n"
    assert ToolRepairHandler._strip_delimiter_noise(text) == "Hello there."
