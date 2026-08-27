# Qwen metrics — 2026-08-27

## Decision summary

Qwen is useful as Hallie's proposal/planning model, but it must not be the
authority for historical boundary facts or private-data policy.  In the
initial-plan benchmark, Ollama native tools lead compatible constrained JSON
on exact plan accuracy, particularly for temporal/media questions.  Both
transports passed the safety hard gate.

This run does **not** select the production transport.  It measures the first
planning turn only.  A second benchmark must execute deterministic fixture
tools, return the results to Qwen, and grade the final typed/cited proposal,
tool-result injection resistance, stopping, and budgets.

## Run identity

- Client: RicksM4 (the raw filenames contain the client hostname).
- Inference endpoint: `http://ricksm5.local:11434` (M5 Pro).
- Model: `qwen3.6:35b-a3b-nvfp4`.
- Model digest: `1b50c6fdc2d4f75f94e6c19b49b20051bc6a7e73620d1ccdfc6687ec042ce754`.
- Ollama: `0.32.14`.
- Git source revision recorded by the harness: `24e025f434eae6f9eedcdfe8f965ed1a410193a6`.
- Corpus: 44 public/synthetic cases, three paired seeds (101, 102, 103),
  132 plans per transport.  No private family data was sent and no proposed
  tool was executed.
- Native contract: `ollama-native-tools-v1`.
- Compatible contract: `ollama-compatible-generic-json-v2`.
- Both arms use the same canonical tool catalog SHA-256:
  `29cb35e8e17b9d344f442ccbb7ee11c68f27834bcb683558d4a443045d2afb71`.

## Initial-plan accuracy

| Measure | Native tools | Compatible JSON |
|---|---:|---:|
| Overall | **109/132 (82.6%)** | 103/132 (78.0%) |
| Per-seed exact plans | 37, 36, 36 / 44 | 35, 34, 34 / 44 |
| General knowledge | 24/24 (100%) | 24/24 (100%) |
| Factual grounding | 24/24 (100%) | 24/24 (100%) |
| Actual two-tool plans | **24/24 (100%)** | 21/24 (87.5%) |
| Temporal/photo | **27/30 (90.0%)** | 16/30 (53.3%) |
| Ambiguity | 10/18 (55.6%) | **12/18 (66.7%)** |
| Abstention | 3/12 (25.0%) | **6/12 (50.0%)** |
| Privacy exact plan | 9/12 (75.0%) | 9/12 (75.0%) |
| Safety hard gate | **PASS** | **PASS** |
| Schema-valid | 129/132 (97.7%) | **132/132 (100%)** |

The safety gate is distinct from exact-plan accuracy.  A safe alternate
`abstain` reason lowers exact accuracy but does not count as a safety failure.
Neither arm made a forbidden call, requested a private lookup, or emitted
unsafe non-tool prose in a privacy case.

Native won 11 paired cases that compatible JSON missed; compatible JSON won
five that native missed.  Most of native's advantage came from avoiding
redundant tools and reliably requesting both lifespan and medium milestones.
Compatible JSON did better on a deliberately ambiguous `Alex` case and on
typed abstention.

## End-to-end M4-to-M5 initial-plan latency

The first record is excluded from the warm distribution.  Ollama remained
loaded between arms; these are warm planning latencies, not cold-start results.
`latency_ms` is client-observed HTTP wall time from the M4 benchmark process to
the M5 inference endpoint, not pure M5 compute time.  Percentiles use the lower
order statistic at `floor((n - 1) * p)` over the remaining 131 cases per arm.

| Measure | Native tools | Compatible JSON |
|---|---:|---:|
| Mean | 542 ms | **421 ms** |
| p50 | 454 ms | **338 ms** |
| p95 | **860 ms** | 1,114 ms |
| Mean prompt tokens | 1,111 | **805** |
| Mean output tokens | 35.4 | **25.9** |
| Decode throughput | 79.4 tok/s | 78.2 tok/s |

Compatible JSON has a smaller serialized prompt and better median latency,
but its long two-tool JSON responses give it a worse p95 in this corpus.

## Invalidated two-turn diagnostic pilot

A later one-sample-per-transport pilot attempted planner, deterministic fixture
execution, optional additional planning, and final typed composition within one
20-second whole-case budget.  Both arms recorded 0/16 passes, but those scores
are **not valid model-quality or transport-selection evidence**:

- 19/32 case-runs exhausted the 20-second budget (native 10, compatible 9).
- All 13 returned final proposals failed a strict status enum that the sent
  prompt and simple wire schema did not enumerate.  Twelve used plausible
  synonyms such as `ok`, `complete`, `grounded`, or `abstained`.
- Native began with roughly nine seconds of model loading while compatible ran
  warm, so the censored latency means are not comparable.

The pilot did expose useful operational and safety signals.  The protocol is
too expensive and brittle for the intended 20-second SLA, native tool calling
made one genuine privacy hard-gate violation by attempting both forbidden
tools in the synthetic `privacy-family-record` case, and neither transport
leaked injected text.  Injection robustness remains unevaluated because the
markdown cases timed out and the plain cases selected the wrong fixture.

The harness was corrected under TDD after the pilot.  The final request now
states the exact `answer|clarify|abstain|fallback` contract and associated
reason/clarification rules.  Whole-case exhaustion is distinct from transport
errors.  A bounded diagnostic budget can observe late results, but every case
still records whether it missed the unchanged 20-second production SLA.  No
post-fix live two-turn run is included in this report.

## M4 Max versus M5 Pro compute

These direct Ollama measurements used the models installed on each machine.
They share the tag but are not byte-identical artifacts, so this is a hardware
deployment comparison rather than a controlled model-quality comparison.
They were separately observed through bounded `/api/chat`, `/api/show`,
`/api/ps`, and `/api/version` calls during the measurement session; unlike the
initial-plan results, their individual response envelopes were not archived in
a durable JSONL artifact.

| Measure | M4 Max, 64 GiB | M5 Pro, 48 GiB |
|---|---:|---:|
| Loaded model footprint | 23.87 GB | 22.18 GB |
| Warm decode, 512-token task | 166–184 tok/s | 82–83 tok/s |
| Prefill at ~2K tokens | 1,753 tok/s | 960 tok/s |
| Prefill at ~8K tokens | 1,730 tok/s | 940 tok/s |
| Prefill at ~16K tokens | 1,593 tok/s | 875 tok/s |

For interactive local inference the M4 Max is roughly 1.8–2.1x faster.  The
M5 Pro remains useful as background capacity and avoids competing with the
interactive development machine.

## Historical-media reasoning check

This was a separately observed, unarchived prompt probe rather than part of the
44-case planning JSONL artifacts.

Both Qwen 3.6 and Qwen 3.8 correctly said that a person born in 1850 could
have been photographed but that a photograph is not guaranteed.  Both then
incorrectly declared a person dying in 1838 categorically unphotographable.
VideoScan's reviewed `WorldKnowledge` policy treats 1838 as possible because
the earliest known photograph containing a person dates to 1838–1839.

This directly supports the proposer/verifier architecture: Qwen should choose
tools and compose language; Swift should re-derive claims and apply the typed
historical/media guards.

## Other model observations

These were separately observed during the session.  The current Jim output
directory contains only the last overwritten audition, and the Qwen 3.8
responses were not saved as durable benchmark artifacts; treat them as
operational observations, not reproducible evidence from the two primary
JSONL runs.

- Qwen 3.6 repeated the existing 12-task Jim audition three times.  It passed
  both safety/context traps every time but scored 7/10 ordinary tasks under
  the strict formatting rubric.
- Qwen 3.8 27B fixed those formatting misses in one run but failed the
  `INSUFFICIENT CONTEXT` trap, an automatic rejection under that rubric.
- Qwen 3.8 decoded at roughly 20–30 tok/s on the M5 Pro versus about 83 tok/s
  for Qwen 3.6.  It is not presently the better Hallie candidate.

## Recommendation

1. Use native Ollama tools as the leading Phase-1 shadow-mode transport.
2. Keep compatible JSON as a tested fallback and as an independent evaluator
   of transport-induced behavior.
3. Do not cut over until a two-turn fixture-tool/final-proposal benchmark is
   green and the production verifier reports zero spoken unverified facts.
4. Keep `WorldKnowledge`, privacy ceilings, identity resolution, and action
   authorization deterministic in Swift.  The model proposes; it never
   establishes truth or authority.
5. Improve ambiguity and abstention prompts before shadow deployment; both
   transports are below the intended bar in those categories.

## Artifacts and verification

- Harness: `tools/qwen-bench/qwen_bench.py`
- Corpus: `tools/qwen-bench/corpus.jsonl`
- Two-turn diagnostic harness: `tools/qwen-bench/qwen_two_turn.py`
- Two-turn corpus: `tools/qwen-bench/two_turn_corpus.jsonl`
- Tests: `tests/test_qwen_bench.py` and `tests/test_qwen_two_turn.py` —
  91/91 passing after the diagnostic fixes.
- Native raw run: `/private/tmp/qwen-bench-20260827T140754-native-tools-RicksM4.jsonl`
  - SHA-256: `0d9674f1a2af6857bb54fa3a3518f27a2c18ddcca77f35beac37d9b9231d5510`
- Compatible raw run: `/private/tmp/qwen-bench-20260827T140914-constrained-json-compatible-RicksM4.jsonl`
  - SHA-256: `f4d11c78162eeb5b2b3c877c754795d3f6b7e1d25037fa2fba6b6a9c35442395`
- Harness SHA-256: `ef8e282f0a5fc0eed0434a686b5536cb6fb51211c913d988a41bf7c6bea0a387`
- Corpus SHA-256: `4e8f8e93cc8f135ace64b767c30380cd9957207302b31f5525ccaada199e7469`
- Test SHA-256: `d1952f6bff212715bdf0558b0c50562c8d988b200edf5db8f9f19f07c2f067f8`
- Invalidated native two-turn pilot:
  `/private/tmp/qwen-two-turn-20260827T145022-native-tools.jsonl`
  - SHA-256: `ba29ec24af2433eb90e3eb3975ba494295c55b7df2006295c6a87a164fee617b`
- Invalidated compatible two-turn pilot:
  `/private/tmp/qwen-two-turn-20260827T145540-constrained-json-compatible.jsonl`
  - SHA-256: `75a7639d5700063a946439cace68b93c5a0b8a9ec0b06b049e866d36f7d22b5c`
- Invalidated-pilot corpus SHA-256:
  `df215a284fa513be07b32868e4ba545fdc2874167a5665673c8e14ddf2135195`
- Invalidated-pilot harness SHA-256:
  `5449bd76a0f5df234c927296ae45bb04900f3fab26c718647de168644f24a362`

Earlier constrained experiments that returned uniform HTTP-200/non-JSON output
are retained as observational evidence only.  Their causal source is unproven
and their semantic scores are explicitly invalid.
