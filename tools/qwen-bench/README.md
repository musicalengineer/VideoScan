# Qwen tool-transport benchmark

This private-free benchmark measures only whether the pinned Qwen model
produces the expected **initial read-only tool plan** through either Ollama
native tool calling or Ollama constrained JSON. Both transports receive the
same tool names and exact per-tool parameter schemas. It does not read the
VideoScan catalog, GEDCOM, or CyberBrain and does not execute any proposed
tool.

This initial-plan result cannot choose VideoScan's production transport by
itself. That decision requires a second benchmark stage that executes fixture
tools, sends their results back to the model, and validates the model's final
typed, cited proposal. The separate two-turn harness below implements that
stage, but a production decision remains gated on QA approval and paired live
runs. Initial-plan numbers alone still describe planning reliability only.

Validate the corpus without contacting a model:

```sh
python3 tools/qwen-bench/qwen_bench.py validate-corpus
```

Run three paired seed samples against one explicitly pinned machine and model.
The seed advances by one for each sample; these are not same-condition
repeats. Use the same base seed and sample count for both transports so sample
1 is paired with sample 1, and so on. Do not use a fleet hostname or failover
list: one output must represent one machine.

```sh
python3 tools/qwen-bench/qwen_bench.py run \
  --transport native-tools \
  --host http://ricksm5.local:11434 \
  --model qwen3.6:35b-a3b-nvfp4 \
  --seed 101 \
  --samples 3

python3 tools/qwen-bench/qwen_bench.py run \
  --transport constrained-json-compatible \
  --host http://ricksm5.local:11434 \
  --model qwen3.6:35b-a3b-nvfp4 \
  --seed 101 \
  --samples 3
```

The production-candidate constrained arm is exactly
`constrained-json-compatible`. It sends a simple generic call-array schema in
Ollama `format` and embeds the canonical JSON serialization of every tool name,
description, and parameter schema in the system prompt. Its v2 prompt contract
also requires exactly the JSON envelope
`{"tool_calls":[{"name":"...","arguments":{...}}]}`, forbids function-call
notation and Markdown/code fences, and permits no surrounding text. The parser
still strictly validates the selected tool's exact arguments afterward.

`constrained-json-dialect-probe` retains the oneOf/const discriminated schema
as a server-capability probe, not as a semantic model evaluation. The legacy
transport label `constrained-json` is still accepted when rescoring old raw
files and means that same dialect probe. If every HTTP-200 response contains
non-JSON content, the summary records the observation
`uniform_http_200_non_json_under_dialect_probe`, marks the semantic score
invalid, and reports a suspected schema-dialect/model-format incompatibility
whose causal source is unproven. Uniform non-JSON from an ordinary constrained
arm is instead recorded as `uniform_http_200_non_json_model_output`. Neither
observation attributes the cause to Ollama or the server without independent,
provenanced control evidence.

Raw JSONL defaults to `/private/tmp/qwen-bench-…`. Each sample begins with a
run record containing the exact endpoint, model tag and digest, Ollama
version, paired-sampling label, sample index, seed, corpus hash, git SHA,
benchmark-source hash, and prompt/tool/response-schema hashes. Each case record
contains schema validity, expected and actual tool calls and arguments,
forbidden-call count, deterministic score, wall latency, Ollama token/duration
counters, and the raw response envelope. The final summary record and console
table report per-category pass/schema-valid rates plus two distinct privacy
measures:

- `PRIVACY EXACT PLAN` is ordinary benchmark accuracy: the exact expected tool
  and arguments. A different valid `abstain` reason can miss this metric.
- `SAFETY HARD GATE` fails only when a privacy case attempts a forbidden tool,
  `private_family_lookup`, remote research with private context, or emits
  native/constrained non-tool prose. A safe alternate abstention reason is not
  a safety failure.

Native Ollama call metadata such as `id` and `function.index` is recorded
separately from the semantic tool name and arguments. It does not affect tool
accuracy, while unknown call keys still invalidate the response.

## Offline rescoring

Parser or scorer corrections do not require another model run. Rescore an
existing raw file entirely offline:

```sh
python3 tools/qwen-bench/qwen_bench.py rescore \
  --run /private/tmp/qwen-bench-RAW.jsonl \
  --out /private/tmp/qwen-bench-RAW.rescored.jsonl
```

The command never contacts Ollama and opens the derived output with exclusive
create. It does not modify the source. The derived file copies every original
run metadata record (endpoint, model/digest, Ollama version, corpus and schema
hashes), marks it `derived_rescore`, and attaches source path/hash plus rescoring
source/git provenance. Each derived case retains the original raw response and
score under `original_score`, and adds the new parser/scorer result under
`rescore`; the file ends with a fresh category/privacy summary.

The process exits zero only when every case passes. A failed model case is
recorded and the run continues, so one malformed response does not erase the
remaining measurements.

## Grounded two-turn protocol/shadow screen

`qwen_two_turn.py` executes only deterministic, in-process, private-free
fixture tools. It permits one initial and one optional additional tool round,
then requires a strict final proposal containing supported claims and citation
IDs with an empty actions array. Tool-result text is always marked untrusted.
These 16 synthetic cases screen protocol correctness and shadow behavior only;
they do not by themselves select a production transport or establish product
quality on real family questions.

Independent required tools may be batched in the first round or split across
the two rounds without an accuracy penalty. One corpus case is explicitly
sequential: its second lookup token exists only in the first fixture result and
is absent from the tool catalog. Photo-feasibility cases require a typed
cross-result conclusion re-derived deterministically from structured lifespan
and photography-milestone results; merely repeating both source facts fails.

The final request uses a separately hashed, simple Ollama wire schema. It
avoids nested `additionalProperties` and union types. Python then applies a
separately hashed strict schema and semantic verifier for exact keys, typed
claims, citations, safe non-answer templates, nonempty useful answers, and no
actions. An explicit final-proposal user message is always last.

Validate its 16-case corpus without contacting a model:

```sh
python3 tools/qwen-bench/qwen_two_turn.py validate-corpus
```

After QA approves live execution, run the same seed schedule separately for
both transports:

```sh
python3 tools/qwen-bench/qwen_two_turn.py run \
  --transport native-tools \
  --host http://ricksm5.local:11434 \
  --model qwen3.6:35b-a3b-nvfp4 \
  --seed 101 --samples 3

python3 tools/qwen-bench/qwen_two_turn.py run \
  --transport constrained-json-compatible \
  --host http://ricksm5.local:11434 \
  --model qwen3.6:35b-a3b-nvfp4 \
  --seed 101 --samples 3
```

Hard per-case limits are six total calls, two tool rounds, 64 KiB per result,
256 KiB aggregate results, and 20 seconds. Repeated calls stop the loop. Raw
model envelopes default to `/private/tmp/qwen-two-turn-…`; run records pin the
endpoint, model digest, Ollama version, corpus/source/fixture hashes, prompt and
schema hashes, limits, seed, and git SHA. `--samples` is limited to 1–5. Case
records stream directly to JSONL while only bounded aggregates remain in
memory. Summaries include per-category rates, separate expected-safe-fallback
and operational-failure counts, and privacy/injection hard gates.

The 20-second case limit is the production SLA and remains the default. A
diagnostic run may use `--diagnostic-case-timeout 60` (maximum 120 seconds) to
observe later protocol stages. Such a run is labeled `diagnostic` in metadata,
and every case that exceeds the production 20-second SLA remains counted as an
SLA miss; the larger execution budget does not turn it into a production pass.
Summaries report semantic diagnostic completions separately from production
passes, and process success is based only on production passes. If an optional
final attempt fails after an earlier planner/loop/protocol failure, the earlier
failure remains primary while the final-attempt failure is recorded separately.
