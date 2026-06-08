"""LiteLLM tool-call repair hook for the zdr-coder proxy.

Three jobs:

  1. Catch Groq's `tool_use_failed` error response on NON-STREAMING requests
     so LiteLLM's int-parse doesn't crash. Groq returns that as a STRING error
     code; LiteLLM's Groq adapter tries to int() it and raises ValueError,
     surfacing as HTTP 500 "invalid literal for int() with base 10:
     'tool_use_failed'". This hook re-raises as a clean HTTP 400.

  2. Same fix for STREAMING requests via the iterator-wrapping hook. The
     non-streaming failure hook doesn't fire for streaming because the error
     is raised inside the Groq chunk_parser mid-stream; the iterator hook
     wraps the generator and converts the exception into a graceful end-of-
     stream chunk so the client sees a clean error message instead of HTTP
     500. Must yield a real ModelResponseStream object (NOT a raw dict) or
     downstream serialization produces Python repr with single quotes, which
     breaks the client's JSON parser.

  3. Repair malformed tool calls in SUCCESSFUL non-streaming responses. Some
     weak tool-using models occasionally emit the tool call as raw text in
     `message.content` instead of using the OpenAI `tool_calls[]` protocol.
     We scan for the four common malformed shapes and rewrite into a proper
     tool_calls block.

Wired in litellm/config.yaml as:
    litellm_settings:
      callbacks: tool_repair.tool_repair_handler

Mounted into the container by docker-compose.yml at /app/tool_repair.py.
"""

import json
import re
import time
import uuid

from litellm.integrations.custom_logger import CustomLogger

# fastapi.HTTPException is what LiteLLM proxy expects for clean error responses
try:
    from fastapi import HTTPException
except ImportError:
    HTTPException = None

# LiteLLM stream types so the iterator hook yields properly-serialized objects
try:
    from litellm.types.utils import ModelResponseStream, StreamingChoices, Delta
except ImportError:
    ModelResponseStream = None
    StreamingChoices = None
    Delta = None


class ToolRepairHandler(CustomLogger):
    # Regex patterns for the malformed tool-call shapes observed from weak models.
    # Ordered most-specific to least-specific so the right one matches first.
    _PATTERNS = [
        # Hermes/Qwen XML: <tool_call>{"name": "x", "arguments": {...}}</tool_call>
        (re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.DOTALL), "hermes_xml"),
        # Llama 3.x JSON: <|python_tag|>{"name": "x", "parameters": {...}}
        (re.compile(r"<\|python_tag\|>\s*(\{.*?\})\s*$", re.DOTALL), "llama_json"),
        # Llama 3.3 70B raw key=val: web_search={"query": "..."}
        (re.compile(r"^(\w+)\s*=\s*(\{.*\})\s*$", re.DOTALL), "raw_kv"),
        # Pythonic list: [web_search(query="...", engine="x")]
        (re.compile(r"\[(\w+)\((.*?)\)\]\s*$", re.DOTALL), "pythonic"),
    ]

    # Provider-specific tool-call delimiter tokens that leak into message.content
    # when the upstream's tool-call parser strips structured calls into tool_calls[]
    # but doesn't fully clean the surrounding text. The chars `｜` are U+FF5C
    # (full-width vertical bar) which DeepSeek and others use as delimiters.
    # Stripping these keeps the displayed content clean in the UI.
    #
    # CRITICAL: streaming chunks split these tokens across deltas. The token
    # `<｜DSML｜function_calls` may arrive split as e.g. `<｜DSML｜function`
    # then `_calls\n...`. The first chunk's regex eats `<｜DSML｜function`,
    # leaving `_calls` to leak in the next chunk where there's no `｜` to gate
    # on. So we ALSO match bare-fragment forms (`_calls`, `function_calls`)
    # that appear at content boundaries — a small false-positive risk we accept.
    _DELIMITER_NOISE = re.compile(
        r"(?:"
        # Full DSML forms (with ｜)
        r"<｜DSML｜\w*(?:｜>)?|"
        # DeepSeek alt-format begin/end markers (with ｜)
        r"<｜(?:tool|function)[▁_]?(?:calls?|call)[▁_]?(?:begin|end)｜>|"
        # ASCII pipe variants
        r"<\|(?:tool_calls?|begin_of_function|end_of_function|"
        r"function_calls?|end_function_calls?)\|>|"
        # Bare fragments at boundaries (from chunk-split DSML tokens).
        # `(?<![A-Za-z0-9_])` = not preceded by identifier char (so we don't
        # eat the `function_calls` *inside* `legitimate_function_calls_to_make`).
        # `(?![A-Za-z0-9_])` = not followed by identifier char (so we don't eat
        # `_callstack`). The fragment must sit at a real sentence boundary.
        r"(?<![A-Za-z0-9_])(?:end_)?function_calls?(?![A-Za-z0-9_])|"
        r"(?<![A-Za-z0-9_])_calls?(?![A-Za-z0-9_])"
        r")",
        re.IGNORECASE,
    )

    @classmethod
    def _strip_delimiter_noise(cls, text):
        """Remove provider-specific tool-call delimiter tokens from content.
        E.g. DeepSeek V3.2's `<｜DSML｜function_calls` leaks alongside the
        structured tool_calls[] that Bedrock extracted."""
        if not text or not isinstance(text, str):
            return text
        cleaned = cls._DELIMITER_NOISE.sub("", text)
        # Also clean up any orphaned trailing newlines / whitespace that
        # the delimiter left behind.
        return cleaned.rstrip(" \n\t")

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict
    ):
        """NON-STREAMING failure path. Convert Groq's `tool_use_failed` (string
        code) into a clean 400 before LiteLLM's downstream int-parse trips on it."""
        err_str = str(original_exception)
        if "tool_use_failed" in err_str or "invalid literal for int" in err_str:
            if HTTPException is not None:
                raise HTTPException(
                    status_code=400,
                    detail={
                        "error": {
                            "message": (
                                "Upstream provider rejected a malformed tool call "
                                "(error: tool_use_failed). The model emitted a tool "
                                "call that didn't match the declared tools schema. "
                                "Retry with simpler tool args or a different model."
                            ),
                            "type": "tool_use_failed",
                            "code": "tool_use_failed",
                            "upstream": err_str[:300],
                        }
                    },
                )
        # Anything else: propagate normally.
        raise original_exception

    # Known delimiter-token PREFIXES — used to detect when a chunk's content
    # tail might be the start of a delimiter still being assembled across
    # streaming chunks. If we see content ending with any prefix of these,
    # we hold those tail chars back until we have enough to disambiguate.
    _DELIMITER_PREFIXES = (
        "<｜DSML｜end_function_calls｜>",
        "<｜DSML｜function_calls",
        "<｜DSML｜",
        "<｜tool▁calls▁begin｜>",
        "<｜tool▁calls▁end｜>",
        "<｜tool▁call▁begin｜>",
        "<｜tool▁call▁end｜>",
        "<｜function_calls｜>",
        "<｜end_function_calls｜>",
        "<|tool_calls|>",
        "<|function_calls|>",
        "<|end_function_calls|>",
        "<|begin_of_function|>",
        "<|end_of_function|>",
    )

    @classmethod
    def _longest_partial_delimiter_suffix(cls, text):
        """Return the length of the longest suffix of `text` that is also a
        prefix of any known delimiter token. We hold that many trailing chars
        back from release because they MIGHT be the start of a delimiter being
        assembled across the next chunk(s).
        """
        if not text:
            return 0
        max_held = 0
        for delim in cls._DELIMITER_PREFIXES:
            limit = min(len(text), len(delim))
            for i in range(limit, 0, -1):
                if text.endswith(delim[:i]):
                    if i > max_held:
                        max_held = i
                    break
        return max_held

    async def async_post_call_streaming_iterator_hook(
        self, user_api_key_dict, response, request_data
    ):
        """STREAMING path: two jobs.

        (1) Catch OpenAIError tool_use_failed / int-parse so LiteLLM's int-cast
            doesn't crash the stream with HTTP 500. The non-streaming failure
            hook above does NOT fire here — streaming errors come through the
            chunk iterator, so we wrap and trap them here.

        (2) Strip provider-specific delimiter tokens (DeepSeek's `<｜DSML｜...`)
            that leak into content alongside parsed tool_calls[]. These tokens
            split across streaming chunks at character boundaries, so we
            maintain a per-stream BUFFER: each chunk's content gets prepended
            with any held-back tail from the previous chunk, gets stripped of
            known full delimiters, then has its longest tail-prefix-of-a-known-
            delimiter re-buffered for the next chunk. At end-of-stream we flush
            whatever's left (with a final strip).
        """
        buffer = ""  # carry-over tail that might be a partial delimiter
        try:
            async for chunk in response:
                try:
                    choices = self._get(chunk, "choices")
                    if choices:
                        for choice in choices:
                            delta = self._get(choice, "delta")
                            if delta is None:
                                continue
                            content = self._get(delta, "content")
                            if content and isinstance(content, str):
                                # ORDER MATTERS: hold PARTIAL delimiters BEFORE
                                # running the strip regex. Otherwise the regex
                                # greedily matches partial forms like
                                # `<｜DSML｜function_c` (eating `function_c`)
                                # and the next chunk's tail `alls` arrives
                                # without enough context to recognize.
                                merged = buffer + content
                                buffer = ""
                                hold = self._longest_partial_delimiter_suffix(merged)
                                if hold > 0:
                                    buffer = merged[-hold:]
                                    to_release = merged[:-hold]
                                else:
                                    to_release = merged
                                cleaned = self._strip_delimiter_noise(to_release)
                                if cleaned != content:
                                    self._set(delta, "content", cleaned)
                except Exception:
                    pass
                yield chunk

            # End of stream — flush any held-back buffer through a final strip.
            # Whatever survives is real content that just happened to be
            # tail-similar to a delimiter prefix.
            if buffer and ModelResponseStream is not None:
                final = self._strip_delimiter_noise(buffer)
                if final:
                    flush_chunk = ModelResponseStream(
                        id="chatcmpl-tool-repair-flush",
                        created=int(time.time()),
                        model="tool-repair",
                        choices=[
                            StreamingChoices(
                                index=0,
                                delta=Delta(content=final),
                                finish_reason=None,
                            )
                        ],
                    )
                    yield flush_chunk
        except Exception as e:
            err_str = str(e)
            if "tool_use_failed" in err_str or "invalid literal for int" in err_str:
                # Yield a PROPER ModelResponseStream (Pydantic model). Yielding a
                # raw dict here causes downstream str() to produce Python repr
                # with single quotes, which breaks the client's JSON parser
                # ("Expecting property name enclosed in double quotes").
                #
                # Surface the error as assistant content + finish_reason=stop so
                # the conversation ends gracefully and the user sees a useful
                # diagnostic message. Adding `error` field too — OpenAI clients
                # that branch on it will pick it up.
                msg = (
                    "⚠️ Upstream provider rejected a malformed tool call "
                    "(error: tool_use_failed). The model emitted a tool call "
                    "that didn't match the declared tools schema. "
                    "Try fewer tools registered, simpler args, a stronger "
                    "model (sonnet-llama → Cerebras Qwen3-Coder), or self-host "
                    "(sonnet-pod → GLM-4.5-Air)."
                )
                if ModelResponseStream is not None:
                    err_chunk = ModelResponseStream(
                        id="chatcmpl-tool-repair-err",
                        created=int(time.time()),
                        model="tool-repair",
                        choices=[
                            StreamingChoices(
                                index=0,
                                delta=Delta(role="assistant", content=msg),
                                finish_reason="stop",
                            )
                        ],
                    )
                    yield err_chunk
                return
            raise

    async def async_post_call_success_hook(
        self, data, user_api_key_dict, response
    ):
        """If a response's message.content looks like a malformed tool call,
        rewrite into message.tool_calls[] and clear message.content."""
        try:
            choices = self._get(response, "choices")
            if not choices:
                return response
            for choice in choices:
                msg = self._get(choice, "message")
                if not msg:
                    continue
                content = self._get(msg, "content")
                existing = self._get(msg, "tool_calls")
                # If structured tool_calls were already parsed by the adapter
                # but leaked-delimiter tokens are sitting in content, clean them.
                if existing and content and isinstance(content, str) and "｜" in content:
                    cleaned = self._strip_delimiter_noise(content)
                    if cleaned != content:
                        self._set(msg, "content", cleaned or None)
                    continue
                if not content or existing:
                    continue
                call = self._extract(content)
                if not call:
                    continue
                self._set(msg, "tool_calls", [call])
                self._set(msg, "content", None)
                self._set(choice, "finish_reason", "tool_calls")
        except Exception:
            # Repair is best-effort. Never break the response on a regex glitch.
            pass
        return response

    @staticmethod
    def _get(obj, key, default=None):
        if isinstance(obj, dict):
            return obj.get(key, default)
        return getattr(obj, key, default)

    @staticmethod
    def _set(obj, key, val):
        if isinstance(obj, dict):
            obj[key] = val
        else:
            setattr(obj, key, val)

    def _extract(self, content):
        text = content.strip()
        for pattern, kind in self._PATTERNS:
            m = pattern.search(text)
            if not m:
                continue
            try:
                if kind == "hermes_xml":
                    obj = json.loads(m.group(1))
                    name = obj.get("name")
                    args = obj.get("arguments") or obj.get("parameters") or {}
                elif kind == "llama_json":
                    obj = json.loads(m.group(1))
                    name = obj.get("name")
                    args = obj.get("parameters") or obj.get("arguments") or {}
                elif kind == "raw_kv":
                    name = m.group(1)
                    args = json.loads(m.group(2))
                elif kind == "pythonic":
                    name = m.group(1)
                    args = self._parse_pythonic(m.group(2))
                else:
                    continue
                if not name:
                    continue
                return {
                    "id": "call_" + uuid.uuid4().hex[:12],
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": json.dumps(args if isinstance(args, dict) else {}),
                    },
                }
            except (json.JSONDecodeError, ValueError):
                continue
        return None

    @staticmethod
    def _parse_pythonic(arg_str):
        if not arg_str.strip():
            return {}
        out = {}
        for k, v in re.findall(
            r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|[^,\s]+)',
            arg_str,
        ):
            v = v.strip()
            if (v.startswith('"') and v.endswith('"')) or (
                v.startswith("'") and v.endswith("'")
            ):
                v = v[1:-1]
            else:
                for cast in (int, float):
                    try:
                        v = cast(v)
                        break
                    except ValueError:
                        continue
            out[k] = v
        return out


# Singleton instance — referenced from litellm/config.yaml's callbacks setting.
tool_repair_handler = ToolRepairHandler()
