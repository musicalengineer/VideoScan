# Hallie and developer model management

Status note (2026-09-08): this is the September 6 design proposal, now committed
to main for review. Its implementation inventory is historical: the nightly
reviewer has since gained independent model/host selection and local-main
tracking. See [the morning brief](morning_brief_2026-09-08.md) for later changes.

Design recommendation — 2026-09-06. Requested by Rick; implementation is not part of this document. Source review based on `6943241e` and the current checkout; unrelated in-progress edits were preserved. This proposal replaces the coupling recommended by `model_strategy_2026_09_01.md` if adopted. That document's measurements remain historical evidence, not a permanent model ranking.

## Recommendation

Use separate role configurations for **Hallie** and **developer jobs**. They may deliberately select the same model, but must never inherit each other's selection implicitly. Hallie's ordinary picker shows evaluated presets. Advanced settings allow Rick to select a compatible custom model, clearly marked experimental. Installing or loading another model must not change Hallie's choice.

Do not build a general model-server manager inside VideoScan. Keep deployment, scheduling, and machine-wide resource policy in the development/admin environment. VideoScan owns its requests, selected backend, compatibility checks, cancellation, and honest status.

## What happens with multiple models

Installed models and resident models are different inventories: `/api/tags` lists available models; `/api/ps` lists running models. A coding model installed alongside Hallie's model does not by itself mean both are resident. [Ollama tags API](https://docs.ollama.com/api/tags), [running-model API](https://docs.ollama.com/api/ps).

Ollama documents concurrent loading when memory permits; otherwise requests can queue and idle models can be unloaded to make room. Parallel contexts add memory demand. `keep_alive` controls retention; it is not a reserved-memory or foreground-priority contract. Server queue, parallelism, and model-count settings exist. Treat actual limits as backend/version dependent and measure the installed runner. [Ollama FAQ](https://docs.ollama.com/faq).

Consequently, a nightly reviewer can slow Hallie or leave her next request cold. Separate settings, aliases, ports, or server processes do not isolate a shared Mac's memory bandwidth/GPU. A separate physical machine provides stronger isolation. Merely hiding a model from the picker does not prevent another client from using it.

Qwen3-Coder-Next is a reasonable **reviewer candidate**, not automatically an approved Hallie model. Its official card describes an 80B-total/3B-active coding model. Four-bit weight arithmetic alone is approximately 40 GB before quantization/runtime/context overhead; active parameters are not resident weight size. Measure the specific artifact on the chosen host before approving concurrent residency. [Qwen model card](https://huggingface.co/Qwen/Qwen3-Coder-Next).

## Current code and gaps

| Surface | Observed behavior | Policy consequence |
|---|---|---|
| `ArchivistEndpointSettings.swift` | Lists all tags from the first host returning a nonempty list; one model tag for an ordered host list | Inventory is not suitability; models installed only on another host are not represented coherently |
| `OllamaFailoverTranslator.swift` | Same template/model across hosts; bounded connection/repair retries; bad model output is not ordinary host failover | Keep this behavior explicit; do not silently reinterpret the host list as arbitrary model selection |
| Brain readiness UI | Installed/resident/missing and digest information | Useful diagnostics, not proof of Hallie quality or spare capacity |
| Restart action | Forgets capability state and unloads/warms selected tag on every configured host | Too broad for a shared fleet; target the selected endpoint/model and distinguish reconnect from reload |
| `review_real_commits.py:configured_model()` | Reads `archivist.ollamaModel` unless `--model` supplied | Hallie selection currently changes developer review behavior |
| `nightly_review.sh` | Supplies endpoint but no explicit model; reviews `origin/main` by default | Needs independent reviewer config; unpushed main changes are not automatically covered |
| Reviewer request | Explicit 32K context, no explicit keep-alive | Set a measured role-specific context and retention policy |
| `OllamaLocalServerBootstrap.swift` | Can spawn a local server from discovered executables | Must reconcile with the official app/service owner; never launch a competing server or pick an unintended binary |

The current memory tooltip also compares a server-reported size with RAM on **this Mac**. For remote hosts, identify whose measurements are shown; unknown remote capacity is unknown, not the client's capacity. Disk bytes, server-reported loaded bytes, and whole-host memory pressure are separate values.

## User-facing selection

Normal settings offer named, evaluated Hallie presets: for example “Family conversations — local.” Each resolves to an explicit provider, endpoint, model artifact and request settings. Show availability independently from approval: a tested model can be offline; an installed model can be untested.

Advanced settings offer other discovered chat/generation models and a custom identifier. Labels distinguish **tested for Hallie**, **untested**, and **known incompatible**. Developer-only entries are hidden from the normal menu, visible in Advanced with their role. Do not infer suitability from names containing “coder,” parameter count, or a successful HTTP response. A coding model can qualify after evaluation; a general model can fail.

An untested but technically compatible selection is allowed after explicit Apply, with a visible experimental label and an easy return to the previous working preset. Known protocol-incompatible models (for example embedding-only) cannot run as Hallie's conversational backend. Experimental selection never disables strict AST validation, evidence checks, or data-routing policy.

Discovery is read-only. Do not pull models, unload models, change the active selection, or send family content just because the settings pane opened. A synthetic compatibility check is distinct from warming weights: any generation probe may load a model and should be explicit.

## Minimal configuration contract

Start with a small settings value, not a new registry service. Each Hallie preset needs:

- Stable preset ID, label, provider adapter, endpoint, and model ID/tag.
- Local/LAN/cloud execution classification, including a cloud model proxied through a localhost server. URL locality alone is not sufficient.
- Observed artifact digest where available, server version, bounded context/output settings, thinking policy, timeouts and retry limits.
- Evaluation status and report reference tied to artifact + backend + request settings; a changed digest invalidates the old tested status.
- Explicitly ordered fallback targets and their data permissions. Begin with the same evaluated model on alternate hosts; heterogeneous fallback can be added only as declared presets.

Keep credentials in Keychain or an equivalent credential store, not profile exports, logs, or checked-in configuration. Cloud use must be explicitly enabled for the relevant family-data payloads; a local failure must not silently escalate to cloud. A cloud-capable local proxy must obey the same rule. Providers may lack comparable digests; record the available model/version identity rather than pretending exact reproducibility.

At turn start capture one configuration revision. Settings changes affect the next turn; a request must not silently switch model halfway through because the dropdown changed. Failover records the actual endpoint/model used. Readiness probes are keyed to the configuration revision so late results cannot label a newer selection as ready.

Capability checks concern an endpoint, model, server/runner build and request configuration. A generic 501 is not proof that every model/backend on that host has identical capabilities. Cache observations at the appropriate granularity; invalidate on configuration/reconnect changes. One valid JSON response demonstrates successful output on that probe, not guaranteed grammar enforcement. Always validate real responses. If schema enforcement is unavailable, use the tested bounded fallback and repair behavior, not guessed family facts.

## Ownership and resource policy

| VideoScan owns | Developer/admin environment owns |
|---|---|
| Hallie preset selection and consent | Model downloads, upgrades, deletions and retention on disk |
| Request budgets, cancellation, validation, approved fallback | Official Ollama installation, service lifecycle and fleet endpoints |
| Read-only installed/running status | Host memory/queue/concurrency limits and monitoring |
| Explicit reconnect or targeted reload | Nightly reviewer model, schedule, inputs and output reports |
| Answer provenance and current configuration status | Candidate evaluation and promotion decisions |

“Reconnect/check” should refresh availability/capability without eviction. “Reload this model” is a separate explicit action against one endpoint; avoid it during an active Hallie turn. No global stop-all, service restart, or unloading unrelated models from the app. Even a targeted unload can affect another client using that same model, so retention is a shared-server concern, not ownership conferred by the app.

For the existing M4/M5/M1 fleet, choose reviewer placement only after checking that machine's measured capacity and availability. Prefer a separate suitable host. Otherwise use an explicitly agreed quiet window, one reviewer job at a time, bounded context/output, a run deadline, and a short explicit retention period. Do not load the reviewer while interactive Hallie work is active unless coexistence has been measured and accepted. Start with scheduling rather than building a cluster scheduler. If same-host concurrent service becomes a requirement, add a cooperative job coordinator; Ollama alone does not establish application priority.

The reviewer script must accept its own explicit model and endpoint and must not read Hallie defaults. Missing reviewer configuration should skip with an actionable message, not choose whichever model happens to be selected in the app. Log model/version, commit range, prompt/harness revision and completion status. Do not advance the review baseline on failed/skipped work. Local automated review remains advisory; it does not approve its own findings or merge changes.

At job completion, let short retention expire; explicitly unload only when the scheduled job has exclusive use of that model. Never unload Hallie's model to make room without an agreed maintenance window. Two model aliases do not establish exclusive ownership.

The expected 96 GB machine is a future capacity opportunity, not an assumption of simultaneous residency or a promised throughput gain. Remeasure with the actual quantization, context, concurrent requests, app and Xcode load.

## Evaluation and tests

Hallie approval measures the recorded family-chat corpus: identity, follow-up scope, AST validity, evidence accuracy, appropriate refusal, conversational usefulness, and p50/p95 latency including cold starts, retries and template fallback. Retain a held-out set so fixing yesterday's examples does not become the whole benchmark. Human read/listen checks remain useful for awkward conversation.

Reviewer approval uses real commits with known defects and clean controls: actionable precision, missed regressions, invented findings, latency and memory. Coding leaderboard scores are shortlist evidence only. Do not substitute the review benchmark for Hallie's chat benchmark.

Check candidate releases monthly and after significant hardware/runner changes; adopt only after a bounded comparison to the current baseline. This is a proposed cadence, not an installed automation. Keep the previous working artifact/configuration available for rollback; official runner updates also need a compatibility smoke check.

Required implementation tests should exercise production construction paths:

1. Hallie selection and reviewer selection are independent; adding an unrelated installed model changes neither.
2. Normal vs Advanced visibility and explicit custom Apply; embedding-only rejection; tested status invalidated on artifact change.
3. Host A has tags but chat fails; model only on B; busy/503, timeout, malformed schema response, cancellation, all hosts down. No unexpected model or cloud fallback.
4. Reload targets exactly one endpoint/model; decoded payload asserts root keep-alive and empty messages; reconnect sends no unload. Late readiness replies cannot overwrite new settings.
5. Poisoned app defaults do not alter reviewer choice. External/remote capacity is not inferred from the client Mac. Same tag/different digest remains visible.
6. Measured coexistence or scheduling test: reviewer activity must meet the agreed Hallie latency and memory-pressure budget, or the scheduler defers it. Use an explicitly routed test host, not Rick's active M4 session.

## Delivery order

1. Decouple reviewer configuration from app defaults; make review job limits explicit. No backend redesign required.
2. Introduce tested Hallie presets plus Advanced custom selection, preserving the user's current setting as untested until evaluated. Improve status labels and target reload correctly.
3. Add explicit backend/route configuration and per-target permission checks before enabling heterogeneous/cloud fallback. Reuse existing transport boundaries; architectural implementation changes still follow project review rules.
4. Evaluate Qwen3-Coder-Next for the reviewer on a suitable host, then revisit residency with measured results. Continue Hallie correctness work independently.

No runtime settings, services, model installations, schedules, or production code were changed while preparing this design.
