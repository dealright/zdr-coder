"""Static validation tests for the sky/*.yaml SkyPilot configs.

These tests are pure YAML inspection — they do NOT launch pods, call the sky CLI,
or hit any network. The intent is to catch drift between the documented
model/parser pairings and the actual YAML so a typo in `--tool-call-parser` or a
flipped `--served-model-name` is surfaced at CI time instead of after a
multi-minute pod boot.

Coverage owned by THIS file (and only this file):
  * YAML parses cleanly
  * Required top-level keys present (`name` for pods, `service` for serverless)
  * Docker image pinned to `docker:vllm/vllm-openai:*`
  * vLLM port == 8080
  * Run block uses `python3 -m vllm` (regression — we got bitten by `python `)
  * Run block sets `--served-model-name <expected>` matching the file's tier
  * Pods using new models declare the correct `--tool-call-parser`. NOTE:
    these names are the vLLM v0.10.0 actual choices (verified against the
    api_server.py --tool-call-parser argparse list). Newer names like
    `qwen3_xml` / `glm45` / `deepseek_v31` exist in vLLM main but NOT in 0.10.0.
    Bump these when we bump the docker image tag.
      haiku-pod/haiku-serve   -> qwen3_coder
      sonnet-pod/sonnet-serve -> glm4_moe
      opus-pod/opus-serve     -> deepseek_v3
  * `stage-opus-weights.yaml` references DeepSeek-V4-Pro (current opus weights)

Other test files (`test_dsml_regex.py`, `test_failure_hook.py`,
`test_partial_buffer.py`, `test_streaming_chunk_split.py`,
`test_success_hook.py`) cover the tool_repair handler itself — this one is
deliberately scoped to sky YAML lint only.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml


# Resolve sky/ at import time so pytest collection errors are loud (instead of
# every parametrized case failing with the same FileNotFoundError).
SKY_DIR = Path("/Users/dylansnow/Work/zdr-coder/sky")

# Pods/serves that must carry full vLLM serving config. `smoke-test` and
# `stage-opus-weights` are intentionally excluded — neither serves a model.
SERVING_YAMLS = [
    "haiku-pod.yaml",
    "haiku-serve.yaml",
    "sonnet-pod.yaml",
    "sonnet-serve.yaml",
    "opus-pod.yaml",
    "opus-serve.yaml",
]

# Expected tool-call parser per tier — must match the model family's vLLM parser.
# Drift here is the #1 reason agentic clients silently get raw text instead of
# OpenAI tool_calls[].
EXPECTED_PARSER = {
    "haiku-pod.yaml": "qwen3_coder",
    "haiku-serve.yaml": "qwen3_coder",
    "sonnet-pod.yaml": "glm4_moe",
    "sonnet-serve.yaml": "glm4_moe",
    "opus-pod.yaml": "deepseek_v3",
    "opus-serve.yaml": "deepseek_v3",
}

# served-model-name should equal the filename stem so LiteLLM's config.yaml
# routing (`model: openai/haiku-pod` etc.) lands on the right vLLM endpoint.
EXPECTED_SERVED_NAME = {
    "haiku-pod.yaml": "haiku-pod",
    "haiku-serve.yaml": "haiku-serve",
    "sonnet-pod.yaml": "sonnet-pod",
    "sonnet-serve.yaml": "sonnet-serve",
    "opus-pod.yaml": "opus-pod",
    "opus-serve.yaml": "opus-serve",
}

ALL_YAMLS = SERVING_YAMLS + ["smoke-test.yaml", "stage-opus-weights.yaml"]


def _load(name: str) -> dict:
    """Load a sky/<name> YAML file, failing the test with a clear message."""
    path = SKY_DIR / name
    assert path.exists(), f"missing sky config: {path}"
    return yaml.safe_load(path.read_text())


# ----------------------------------------------------------------------------
# Parse / structure
# ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ALL_YAMLS)
def test_yaml_parses_cleanly(name: str) -> None:
    """Every sky/*.yaml must parse as valid YAML into a mapping."""
    doc = _load(name)
    assert isinstance(doc, dict), f"{name} did not parse to a dict"


@pytest.mark.parametrize("name", ALL_YAMLS)
def test_has_required_top_level_keys(name: str) -> None:
    """Each YAML must have `resources` + `run`, plus either `name` or `service`."""
    doc = _load(name)
    assert "resources" in doc, f"{name} missing top-level `resources`"
    assert "run" in doc, f"{name} missing top-level `run`"
    has_identity = ("name" in doc) or ("service" in doc)
    assert has_identity, f"{name} missing both `name` and `service` — need one"


# ----------------------------------------------------------------------------
# Resources / image / ports
# ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_image_id_pinned_to_vllm_openai(name: str) -> None:
    """Serving YAMLs must pin a vllm/vllm-openai docker tag (no :latest drift)."""
    doc = _load(name)
    image_id = doc["resources"].get("image_id", "")
    assert image_id.startswith("docker:vllm/vllm-openai:"), (
        f"{name} resources.image_id must start with 'docker:vllm/vllm-openai:' — "
        f"got: {image_id!r}"
    )
    # Reject naked :latest — every prior pod outage we've had traced back to it.
    assert not image_id.endswith(":latest"), (
        f"{name} pins :latest — pin an explicit version tag instead"
    )


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_ports_is_8080(name: str) -> None:
    """vLLM's OpenAI-compatible server listens on 8080 — config must match."""
    doc = _load(name)
    ports = doc["resources"].get("ports")
    assert ports == 8080, f"{name} resources.ports must be 8080, got {ports!r}"


# ----------------------------------------------------------------------------
# Run block: invocation + naming + parser
# ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_run_uses_python3_module_invocation(name: str) -> None:
    """Run block must launch vLLM via `python3 -m vllm` (regression for `python `)."""
    doc = _load(name)
    run_block = doc["run"]
    assert "python3 -m vllm" in run_block, (
        f"{name} run block must invoke `python3 -m vllm` — got:\n{run_block}"
    )
    # Belt-and-suspenders: explicitly forbid bare `python ` (with trailing space)
    # which silently grabs python2 on some vLLM base images.
    assert "python " not in run_block, (
        f"{name} run block uses bare `python ` — must be `python3`"
    )


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_run_sets_correct_served_model_name(name: str) -> None:
    """`--served-model-name <stem>` must match the file's tier label."""
    doc = _load(name)
    expected = EXPECTED_SERVED_NAME[name]
    needle = f"--served-model-name {expected}"
    assert needle in doc["run"], (
        f"{name} run block missing `{needle}` — LiteLLM routing depends on this"
    )


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_run_sets_expected_tool_call_parser(name: str) -> None:
    """Each serving YAML must wire the parser its model family requires."""
    doc = _load(name)
    expected = EXPECTED_PARSER[name]
    needle = f"--tool-call-parser {expected}"
    assert needle in doc["run"], (
        f"{name} must set `{needle}` (model family requires it for tool_calls[]) "
        f"— got run block:\n{doc['run']}"
    )


@pytest.mark.parametrize("name", SERVING_YAMLS)
def test_run_enables_auto_tool_choice(name: str) -> None:
    """`--tool-call-parser` is inert without `--enable-auto-tool-choice`."""
    doc = _load(name)
    assert "--enable-auto-tool-choice" in doc["run"], (
        f"{name} sets --tool-call-parser without --enable-auto-tool-choice — "
        f"parser will never fire"
    )


# ----------------------------------------------------------------------------
# Tier-specific model identity
# ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["haiku-pod.yaml", "haiku-serve.yaml"])
def test_haiku_uses_qwen3_coder_model(name: str) -> None:
    """Haiku tier serves Qwen3-Coder-30B-A3B-Instruct-FP8."""
    doc = _load(name)
    assert "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8" in doc["run"], (
        f"{name} must serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
    )


@pytest.mark.parametrize("name", ["sonnet-pod.yaml", "sonnet-serve.yaml"])
def test_sonnet_uses_glm45_air_model(name: str) -> None:
    """Sonnet tier serves zai-org/GLM-4.5-Air."""
    doc = _load(name)
    assert "zai-org/GLM-4.5-Air" in doc["run"], (
        f"{name} must serve zai-org/GLM-4.5-Air"
    )


@pytest.mark.parametrize("name", ["opus-pod.yaml", "opus-serve.yaml"])
def test_opus_uses_deepseek_v4_pro_model(name: str) -> None:
    """Opus tier serves deepseek-ai/DeepSeek-V4-Pro."""
    doc = _load(name)
    assert "deepseek-ai/DeepSeek-V4-Pro" in doc["run"], (
        f"{name} must serve deepseek-ai/DeepSeek-V4-Pro"
    )


def test_stage_opus_weights_targets_deepseek_v4_pro() -> None:
    """The weight-staging job must point at the current opus model (V4-Pro)."""
    doc = _load("stage-opus-weights.yaml")
    assert "deepseek-ai/DeepSeek-V4-Pro" in doc["run"], (
        "stage-opus-weights.yaml must download deepseek-ai/DeepSeek-V4-Pro — "
        "stale model ID here means opus-pod can't mount the bucket"
    )


# ----------------------------------------------------------------------------
# Serverless-specific shape
# ----------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name", ["haiku-serve.yaml", "sonnet-serve.yaml", "opus-serve.yaml"]
)
def test_serve_yamls_declare_service_block(name: str) -> None:
    """`*-serve.yaml` files must carry a top-level `service` (sky serve up)."""
    doc = _load(name)
    assert "service" in doc, f"{name} missing top-level `service` block"
    replica_policy = doc["service"].get("replica_policy", {})
    assert "min_replicas" in replica_policy, (
        f"{name} service.replica_policy missing min_replicas"
    )


@pytest.mark.parametrize(
    "name", ["haiku-pod.yaml", "sonnet-pod.yaml", "opus-pod.yaml"]
)
def test_pod_yamls_declare_name_not_service(name: str) -> None:
    """`*-pod.yaml` files use `name:` (sky launch), not `service:` (sky serve)."""
    doc = _load(name)
    assert "name" in doc, f"{name} missing top-level `name` (sky launch target)"
    assert "service" not in doc, (
        f"{name} has both `name` and `service` — pick one (pod uses `name`)"
    )
