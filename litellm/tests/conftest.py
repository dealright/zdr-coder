"""Pytest configuration + shared fixtures for tool_repair tests.

Ensures the tool_repair module can be imported by adding the parent litellm/
directory to sys.path before any test collection. Provides fixtures for the
handler under test, the local LiteLLM proxy URL/key, and a streaming-chunk
simulator that exercises the iterator hook without needing a real HTTP server.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Iterable

import pytest

# Make /Users/dylansnow/Work/zdr-coder/litellm/ importable so `import tool_repair`
# resolves to the module that's mounted into the LiteLLM container at /app/.
_LITELLM_DIR = Path(__file__).resolve().parent.parent
if str(_LITELLM_DIR) not in sys.path:
    sys.path.insert(0, str(_LITELLM_DIR))

# Provide a stub for litellm.integrations.custom_logger.CustomLogger if litellm
# isn't installed in the test environment. The real CustomLogger is just a base
# class with no-op hooks; a SimpleNamespace-style stub is enough for unit tests.
try:
    import litellm.integrations.custom_logger  # noqa: F401
except ImportError:  # pragma: no cover — only triggers if litellm absent
    import types

    fake_litellm = types.ModuleType("litellm")
    fake_integrations = types.ModuleType("litellm.integrations")
    fake_custom_logger = types.ModuleType("litellm.integrations.custom_logger")

    class _StubCustomLogger:  # minimal base class
        pass

    fake_custom_logger.CustomLogger = _StubCustomLogger
    fake_types = types.ModuleType("litellm.types")
    fake_types_utils = types.ModuleType("litellm.types.utils")

    # Lightweight stand-ins for the streaming model types — just hold attrs.
    class _Delta:
        def __init__(self, role=None, content=None, **kwargs):
            self.role = role
            self.content = content
            for k, v in kwargs.items():
                setattr(self, k, v)

    class _StreamingChoices:
        def __init__(self, index=0, delta=None, finish_reason=None, **kwargs):
            self.index = index
            self.delta = delta
            self.finish_reason = finish_reason
            for k, v in kwargs.items():
                setattr(self, k, v)

    class _ModelResponseStream:
        def __init__(self, id=None, created=None, model=None, choices=None, **kwargs):
            self.id = id
            self.created = created
            self.model = model
            self.choices = choices or []
            for k, v in kwargs.items():
                setattr(self, k, v)

    fake_types_utils.Delta = _Delta
    fake_types_utils.StreamingChoices = _StreamingChoices
    fake_types_utils.ModelResponseStream = _ModelResponseStream

    sys.modules.setdefault("litellm", fake_litellm)
    sys.modules.setdefault("litellm.integrations", fake_integrations)
    sys.modules.setdefault("litellm.integrations.custom_logger", fake_custom_logger)
    sys.modules.setdefault("litellm.types", fake_types)
    sys.modules.setdefault("litellm.types.utils", fake_types_utils)


def _make_chunk(content: str | None):
    """Build a minimal streaming chunk that looks like a ModelResponseStream
    enough for tool_repair's `_get(chunk, 'choices')` / `_get(choice, 'delta')`
    / `_get(delta, 'content')` traversal."""
    delta = SimpleNamespace(role=None, content=content)
    choice = SimpleNamespace(index=0, delta=delta, finish_reason=None)
    return SimpleNamespace(
        id="chatcmpl-test",
        created=0,
        model="test-model",
        choices=[choice],
    )


@pytest.fixture
def repair_handler():
    """Fresh ToolRepairHandler per test — avoids any cross-test buffer leak."""
    from tool_repair import ToolRepairHandler

    return ToolRepairHandler()


@pytest.fixture(scope="session")
def litellm_url() -> str:
    """Session-scoped so module-scoped fixtures (like e2e's proxy_or_skip) can
    depend on it without triggering pytest's ScopeMismatch error."""
    return "http://localhost:4000"


@pytest.fixture(scope="session")
def litellm_key() -> str:
    """Read the local LiteLLM master key. Skips integration tests if absent.
    Session-scoped for the same reason as litellm_url."""
    path = Path("/Users/dylansnow/Work/zdr-coder/.litellm-key")
    if not path.exists():
        pytest.skip(f"missing {path} — skipping integration test")
    return path.read_text().strip()


@pytest.fixture
def simulate_chunks(repair_handler):
    """Async helper: feed a list of delta-content strings into the streaming
    hook and return the released content as a single concatenated string.

    Usage:
        released = await simulate_chunks(["foo", "bar"])
    """

    async def _run(contents: Iterable[str | None]) -> str:
        async def _source():
            for c in contents:
                yield _make_chunk(c)

        out_parts: list[str] = []
        async for released_chunk in repair_handler.async_post_call_streaming_iterator_hook(
            user_api_key_dict=None,
            response=_source(),
            request_data={},
        ):
            try:
                choices = released_chunk.choices
            except AttributeError:
                choices = released_chunk.get("choices") if isinstance(released_chunk, dict) else None
            if not choices:
                continue
            for ch in choices:
                delta = getattr(ch, "delta", None) or (ch.get("delta") if isinstance(ch, dict) else None)
                if delta is None:
                    continue
                content = getattr(delta, "content", None)
                if content is None and isinstance(delta, dict):
                    content = delta.get("content")
                if content:
                    out_parts.append(content)
        return "".join(out_parts)

    return _run


# Re-export the helper for tests that want to build their own chunks.
make_chunk = _make_chunk

# Mark all tests in this directory as asyncio by default — pytest-asyncio's
# auto mode (set in pytest.ini) handles this, but be explicit if the plugin
# is missing.
collect_ignore_glob: list[str] = []

if os.environ.get("TOOL_REPAIR_TEST_DEBUG"):  # opt-in trace output
    import logging

    logging.basicConfig(level=logging.DEBUG)
