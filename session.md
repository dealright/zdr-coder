# zdr-coder session resume — 2026-06-10

Comprehensive pickup doc after a long self-hosted sonnet-tier exploration.
Replaces the prior session.md from 2026-06-09.

---

## TL;DR

- ✅ **193/193 pytest suite green**, committed as `588e9a3`. Bedrock + tool_repair callback in production.
- ✅ **All Bedrock managed routes work** (sonnet-llama → DeepSeek V3.2, opus-bedrock → Mistral Large 3, haiku-llama → Qwen3-Coder, vision-bedrock → Qwen3-VL).
- ✅ **haiku-pod (Qwen3-Coder-30B-A3B-FP8) PROVEN working** via Hermes end-to-end test. The architectural proof of self-hosted agentic-haiku tier.
- ❌ **sonnet-pod self-host: extensively explored, no clean path found in current infra (mid-2026).** See "The Sonnet Exploration Postmortem" below.
- 🔵 **No clusters running. $0 ongoing GPU spend.**

**Total session GPU spend on the sonnet-pod exploration: ~$141.**

---

## The sonnet-pod exploration postmortem (2026-06-09 to 2026-06-10)

The user wanted a **self-hosted, non-AWS, sonnet-tier model** with reliable streaming + tool_choice=auto + agentic tool calling. We exhausted ~7 model+parser+hardware combinations. None met all constraints.

### Model matrix tested

| Model | Family | Streaming + auto + tools | Why it failed (or didn't) |
|---|---|---|---|
| ✅ Qwen3-Coder-30B-A3B-FP8 (haiku-pod) | Qwen3 Coder MoE | **WORKS** | Proven via Hermes test. The reference working config. |
| ❌ GLM-4.5-Air | GLM 4.5 MoE | `finish_reason: stop` | vLLM v0.10.0's `glm4_moe` parser + tool_choice=auto bug. Newer parser `glm45` exists in vLLM v0.22+ but needs CUDA 12.9 which Lambda doesn't support. |
| ❌ Qwen3-Coder-480B-A35B-FP8 | Qwen3 Coder MoE | UNTESTABLE | Engine init fails on A100: "CutlassBlockScaledGroupedGemm not supported" — needs Hopper (H100/H200) for FP8 grouped-GEMM kernel. H100:8 capacity dry across Lambda/Vast/RunPod for 12+ hours. |
| ❌ Qwen3-235B-A22B-Instruct | Qwen3 Instruct MoE | `finish_reason: stop` | Generic Instruct model is too conservative — refuses to commit to tool calls in streaming+auto mode regardless of system prompt, temperature, or `enable_thinking=False`. |
| ⚠️ Qwen2.5-72B-Instruct | Qwen2.5 Instruct Dense | mixed | Tool pipeline works (browser_navigate fired in Hermes test), but model prefers prose code blocks over `write_file` for ambiguous prompts. |
| ⚠️ Qwen2.5-Coder-32B-Instruct | Qwen2.5 Coder Dense | format mismatch | **Model IS willing to call tools** — emits `<tools>{...}</tools>` (Qwen2.5's native format), but vLLM's `hermes` parser expects `<tool_call>{...}</tool_call>`. Fixable with custom chat template or extending tool_repair callback. |
| ❌ Llama-3.3-70B-Instruct | Llama 3.3 Dense | UNTESTABLE | HuggingFace gated. No HF_TOKEN set. User started the access request — not yet approved. |

### Key findings

1. **Coder-tuned matters but "Coder" alone is not magic.** Qwen3-Coder works; Qwen2.5-Coder emits wrong format. Generation + training data both matter.

2. **MoE vs Dense matters at the streaming layer.** Generic MoE Instruct models (GLM-4.5-Air, Qwen3-235B-A22B-Instruct) refuse to commit to tool calls in streaming+auto. Generic Dense Instruct models (Qwen2.5-72B-Instruct) at least emit tool calls but conservatively.

3. **Qwen3-Coder-480B-FP8 = sonnet-tier ideal, but Hopper-locked.** Requires H100/H200 due to CutlassBlockScaledGroupedGemm. Capacity has been globally dry for 12+ hours across Lambda/Vast/RunPod.

4. **vLLM v0.10.0 ↔ Lambda CUDA 12.8 ↔ modern parsers**: irreconcilable triangle. Newer vLLM (v0.22+) ships better parsers (`glm45`, `qwen3_xml`, `deepseek_v32`) but requires CUDA 12.9 which Lambda's driver doesn't support.

5. **Parser names differ between vLLM versions**: v0.10.0 uses `glm4_moe`, `deepseek_v3`; v0.22+ uses `glm45`, `deepseek_v31`. The earlier workflow's recommendations were correct for newer vLLM, wrong for our pinned v0.10.0. Fixed in sky/*.yaml + test_sky_configs.py.

6. **RunPod's "stuck allocation" bug bit us twice this session.** Cluster shows `INIT` with an IP, but SSH never works — the instance is "rented but never starts". Cancellation is the only recovery.

### Cost ledger

| Item | Time | Cost |
|---|---|---|
| Stuck RunPod haiku-pod #1 (first launch attempt) | ~14 min | ~$0.20 |
| Lambda haiku-pod (UP, tested via Hermes, then idle 3hr) | ~3 hrs @ $1.99/hr | ~$6 |
| Lambda sonnet-pod GLM-4.5-Air all attempts | ~2 hrs @ $22.32/hr | ~$45 |
| Lambda A100 Qwen3-Coder-480B (failed engine init in <30 min) | ~30 min @ $22.32/hr | ~$11 |
| 10 hrs of H100:8 capacity bouncing (no instance up) | 10 hrs @ $0 | $0 |
| Lambda Qwen3-235B / Qwen2.5-72B / Qwen2.5-Coder-32B (sky exec rotations, same cluster) | ~3.5 hrs @ $22.32/hr | ~$78 |
| **Session total** | | **~$141** |

---

## What's working in production right now

### LiteLLM proxy (running, healthy)

`docker compose ps` → `zdr-litellm` UP. Port 4000. Health: 200.

Routes that **work and are smoke-tested**:

| Route | Model | Provider | Cost | Notes |
|---|---|---|---|---|
| ⭐ **sonnet-llama** | DeepSeek V3.2 | Bedrock | $3-8/M, $0 idle | THE agentic-sonnet workhorse |
| **opus-bedrock** | Mistral Large 3 675B | Bedrock | $3-15/M, $0 idle | Opus-class managed |
| **haiku-llama** | Qwen3-Coder 30B-A3B | Bedrock | $0.07/$0.27/M, $0 idle | Cheap agentic |
| **vision-bedrock** | Qwen3-VL 235B | Bedrock | ~$1-3/M, $0 idle | Vision-capable |
| **sonnet-deepseek-bedrock** | DeepSeek V3.2 | Bedrock | (alias of sonnet-llama) | |
| **haiku-api** | GPT-OSS 20B | Groq | $0.075/$0.30/M, $0 idle | Single-turn UI |
| **sonnet-api** | GPT-OSS 120B | Groq | $0.15/$0.60/M, $0 idle | Single-turn UI |
| **sonnet-llama-groq** | Llama 4 Scout | Groq | $0.11/$0.34/M, $0 idle | Streaming bug fixed by repair callback |
| **haiku-llama-groq** | Qwen3-32B | Groq | $0.30/$0.30/M, $0 idle | Cheap fallback |

### Sky configs on disk

| File | Status |
|---|---|
| haiku-pod.yaml | ✅ Qwen3-Coder-30B-A3B-FP8 + qwen3_coder, PROVEN working |
| haiku-serve.yaml | ✅ Same as haiku-pod, scale-to-zero (untested, should work identically) |
| sonnet-pod.yaml | ⚠️ Currently set to Qwen3-235B-A22B-Instruct (Instruct conservatism issue). Needs revision (see "Pickup options" below) |
| sonnet-serve.yaml | ⚠️ Same config issue as sonnet-pod.yaml |
| opus-pod.yaml | ✅ DeepSeek V4 Pro + deepseek_v3, untested (needs stage-opus-weights first) |
| opus-serve.yaml | ✅ Same model, scale-to-zero |
| smoke-test.yaml | Untested, just a cheap GPU sanity check |
| stage-opus-weights.yaml | One-time job, untested |

### Active SkyPilot clusters

**None.** $0 ongoing GPU burn.

### The test harness (193/193 green)

`litellm/tests/` — 193 tests passing in 47s. Run with:
```bash
cd /Users/dylansnow/Work/zdr-coder/litellm/tests
python3 -m pytest --tb=short -q                       # all 193
python3 -m pytest -m 'not integration' --tb=short -q  # unit only (0.17s)
python3 -m pytest -m integration --tb=line -q         # e2e against live proxy
```

CI: `.github/workflows/tool-repair-tests.yml` runs non-integration tier on push + PR.

### Uncommitted changes (working tree)

```
modified: litellm/tests/test_sky_configs.py    (parser name fixes — 65/65 still pass)
modified: sky/haiku-pod.yaml                   (qwen3_xml → qwen3_coder)
modified: sky/haiku-serve.yaml                 (same)
modified: sky/opus-pod.yaml                    (deepseek_v31 → deepseek_v3)
modified: sky/opus-serve.yaml                  (same)
modified: sky/sonnet-pod.yaml                  (now Qwen3-235B-A22B-Instruct, all A100/H100 SKUs)
modified: sky/sonnet-serve.yaml                (glm45 → glm4_moe — but the model is GLM still; needs revision)
new:      session.md                           (this file)
untracked: add_numbers.py / add_two_numbers.py / calculator.py / search_attempts.txt / stackoverflow_summary.txt
  (Hermes test artifacts — safe to delete)
```

When ready: `git add` the YAML + test edits and commit them as a "fix vLLM v0.10.0 parser names + sonnet-pod exploration" follow-up.

---

## Pickup options for next session

### Option A: Accept Bedrock as the agentic-sonnet backbone (cheapest)

The data says self-hosted sonnet-tier with streaming+auto+tools in our current vLLM v0.10.0 + Lambda/Vast/RunPod stack is genuinely hard. Bedrock `sonnet-llama` (DeepSeek V3.2) works perfectly. Accept this, document it, ship.

Action: tear down nothing (already clean), commit current YAML edits + session.md, push.

### Option B: Wait for HF token + try Llama-3.3-70B-Instruct

User started requesting access to meta-llama/Llama-3.3-70B-Instruct on HuggingFace. Once approved:

1. `echo "HF_TOKEN=hf_..." >> /Users/dylansnow/Work/zdr-coder/.env`
2. Update sky/sonnet-pod.yaml to use `meta-llama/Llama-3.3-70B-Instruct` + `llama3_json` parser + `--max-model-len 131072` + env passthrough for HF_TOKEN
3. sky launch on Lambda 8×A100 (proven SKU)
4. Cost: ~$10-15 for the test (Llama 3.3 70B is dense, smaller download than the MoE alternatives)

Hypothesis: dense Llama 3.3 70B + llama3_json parser may behave like Qwen3-Coder-30B did (clean streaming+auto+tools) since both are dense + tool-aware models.

### Option C: Wait for H100/H200 capacity + try Qwen3-Coder-480B-FP8

The model the original workflow research recommended as the #1 agentic-sonnet pick. Requires Hopper (H100/H200) — capacity has been globally dry but may open up. Watch by running:

```bash
./.venv-sky/bin/sky check-capacity H100:8  # not a real command, but the idea
# or just retry:
./.venv-sky/bin/sky launch -c sonnet-pod sky/sonnet-pod.yaml --yes
```

Cost: ~$30-40 if it actually provisions (~$30/hr for H100:8, ~30-50 min provisioning + download + warmup).

### Option D: Fix Qwen2.5-Coder-32B format mismatch via tool_repair callback

Extend `litellm/tool_repair.py` regex to handle `<tools>{...}</tools>` wrapper. Then Qwen2.5-Coder-32B-Instruct becomes a viable cheap dense sonnet-tier option (fits 4×H100 or 8×A100, ~$10-20/hr).

Code change: ~10 lines to add a new regex pattern to `_PATTERNS` in tool_repair.py:
```python
(re.compile(r"<tools>\s*(\{.*?\})\s*</tools>", re.DOTALL), "qwen25_tools"),
```

Plus possibly a chat-template override on the vLLM serve side to make Qwen2.5-Coder always emit `<tools>` format.

Test impact: add 1 case to `test_dsml_regex.py` parametrize and 1 to `test_success_hook.py`.

---

## Hermes test results from this session

### haiku-pod (Qwen3-Coder-30B-A3B-FP8) — TESTED, FULLY WORKING

```
write a python function to add two numbers, just print it out
  → write_file tool executed, add_numbers.py written cleanly
search for an answer in stackoverflow.com for the same
  → terminal tool executed 4× (curl calls to Stack Exchange API), recovered from Cloudflare
now wrap it in a class called Calculator and add error handling
  → write_file again, calculator.py with Calculator class + error handling
```

No leaks visible. Multi-turn coherence good. Full agentic loop works end-to-end.

### sonnet-pod (Qwen2.5-72B-Instruct) — PARTIALLY WORKING (latest test)

```
write a python function to add two numbers
  → NO tool call. Just prose code in message bubble.
search for an answer in stackoverflow.com for the same
  → ✅ browser_navigate fired, Cloudflare blocked, model recovered with prose
now wrap it in a class called Calculator and add error handling
  → NO tool call. Just prose code.
```

Pipeline works (browser_navigate fired). Model is conservative about choosing write_file when prose code answers the question. Coder-vs-Instruct distinction.

---

## To resume next session:

```bash
cd ~/Work/zdr-coder

# Verify state
./.venv-sky/bin/sky status                          # should be "No existing clusters"
docker compose ps                                   # zdr-litellm UP
cd litellm/tests && python3 -m pytest -q            # 193 passed

# Read this doc
cat ~/Work/zdr-coder/session.md

# Pick from "Pickup options" above based on appetite + HF token status
```

LiteLLM proxy health check: `curl http://localhost:4000/health/readiness` → 200.

End of session.md.
