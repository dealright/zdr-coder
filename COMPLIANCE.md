# Compliance posture — `zdr-coder`

This document covers the two paths this repo actually wires:

- **Level 3 — API mode** (`*-api` routes via Groq Cloud) → primary section below.
- **Level 6 — self-hosted** (`*-vast`, `*-serverless`, RunPod pods) → see [§ Level 6](#level-6--self-hosted-on-rented-gpu) at the bottom.

For the other levels (free chat, paid consumer, enterprise cloud APIs, TEE confidential), see the comparison table in [README.md](README.md#pick-your-privacy-level) — none of those are wired here, but the citations needed to audit them are linked from the table.

---

# Level 3 — Groq API mode (`*-api` routes)

What you contractually + technically achieve when running `sonnet-api` / `haiku-api`
through Groq Cloud with all best practices in place.

All quoted clauses are from Groq's binding legal docs:

- **SA** = [Groq Services Agreement](https://console.groq.com/docs/legal/services-agreement)
- **DPA** = [Customer Data Processing Addendum](https://console.groq.com/docs/legal/customer-data-processing-addendum)
- **BAA** = [Business Associate Addendum for GroqCloud Services](https://console.groq.com/docs/legal/customer-business-associate-addendum) (also mirrored as `.md` for download)
- **YD** = [Your Data in GroqCloud](https://console.groq.com/docs/your-data)

Read these against the doc versions in force on your account at the time you signed.

---

## What we **do** meet (with all best practices applied)

| Item | Source | How we meet it |
|---|---|---|
| **Zero Data Retention (contractual)** | SA §4.2 + YD | ZDR toggle enabled in console → Groq does not retain Inputs/Outputs for reliability or AUP-compliance purposes. Other §4.2 exceptions (service delivery, customer instruction, legal compulsion) remain. |
| **No training on Inputs/Outputs** | SA §4.2 verbatim: *"Groq is not permitted to use Inputs or Outputs for training or fine-tuning any AI Model Services or other models, unless explicitly granted permission or instructed by Customer."* | Default contractual posture. No additional action required. |
| **Customer retains IP in Inputs/Outputs** | SA §8.1 | Default. |
| **Encryption in transit** | DPA Annex II | TLS to `api.groq.com`. LiteLLM-to-Groq leg also TLS. |
| **Encryption at rest** | DPA Annex II | Applies only to data retained; with ZDR, nothing of yours is at rest beyond ephemeral inference buffers. |
| **US data residency for any retained data** | YD: *"All customer data is retained in Google Cloud Platform (GCP) buckets located in the United States."* | Applies only to data retained; ZDR makes this moot. |
| **HIPAA Business Associate Agreement** | BAA | Executed BAA (counter-signed) on file, traffic constrained to Covered Cloud Services. |
| **Breach notification within 10 business days** | BAA §2.6.a | Contractual. |
| **Sub-processor change notice ≥15 days** | DPA §7.2 | Contractual. |
| **SOC 2 Type 2** | Groq Trust Center | Marketing-level claim, not in binding docs. Request the report under NDA from `security@groq.com`. |
| **ISO 27001** | Groq Trust Center | Same as above. |
| **No prompt logging in our local proxy** | This repo: [litellm/config.yaml](litellm/config.yaml) | `turn_off_message_logging: true` and `disable_spend_logs: true`. |
| **Bound surface area** | This repo: [docker-compose.yml](docker-compose.yml) | LiteLLM bound to `127.0.0.1:4000` — never publicly exposed. |

---

## What we **don't** meet (and why)

| Gap | Why it's a gap | Workaround if you need it |
|---|---|---|
| **True end-to-end encryption** | Groq must see plaintext to run inference. TLS only protects the wire; the GPU has the cleartext. | Confidential computing (TEE-attested inference). Groq does not offer this in May 2026. Tinfoil and Apple PCC are the only options today, neither serves GPT-OSS 120B. |
| **Cryptographic proof ZDR is on** | The toggle is a contractual switch; you can't independently verify Groq is honoring it. You trust the SOC 2 audit. | Periodic vendor-attestation review, SOC 2 report read. |
| **HITRUST CSF certification** | Groq does not claim it. | If a payer requires HITRUST, use a self-hosted route (`-vast` / `-serverless`) with your own attested infra. |
| **FedRAMP authorization** | Groq is not FedRAMP authorized as of May 2026. | Self-host on FedRAMP-authorized cloud, or use AWS Bedrock / Azure AI for FedRAMP-eligible LLM calls. |
| **GDPR EU adequacy / EU data residency** | YD says data is retained in US GCP. DPA §8.1 allows transfer to "the United States and other countries." | Don't send EU resident data to `*-api` routes. Use a self-hosted route in EU region instead. |
| **PCI DSS** | Not relevant for inference of PHI; would require separate scoping if processing CHD. | Don't send PCI cardholder data to any of these routes. |
| **Free-tier / Preview / Beta model coverage** | BAA §1.1 explicitly excludes *"Beta Services and any features, products, or services that are not generally available, in alpha, beta, pre-production, preview, demo, trial stage or access, or provided for free or at no additional charge"* from Covered Cloud Services. | Pin to GA model IDs; never auto-upgrade to Preview. See best practices §3 below. |
| **Designated Record Set custody (HIPAA §164.524)** | BAA §2.4.a: *"The parties agree that Business Associate does not maintain PHI in a Designated Record Set for Customer."* Groq forwards individual access requests to you within 5 business days; you respond. | Your own systems must be the DRS of record for any PHI sent through Groq. |
| **Customer-side audit right of Groq's facility** | Not granted in DPA / SA. Only HHS Secretary has audit access per BAA §2.3. | Rely on SOC 2 / ISO 27001 reports under NDA. |
| **Geographic restriction on sub-processors** | DPA §8.1 permits non-US sub-processors. | Negotiate a US-only sub-processor amendment (enterprise plan). |
| **Coverage of message-prompt-engineering tooling** | LiteLLM does have an option to send analytics to Berri's hosted dashboard. We disable it. | Verified disabled in this repo. If you fork, re-verify. |
| **Inference workload isolation** | Multi-tenant GPU pool. Side-channel attacks (Spectre-family on H200 / B200) are a theoretical concern. | Self-hosted dedicated GPU (`*-vast` pod) if your threat model requires it. |
| **Cure period for material breach** | 30 business days (BAA §4.2) — a long window. | Document your own internal escalation path so you act within hours, not weeks. |

---

## Best practices — checklist for max-ZDR posture on Groq

Run through this **before** sending the first production / PHI request, and re-verify quarterly.

### 1. Account configuration

- [ ] **Enable ZDR**: [console.groq.com → Settings → Data Controls](https://console.groq.com/settings/data-controls) → toggle Zero Data Retention **ON**. Screenshot the confirmation for your audit folder.
- [ ] **Execute the BAA**: email `security@groq.com` with legal entity name, signer name + email, account ID, BAA URL. Request a **counter-signed PDF**, not just clickwrap confirmation. File it.
- [ ] **Request SOC 2 Type 2 report under NDA**: same email.
- [ ] **Request ISO 27001 certificate**: same email.
- [ ] **Enable spend limits**: console → Spend Limits → set a monthly cap appropriate to expected use. Anomalous spend = potential leak / abuse, acts as a tripwire.
- [ ] **Create a dedicated Project for PHI traffic**: console → Projects. Use a separate API key per environment (dev / staging / prod). Don't share keys across teams.

### 2. Key hygiene

- [ ] **Store `GROQ_API_KEY` only in `.env`** (in `.gitignore`). Never commit. Never ship to client devices.
- [ ] **Rotate quarterly**, or immediately on suspected exposure.
- [ ] **Scope keys per project** in the Groq console — not one master key for everything.

### 3. Model selection — only GA, never Preview

- [ ] **Pin model IDs in `litellm/config.yaml`** to specific GA model strings (e.g., `groq/llama-3.3-70b-versatile`). Never `:latest`, never `:preview`.
- [ ] **Before swapping models**, verify the new model ID is GA on Groq's pricing page — the BAA does not cover Preview tier.
- [ ] **Verify monthly** that the models you're using haven't been moved to deprecation / Preview status.

### 4. Surface area

- [ ] **LiteLLM proxy is bound to `127.0.0.1:4000`** in [docker-compose.yml](docker-compose.yml) — confirmed. Never change to `0.0.0.0` without front-line auth + TLS.
- [ ] **Logging is off**: `turn_off_message_logging: true` and `disable_spend_logs: true` in [litellm/config.yaml](litellm/config.yaml) — confirmed.
- [ ] **No LiteLLM dashboard auth tokens (`LITELLM_UI_USERNAME`, etc.) set** — we don't run the UI.
- [ ] **Local container**: Docker Desktop / engine should be on a managed laptop with full-disk encryption, screen-lock, automatic OS updates.

### 5. Client-side hygiene (Cline + your editor)

- [ ] **Cline workspace**: don't enable any "share session" / telemetry option that uploads prompts to a third-party service.
- [ ] **Your repo `.gitignore`** must exclude `.env`, `.env-runtime`, `.litellm-key`, `.vllm-key.*`, `.runpod-state.*`. (Pre-set in this repo.)
- [ ] **VSCodium telemetry**: disable in Settings → Telemetry → off. Codium ships with most disabled by default; verify.

### 6. PHI-aware operational discipline

- [ ] **Document which Cline sessions are PHI-eligible.** PHI work goes only through `*-api` routes after ZDR + BAA are in place, or through self-hosted (`-vast` pod with BAA from Vast).
- [ ] **Don't paste PHI into any other tool** (web LLM chats, screenshot OCR, email drafts, etc.) for "convenience".
- [ ] **Treat your own local logs as in-scope**: if you wrap requests in custom logging, that captured prompt is now PHI in your custody.
- [ ] **Incident protocol**: if you suspect a breach (key leak, anomalous spend, model returning data not from your context), rotate the key immediately and email `security@groq.com` within 24 hours regardless of whether it's confirmed.

### 7. Ongoing verification (quarterly)

- [ ] **Re-check ZDR toggle is still on** (no silent regression on UI redesigns).
- [ ] **Re-read sub-processor list**: [trust.groq.com/subprocessors](https://trust.groq.com/subprocessors). Note any new entries; flag to compliance if a new geography appears.
- [ ] **Re-read the SA and BAA versions** — check effective dates. Material changes warrant a re-acceptance audit trail.
- [ ] **Rotate API keys**.
- [ ] **Pull a fresh SOC 2 / ISO 27001 report** if older than 12 months.

---

## TL;DR

With all of the above in place, the API-mode posture on Groq is:

- **Strong** on contractual ZDR, no-training commitments, US residency, encryption in transit and at rest, HIPAA BAA coverage of Covered Cloud Services, customer IP retention.
- **Adequate** on SOC 2 / ISO 27001 / breach notification / sub-processor governance.
- **Weak** on cryptographic E2E (provider sees plaintext — inherent to non-TEE inference), independent ZDR verification, FedRAMP / HITRUST, EU residency, customer audit rights.

If your threat model needs any of the "weak" items above, the right answer is the self-hosted route below — accept the higher $/hr and operational burden for the stronger isolation.

---

# Level 6 — self-hosted on rented GPU

Applies to `haiku-vast`, `sonnet-vast`, `opus-vast`, `haiku-serverless`, `sonnet-serverless`, and the plain `haiku`/`sonnet`/`opus` RunPod-pod routes. Two providers in scope: **Vast.ai Secure Cloud** and **RunPod Secure Cloud**.

## What the platform itself certifies (not the datacenter partner)

| Item | Vast.ai (the rental platform) | RunPod (the rental platform) |
|---|---|---|
| **SOC 2 Type 2** | ✅ Vast Inc holds Type 2; Type 3 available on request | ✅ RunPod Inc holds Type 2 (October 2025) |
| **ISO 27001** | ❌ Not held by Vast Inc — only by datacenter partners | ❌ Not held by RunPod Inc — only by datacenter partners |
| **HIPAA BAA** | ✅ Via sales email (`compliance@vast.ai`) | ✅ Since February 2026 (via sales) |
| **FedRAMP** | ❌ | ❌ |
| **HITRUST CSF** | ❌ at platform level (some DC partners hold it) | ❌ at platform level |
| **GDPR** | ✅ DPA available; Ireland as supervisory authority | ✅ DPA available |
| **Host-introspection prohibition** | ⚠️ Not explicit in DPA — relies on Docker isolation + ToS | ✅ Docs explicitly prohibit hosts inspecting pod data; "Any violation results in immediate removal" |

**Important distinction**: when Vast or RunPod markets "ISO 27001 / Tier 3-4 datacenter," that certification belongs to the **upstream colo operator** (Equinix, OVH, etc.), not the rental platform. If your auditor needs ISO 27001 of the entity you're contracting with, Vast and RunPod don't qualify today — Lambda or CoreWeave do (both at Level 6 alternatives, not wired here).

## What you DO meet (Level 6, both providers, best practices applied)

| Item | Source | How |
|---|---|---|
| **No managed model provider** | Architecture | Your container, your model weights — no third-party LLM service sees prompts |
| **No training on your data** | Physical | You control the model binary. No telemetry path back to a model owner. |
| **Encryption in transit** | RunPod: HTTPS via `.proxy.runpod.net`. Vast: HTTP + bearer token (see gap below) | TLS or bearer-auth (Vast) |
| **No prompt logging by our proxy** | This repo's `litellm/config.yaml` | `turn_off_message_logging: true`, `disable_spend_logs: true` |
| **HIPAA BAA available** | Vast: compliance@vast.ai. RunPod: trust.runpod.io / sales. | Counter-signed PDF on request, no contract minimum |
| **SOC 2 Type 2 of rental platform** | Vast SOC 2 Type 2/3; RunPod SOC 2 Type II (Oct 2025) | Request under NDA via Trust Center |
| **Datacenter-tier ISO 27001 / Tier 3-4** | Filter applied by deploy script (`datacenter: {eq: true}` on Vast) | Held by colo, inherited transitively |
| **Bounded surface area** | `docker-compose.yml` | LiteLLM bound to `127.0.0.1:4000`, never publicly exposed |
| **Container-level isolation** | Provider-managed Docker | Side-channel still in scope; see gaps |
| **Pay-as-you-go, no contract minimum** | Both providers | Self-serve credit card; instances terminable in ~1 min |

## What you DON'T meet (Level 6)

| Gap | Why | Workaround |
|---|---|---|
| **Cryptographic E2E** | Host operator's root user can technically introspect the running container | TEE/CC mode (Level 5) — not standard on Vast/RunPod productized SKUs |
| **TLS on Vast leg** | Vast's direct port-forward is plain HTTP; bearer token is the only auth | Run a Caddy/Cloudflared sidecar inside the container. Tracked. |
| **ISO 27001 of rental platform** | Held by datacenter partner, not Vast/RunPod | Switch to Lambda or CoreWeave (require sales engagement) |
| **FedRAMP / HITRUST of platform** | Not certified by Vast/RunPod themselves | Required: move to AWS Bedrock / GCP Vertex (Level 4) |
| **Subprocessor disclosure** | Vast lists in DPA Annex III; RunPod has no public list | Vast: read DPA. RunPod: request from sales. |
| **Side-channel resistance** | Multi-tenant GPU host; H100 not in CC mode by default | Use H100/H200 CC mode — requires host config, not self-serve on either provider today |
| **EU residency SLA** | Both providers offer EU region selection but no SLA | Filter `geolocation` to EU. No 100% guarantee of region pinning if a host moves. |
| **Counter-signed BAA on file by default** | Both providers require sales contact | Email vendor, request counter-signed PDF (not clickwrap). Standard pattern. |
| **Auditable proof of "host doesn't introspect"** | Contractual prohibition (RunPod) or implicit (Vast) — no technical attestation | Use Level 5 TEE if needed |

## Best-practices checklist (Level 6)

Run through this once per project. Re-verify if you switch hosts or vendors:

### Vast.ai-specific
- [ ] `datacenter: {eq: true}` filter is enforced in `deploy-vast.sh` — verify before override
- [ ] `verified: {eq: true}` is **not** sufficient — that's marketplace tier
- [ ] BAA requested via `compliance@vast.ai` if PHI in scope; counter-signed PDF filed
- [ ] Vast SOC 2 Type 2 (and Type 3 if needed) requested under NDA via Trust Center

### RunPod-specific
- [ ] BAA requested via `support@runpod.io` (1-2 bday turnaround); counter-signed PDF filed
- [ ] API key set to **All** permissions scope (Restricted breaks serverless inference)
- [ ] RunPod SOC 2 Type II report requested via trust.runpod.io
- [ ] Acknowledge host-introspection prohibition (RunPod docs) but treat as contractual not technical

### Common to both
- [ ] LiteLLM bound to `127.0.0.1:4000` — never `0.0.0.0`
- [ ] `litellm/config.yaml` has `turn_off_message_logging: true` and `disable_spend_logs: true` (default in this repo)
- [ ] `.env`, `.env-runtime`, `.litellm-key`, `.vllm-key.*` in `.gitignore` (default)
- [ ] Bearer tokens rotated when destroying/recreating pods (`destroy.sh` handles this)
- [ ] No public ingress on pod ports — only the LiteLLM bearer-auth path
- [ ] Persistent volumes (`vol-up.sh`) destroyed when project ends (`vol-down.sh`) — they bill ongoing storage
- [ ] PHI traffic only on pods sized to your retention SLA; nothing in HuggingFace cache outlives the session

### Optional hardening
- [ ] H100/H200 CC mode requested via vendor sales (gets you to ~Level 5 on self-hosted)
- [ ] Run a Caddy/Cloudflared sidecar to add TLS on Vast (currently HTTP + bearer)
- [ ] Audit `gpu-node/Dockerfile` for any telemetry-by-default in vLLM or its dependencies

## TL;DR for Level 6

- **Strong** on: no managed model provider in path, you own the weights, contractual no-introspect (RunPod) / Docker isolation (Vast), HIPAA BAA, datacenter Tier 3-4, no third-party LLM telemetry.
- **Adequate** on: SOC 2 Type 2 of rental platform, encryption in transit (HTTPS on RunPod, HTTP+bearer on Vast).
- **Weak** on: ISO 27001 of platform (only DC partner has it), FedRAMP / HITRUST (none), cryptographic isolation from host operator (multi-tenant GPU), public subprocessor disclosure (RunPod).

**Level 6 is the right call when**: you need >4 hr/day continuous use, full control of model weights, no managed-provider in path, and you're OK with "datacenter operator could theoretically introspect" as the residual trust.

**Level 6 is NOT enough when**: your threat model requires cryptographic proof that the host operator cannot read prompts. Move to Level 5 (Tinfoil) or Level 4 with confidential-compute add-on (GCP Vertex on H100 CC + Sole-Tenant Nodes).
