# Hallie — the agent lane (cloud model in the loop, verifier in Swift)

*Design, 2026-10-10. Status: PROPOSED — Rick reviews before any code. Supersedes the control-loop half of [hallie_proposer_with_tools_design.md](hallie_proposer_with_tools_design.md) rev 5 under Rick's §R6 ruling (cloud allowed); keeps rev 5's claim/citation contract (§3, §3.1), knowledge tiers (§4), GuardPolicy and budgets (§8b) unchanged. The experiment that decides whether this gets built is [hallie_e1_experiment.md](hallie_e1_experiment.md). Author: Claude (design agent). Reviewer: Rick; in-house `qa`. Not a codex path (no data loss possible — read-only tools).*

**🔴 Decisions needed from Rick are in §12, one per line.** Nothing in §§1–11 is final until those are ruled.

---

## 0. In one paragraph

Hallie gets three lanes behind one door. The **agent lane** sends the question and a catalog of ~11 read-only tools to a Claude model, which calls tools in a bounded loop and ends by calling `submit_answer` with typed, cited claims. The **local lane** is rev 5's shape (one plan turn on the M5 Ultra's local model, Swift executes) over the *same* tools, for offline use. The **deterministic lane** is today's chain, the fallback forever. All three feed one **verifier**: a claim is spoken only if its citation points at an id a tool returned *this turn* and the value re-derives from the source. A privacy **data class** rides on every tool result and is enforced in the one function that serializes results for a transport, so `familyMedia` of living immediate family cannot reach a remote endpoint whatever the prompt says. "Decline over guess" is not a rule the model follows; it is what remains when the only way to say a fact is a verified claim and the only way to name a subject is a resolved id.

---

## 1. Why this shape (what changed since rev 5)

Rev 5 kept the model out of the control loop because the local qwen 35B scored 0/16 on a two-turn agentic loop under a 20 s deadline (codex #736; the Hallie guide later notes that pilot was itself under-specified — `docs/guides/hallie.md` § Model configuration — but no corrected rerun exists). Rick's 2026-10-10 ruling allows cloud models for everything except media of living immediate family. Frontier models are built for exactly the shape rev 5 avoided: pick a tool, read the result, pick the next, stop when done. So the loop comes back, **on the cloud lane only**, and everything that made rev 5 safe stays: typed claims, re-derivation, GuardPolicy in every lane, budgets, one deadline, tool results as data.

The defect this must remove is named in the live ledger (`docs/guides/hallie_live_failures.md`): *a cue misses and a fallback confidently answers a different question*. Every instance was true, cited, and about the wrong person or field. Section 8 makes that structurally impossible rather than adding another cue.

---

## 2. Architecture

```
                 ┌──────────────────────────────────────────────────────────────┐
 question ──────►│ HallieFrontDoor / modal states / repair / HallieModeClassifier│  (unchanged)
                 └───────────────┬──────────────────────────────────────────────┘
                                 │  HallieLanePolicy.pick(mode, turnKind, endpoint availability)   (data table, §9)
            ┌────────────────────┼─────────────────────────────┐
            ▼                    ▼                             ▼
   ┌─────────────────┐  ┌──────────────────┐        ┌────────────────────────┐
   │  AGENT LANE     │  │  LOCAL LANE      │        │  DETERMINISTIC LANE    │
   │ Claude API      │  │ Ollama on Ultra  │        │ today's chain          │
   │ bounded loop    │  │ one plan turn,   │        │ preTranslationSingle → │
   │ ≤6 model calls  │  │ Swift executes   │        │ translator → execute   │
   │ ≤8 tool calls   │  │ (rev 5 §3)       │        │ (fallback forever)     │
   └───────┬─────────┘  └────────┬─────────┘        └───────────┬────────────┘
           │ AgentToolCatalog (§4) — the SAME tools              │
           ▼                     ▼                               │
   ┌──────────────────────────────────────────┐                  │
   │ ToolResult {items, ids, dataClass, …}    │                  │
   │ RemoteSerializer (§5) — the ONE gate     │                  │
   └───────────────────┬──────────────────────┘                  │
                       ▼ AnswerProposal (submit_answer)          ▼ Result
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ ClaimVerifier (§7) → SubjectCheck (§8) → GuardPolicy → canonical sentences│
   │ → HallieTurnExecutor.Result → HallieResponseCommit (unchanged)            │
   └──────────────────────────────────────────────────────────────────────────┘
```

**Seams (C++ reader's map).** `AgentTool` is a table row — metadata plus a function pointer (`std::function`) — not a case in a `switch`. `ToolResult` is a plain value (`struct`, `Codable` ≈ auto-generated JSON (de)serializer, like `NLOHMANN_DEFINE_TYPE_INTRUSIVE`). `HallieAgentLane` is an `actor`: think "class whose methods are serialized onto one strand" — callers `await` instead of taking a mutex. `Task` cancellation is cooperative, like `std::stop_token`: the deadline requests a stop, and every `await` inside the loop is a check-point. `Sendable` is a compile-time marker meaning "safe to hand to another thread" (no shared mutable reference inside), enforced by the compiler the way `const` is.

**Fleet.** M5 Ultra: Ollama/MLX for the local lane and (later) a local semantic index; M4 Max: the app + nightly eval; M5 Pro / M1 Max: Dossier/caption backfill and E1/eval runners; Claude API: agent lane and the nightly A/B lane. Nothing in the app depends on which Mac hosts the local model.

---

## 3. What the tools wrap (nothing re-invented)

The point of the catalog is that every tool is a thin adapter over an engine that already exists and already has tests. Anchors are in the worktree at commit `40ad4b7`; `CORE` = `VideoScan/VideoScanCore/Sources/VideoScanCore`, `APP` = `VideoScan/VideoScan`.

| Engine | Anchor | Used by tool |
|---|---|---|
| `GedcomFamilyGraph.people[id]` / `person(familySearchID:)` / `people(matching:)` | `CORE/GedcomFamilyGraph.swift:112`, `:754`, `:722` | `resolve_person`, `person_facts` |
| `HallieOwnerResolver.resolve(_:graph:familySearchID:)` (owner pin first) | `APP/Hallie/HallieOwnerResolver.swift:61` | `resolve_person` |
| `PersonResolver.resolveExact/resolve/resolveAll` (People tab names, aliases) | `APP/People/PersonResolver.swift:176,191,214` | `resolve_person` |
| `CyberBrainIndex.resolve(_:)` | `CORE/CyberBrainIndex.swift:98` | `resolve_person` |
| `SpeakerKinship.rebind(people:question:speakers:graph:cyberBrain:kinshipOverlay:)` ("my dad" → a person) | `APP/Hallie/HallieTurnExecutor+SpeakerKinship.swift:235` | `resolve_person` (kin words) |
| `HallieLineageAnswer.ownerRelative(_:context:graph:)` (bare kin word ladder, the Dafydd fix) | `APP/Hallie/HallieLineageAnswer+KinTerm.swift:45` | `resolve_person` |
| `FamilyTreeNameSearch.search(_:overlay:)` (typo-tolerant hits) | `CORE/FamilyTreeNameSearch.swift:413` | `resolve_person` (last rung) |
| `GedcomFamilyGraph.relatives(_:of:)`, `marriages(of:)`, `allRecordedParents(of:)` | `CORE/GedcomFamilyGraph.swift:890`, `:881`, `:965` | `person_facts`, `relatives` |
| `relatives(_ relation: ExtendedRelation, side:, of:) -> KinshipResolution` | `CORE/GedcomKinshipPath.swift:99` | `relatives` |
| `relationshipPath(from:to:maxDepth:)`, `describe(_:)`, `directAncestorLine(from:to:)` (12 / 25 limits) | `CORE/GedcomRelationshipPath.swift:211`, `:275`, `:126`, `:103`, `:117` | `relationship_between` |
| `commonAncestry(of:and:)`, `bloodRelation(of:to:)`, `relationThroughMarriage` | `CORE/GedcomFamilyGraph+CommonAncestry.swift:64`, `+RelationshipName.swift:143`, `:206` | `relationship_between` |
| `ancestorLine(of:line:generations:untilYear:)`, `descendants(of:depth:)`, `originTrail(of:)` | `CORE/GedcomFamilyGraph+Lineage.swift:59`, `:228`, `:275` | `ancestor_line` |
| `TreeStatistics.people(matching:in:)`, `count`, `birthCountries`; `BirthplaceClassifier.classify` | `CORE/TreeStatistics.swift:125`, `:135`, `:182`; `CORE/BirthplaceClassifier.swift:103` | `tree_people_where` |
| `HallieLineageAnswer.superlative(_:…)` (kinds at `HallieLineageQuestion.swift:106`); `ArchivistFamilyTreePolicy.summary` | `APP/Hallie/HallieLineageAnswer+Superlatives.swift:96`; `CORE/ArchivistFamilyTreePolicy.swift:42` | `tree_superlative` |
| `CyberBrainIndex.evidence(for:privacyCeiling:limit:)` (privacy filtered, cap 50) — never `allActiveItems` | `CORE/CyberBrainIndex.swift:159` | `family_knowledge` |
| `HallieTurnExecutor.executePresenceLike(_:route:request:context:dependencies:)` → `ArchivistPresenceExecutor.execute(_:records:)`; `knownSpellings(of:graph:)`; `ArchivistEvidenceBasis` | `APP/Hallie/HallieTurnExecutor+Presence.swift:58`, `:450`; `APP/Hallie/ArchivistPresenceExecutor.swift:485`, `:7` | `search_media` |
| `HallieCatalogStats.compute/answer`; `OrderRequest` + `executeOrdered` (longest/shortest/newest/oldest) | `APP/Hallie/HallieCatalogStats.swift:54`, `:285`; `APP/Hallie/HallieTurnExecutor.swift:295`; `+DateOrdered.swift:22` | `catalog_stats` |
| `WorldKnowledge.fact(_:)`, `MediumFeasibility.assess(person:medium:)` | `CORE/WorldKnowledge.swift:163`, `:278` | `world_fact` |
| `ArchivistTemporalExecutor.ageAtDeath`, `executePresentAge` (age arithmetic over qualified dates) | `APP/Hallie/ArchivistTemporalExecutor.swift:923`, `:492` | verifier's `inference(ageAtEvent)` re-derivation |
| `HallieCompositionVerifier.verify(_:plan:personaName:)`; `HallieAnswerPlan.derive(from:)` | `APP/Hallie/HallieCompositionVerifier.swift:156`; `APP/Hallie/HallieAnswerPlan.swift:223` | prose check after claims (§7) |
| `HallieModeClassifier`, `HallieModeGate.reconcile` | `APP/Hallie/HallieModeClassifier.swift`; `APP/Hallie/HallieModeGate.swift:46` | lane pick (§9) and the deterministic lane's own gate |
| `HallieResponseCommit.apply(…sinks:)`, `isThinking` | `APP/Hallie/HallieResponseCommit.swift:44`; `APP/Hallie/ArchivistChatWindow.swift:260` | UI (§6.5) |
| `OllamaEndpoints`, `OllamaLocalServerBootstrap.isLocalEndpoint(_:)` | `APP/Hallie/LLM/OllamaEndpoints.swift:43`; `OllamaLocalServerBootstrap.swift:148` | `EndpointClass` (§5) — today there is only local-vs-not; the class enum is new |
| `HallieTranscriptEvent` / `HallieConversationRecorder` | `APP/Hallie/HallieConversationLog.swift:7`, `:323` | lane + usage fields (§6.6) |

Two facts from the survey shape the plan: **there is no text embedding index** (only face embeddings) and **the transcript is one flat `String?` per record** (`VideoRecord.audioTranscript`, `CORE/VideoRecord.swift:324`); only scene captions carry timestamps. So `search_media` can report *that* a transcript matched and a short snippet, but "the Hudson Thanksgiving inside a 94-minute tape" needs segments and a semantic index — separate designs (§R6 item 5), and this doc only reserves the field (`segment` in `search_media` items, optional).

---

## 4. The tool catalog

Conventions (rev 5 §5.1 kept): every tool returns

```json
{"ok": true, "items": [...], "ids": ["gedcom:@I13@", "people:7F2C…", "brain:item.42", "catalog:5E1A…", "world:photo.first@3", "q:q-3f9a"],
 "truncated": false, "queryID": "q-3f9a", "dataClass": "familyText",
 "subjects": [{"id": "gedcom:@I13@", "living": false, "immediateFamily": false}]}
```

or `{"ok": false, "error": "<enum>", "detail": "…"}`. `ids` is the only thing a claim may cite; `q:` ids are what `catalogCount` cites. Budgets are **per call** (items and bytes) and there is one aggregate prompt budget per turn (§6). `dataClass` is the *highest* class of any item in the result (`public < familyText < familyMedia`). Schemas below are abbreviated; the full file is `docs/hallie_tools.schema.json`, generated from the Swift catalog (golden test, §13) and consumed by the E1 harness. All schemas carry `additionalProperties: false` and are sent with `strict: true`.

| # | Tool | Input schema (abbrev.) | Items | Wraps | Class | Budget |
|---|---|---|---|---|---|---|
| 1 | `resolve_person` | `{name: string, hint?: enum[tree,people,knowledge,any]}` | `[{id, displayName, years, sex?, kind: tree\|profile\|brain, note?}]` — owner pin first; kin words rebound; ambiguity returned as several items, never guessed | OwnerResolver → PersonResolver → CyberBrain.resolve → SpeakerKinship.rebind / ownerRelative → people(matching:) → FamilyTreeNameSearch | familyText | ≤ 8 items, 2 KiB |
| 2 | `person_facts` | `{personID: string}` | `{birth{date,qualifier,place}, death{…}, sex, familySearchID?, parents[ids], spouses[ids], children[ids], profile?{aliases, kinshipRows}}` — People-tab dates win for the inner circle (People tab = truth) | graph.people[id], relatives, marriages, POIProfile | familyText | 4 KiB |
| 3 | `relatives` | `{personID, relation: enum[ExtendedRelation], side?: enum[maternal,paternal]}` | `[{id, name, years, path[ids]}]` | GedcomKinshipPath.relatives(_:side:of:) | familyText | ≤ 12 items, 4 KiB |
| 4 | `relationship_between` | `{aID, bID}` | `{relation, pathIDs[], hops, viaDirectLine: bool, commonAncestors?[ids]}` or `ok:false error:"noPathWithinLimit"` (the limits are stated in `detail`) | relationshipPath / directAncestorLine / commonAncestry / describe | familyText | 4 KiB |
| 5 | `ancestor_line` | `{personID, line: enum[maternal,paternal,all], generations: int, untilYear?: int}` | `[{depth, id, name, birth{year,place}}]` + `yearBoundGap` | ancestorLine, originTrail | familyText | ≤ 40 items, 8 KiB |
| 6 | `tree_people_where` | `{filter{bornIn?, diedIn?, bornBetween?[y,y], diedBetween?, surname?, scope?{personID, relation: ancestors\|descendants}}, operation: enum[list,count]}` | `{count, items[{id,name,years,birthPlace}]}` (list ≤ 25; count always exact) — unknown place → `ok:false error:"unknownPlace"` | TreeStatistics.people/count, BirthplaceClassifier, gazetteer (10/09 design) | familyText | ≤ 25 items, 6 KiB |
| 7 | `tree_superlative` | `{kind: enum[earliestBorn,latestBorn,longestLived,latestDied,earliestMarried], scope{personID?, line?: enum, surname?, wholeTree: bool}}` | `[{id, name, value, rankedCount}]` ≤ 3 — the scope echo ("ranked N of X's ancestors") is in the item so the model cannot misreport scope | HallieLineageAnswer.superlative, ArchivistFamilyTreePolicy | familyText | 2 KiB |
| 8 | `family_knowledge` | `{personID, kinds?: [enum[biography,anecdote,event,note,service]], limit?: int}` | `[{itemID, kind, text, confidence, sourceIDs, attribution, eventDate?, place?}]` — privacy ceiling comes from the viewer, **never from the model** | CyberBrainIndex.evidence(for:privacyCeiling:limit:) | familyText | ≤ 12 items, 8 KiB |
| 9 | `search_media` | `{people?: [personID], keywords?: [string], years?: [y,y], mediaKind?: enum[video,photo,audio,any], place?: string, limit?: int}` | `{matchCount, items[{recordID, filename, year, durationSeconds, evidence[{kind: tag\|transcript\|caption\|filename\|notes\|place, term, snippet?, timestamp?}], segment?}]}`, `truncated` | executePresenceLike over `ArchivistPresenceRecordSnapshot`; spellings via knownSpellings; evidence kinds from ArchivistEvidenceBasis | familyText; **snippets from transcript/caption are `familyMedia` by default** (D1) | ≤ 25 items, 8 KiB |
| 10 | `catalog_stats` | `{question: enum[total,footage,years,archived,duplicates,diskSpace,overview], order?{key: enum[date,duration,size], direction: enum[asc,desc], ordinal?: int}, filter?{people?, years?}}` | `{values{…}}` or `[{recordID, filename, value}]` for an ordered ask | HallieCatalogStats.compute/answer; OrderRequest + executeOrdered | familyText | 2 KiB |
| 11 | `world_fact` | `{id?: string, feasibility?{personID, medium: enum[photograph,film,audio,video]}}` | `{id, version, statement, earliest, latest}` or `{verdict: impossible\|possible\|unknown, factID}` | WorldKnowledge.fact, MediumFeasibility.assess | public | 1 KiB |
| 12 | `submit_answer` | see §7.1 | terminal — ends the loop | — | — | — |

Not a tool: writes of any kind (told-me, captions, pronunciations stay on the telling routes with confirmation), app navigation, playback. Offers are *intents* in `submit_answer`; Swift derives every `OfferedAction` from verified claims (rev 4).

**Why 11, not 30.** Each of today's regex routes could be a tool; that would re-create the pile. These 11 are the *engines*, one each, with the model doing the composition a route used to hard-code ("great great grandpa on his paternal side" = `resolve_person` → `relatives(relation: greatGreatGrandparent, side: paternal)` → `person_facts`). A tool is added when an engine exists and no composition of the 11 reaches it (the tool-count tip in the API docs: keep the set focused; descriptions say *when* to call).

**Descriptions are prescriptive.** Each tool's `description` states when to call it and what not to do ("`resolve_person`: call before ANY other tool when the asker names a person or a kin word; never type an id you did not get from a tool result"). Descriptions are part of the cached prefix, so wording changes are a version bump (§6.3).

### 4.1 Swift shape (data over switches)

```swift
/// One row of the catalog. C++: a `struct Tool { const char* name; JsonSchema schema; …; std::function<Result(Args)> run; }`
/// kept in a `static const` table — never a `switch (name)` that grows.
public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let schema: JSONSchema            // Codable; emitted to docs/hallie_tools.schema.json
    public let dataClass: DataClass          // the class the tool CAN return; items may raise it
    public let budget: ResultBudget          // maxItems, maxBytes
    public let run: @Sendable (ToolArguments, ToolContext) async throws -> ToolResult
}

public enum AgentToolCatalog {
    public static let all: [AgentTool] = [resolvePerson, personFacts, relatives, relationshipBetween,
                                          ancestorLine, treePeopleWhere, treeSuperlative, familyKnowledge,
                                          searchMedia, catalogStats, worldFact]   // deterministic order → stable prefix
    public static func tool(named: String) -> AgentTool?   // dictionary built once from `all`
}
```

`ToolContext` carries the graph, the presence snapshots, the CyberBrain index, the People snapshots, the viewer's privacy ceiling, the owner id and the turn's deadline — injected, so every tool is testable with fixtures and reads no globals (CLAUDE.md dimension 4). Each `run` is ≤ 30 lines: validate args → call the engine → map to items/ids → clamp to budget → set `truncated`. The engines stay where they are; the catalog is the wrapper over N sites.

---

## 5. Data class and the endpoint gate

### 5.1 The classes

| Class | Contents | May go to `remote`? |
|---|---|---|
| `public` | world facts; tree facts of deceased people (FamilySearch already publishes them) | yes |
| `familyText` | names, dates, places, aliases, kinship rows, tags, filenames, notes, CyberBrain item text, counts | yes (Rick's ruling) |
| `familyMedia` | pixels, audio, frames, face embeddings — **and, until D1 is ruled, transcript and caption text derived from media** | **never** when any subject is living immediate family; by default never at all |

`subjects[].living` / `.immediateFamily` are computed by `FamilyMembership` (new, pure, in Core): immediate family = the owner plus every People-tab profile with a kinship row to the owner (`POIProfile.kinships`, `APP/People/PersonFinderTypes.swift:483`, Kinship at `APP/FamilyTree/FamilyKinship.swift:407`); living = no death date on the profile or tree record, with "born after 1926 and no death date" treated as living (D2). Unknown → living (conservative).

### 5.2 The one gate

```swift
public enum EndpointClass: String, Sendable { case local, privateLAN, remote }   // new; today only isLocalEndpoint exists

/// THE enforcement point. Every byte that leaves for a model transport is produced here and nowhere else.
public enum RemoteSerializer {
    public static func toolResultBlock(_ result: ToolResult, endpoint: EndpointClass, policy: DataClassPolicy) -> ToolResultBlock
}
```

`DataClassPolicy` is a value with one method, `permits(class, subjects, endpoint) -> Bool`; the default instance encodes the table above. When a result is not permitted, the block carries the item **ids and kinds only** plus `"redacted": "familyMedia"` — the model still learns *that* evidence exists and can cite the id; the verifier can still re-derive locally. There are exactly two transports (`ClaudeMessagesClient`, `OllamaToolClient`) and both take a `[ToolResultBlock]`, never a `ToolResult` — the type system makes bypassing the serializer a compile error (C++: the transport's parameter type is the *serialized* type; there is no overload taking the raw one).

`EndpointClass` is derived once per turn from the host: `isLocalEndpoint` → `.local`; `HallieWebPeer.isPrivate`-style RFC 1918 test → `.privateLAN`; everything else, including any `https` host and `api.anthropic.com`, → `.remote`. The Ultra on the LAN is `.privateLAN` and treated like local for data class (it is Rick's machine), but the policy table keeps the column so a future "LAN but not ours" host can be stricter.

### 5.3 The sensor that proves it

`RemoteEndpointSensorTests` (Swift Testing, `VideoScanTests/`):
1. **Unit:** every `DataClass × living × immediateFamily × EndpointClass` cell of the policy table, including the "unknown living status" row.
2. **Poisoned transport:** a `RecordingTransport` conforming to the same protocol as `ClaudeMessagesClient`, capturing every request body. Fixtures: the synthetic 5-generation tree, a 40-record catalog whose transcript and caption fields contain canary strings (`CANARY-TRANSCRIPT-7f3a`, `CANARY-CAPTION-91be`) for a *living immediate* fixture person and for a deceased one. Run the strict corpus through `HallieAgentLane` with a scripted model (fixture tool plans). Assert: (a) no request body contains either canary when `endpoint == .remote`; (b) with `endpoint == .local` the canaries **do** appear (the test proves the gate, not an absence of data); (c) the id of the canary record *does* appear in remote bodies (redaction keeps ids).
3. **Isolation:** with `UserDefaults` poisoned (`archivist.ollamaHosts` pointing at a public host, `hallie.agentLane.endpoint` tampered), the class still derives `.remote` and the gate holds.
4. **Scale:** 100k-record presence snapshot through `search_media` → serializer under the §6 budget; the serializer never iterates records, only the ≤ 25 items.

This sensor is the acceptance test for phase 0 and runs in CI and the nightly.

---

## 6. The agent loop

### 6.1 Budgets (one struct, injected; the app and the eval use different instances)

```swift
public struct AgentBudget: Sendable {
    public var maxModelCalls = 6         // plan + ≤4 tool rounds + submit
    public var maxToolCalls = 8          // across the turn
    public var maxResultBytesPerCall = 8 * 1024
    public var maxPromptTokens = 24_000  // system + schemas + history + all results, estimated by bytes/3.5 before send
    public var reservedOutputTokens = 2_048
    public var deadline: Duration = .seconds(20)   // app; eval uses 60 s
    public var consecutiveToolErrorsBeforeFallback = 2
    public static let app = AgentBudget(); public static let eval = AgentBudget(deadline: .seconds(60))
}
```

Any breach → `LaneOutcome.fallback(reason)` and the deterministic lane answers the same question; the reason is logged and counted by the eval (rev-5 invariant 4, unchanged).

### 6.2 Turns

```
HallieAgentLane.run(question, memory, context, budget) async -> LaneOutcome
  prefix   = [tools (catalog order), system (persona + rules + claim grammar, versioned)]   ← cached
  messages = history (this scenario only) + [user: question + <turn-facts> (date, viewer ceiling, mode, settled subject ids)]
  loop:
    guard !deadline.passed, calls < max else fallback(.budget)
    response = try await transport.send(prefix, messages, stream: true)         ← tokens streamed, see 6.5
    switch response.stopReason:
      .refusal          → decline(.refusal)            // spoken as an honest "I can't help with that one"
      .maxTokens        → fallback(.truncated)
      .endTurn, .toolUse:
         uses = tool_use blocks
         if uses contains submit_answer → return verify(submit, turnResults)      // §7, §8
         if uses.isEmpty → fallback(.noSubmission)      // prose without a submission is never spoken
         messages += assistant(response.content)
         results = await withThrowingTaskGroup { for u in uses { run tool u } }   // read-only ⇒ parallel; order preserved
         turnResults += results                          // the verifier's provenance set
         messages += user(results.map { RemoteSerializer.toolResultBlock($0, endpoint, policy) })   // ALL results in ONE user message
```

Rules: unknown tool name or schema-invalid args → `tool_result` with `is_error: true` and an enum error (the model can recover once; two consecutive → fallback). `tool_choice` is `auto` (forced `any`/`tool` is a 400 on the 5.5 generation and Fable 5.1); the system prompt requires the turn to end with `submit_answer`. Thinking: adaptive, omitted from the request (on by default on these models); `output_config.effort` comes from the lane policy (§9). Tool results are wrapped as data and labelled so; the adversarial suite (planted instructions in a GEDCOM NOTE and a transcript fixture) asserts no behaviour change (rev 5 §11.3).

### 6.3 Prompt caching

Order is `tools → system → messages`, so the stable material goes first and one explicit `cache_control` breakpoint sits on the **last system block**; the growing tail (tool rounds within the turn, and the scenario history across follow-ups) uses top-level automatic caching. Rules that keep the prefix byte-stable, each pinned by a test (`AgentPromptStabilityTests`: two consecutive requests must have identical bytes up to the breakpoint):
- tool order = catalog order; schema JSON encoded with sorted keys; no timestamps, viewer names, ids or mode in the system prompt — those go in the first user block after the breakpoint;
- the system prompt and tool descriptions carry a version (`promptVersion`) that is part of the cache key *and* the eval report; changing wording is a version bump, not a silent edit;
- one model per turn (caches are model-scoped; §9 picks before the first call, never mid-turn).
TTL: default 5 minutes. Within a turn the calls are seconds apart; across Rick's turns a 20-minute pause misses, which costs one prefix write (~4k tokens ≈ $0.01 on Sonnet) — not worth the 2× write price of the 1-hour TTL. The nightly eval runs continuously and stays warm. The minimum cacheable prefix on these models is 512 tokens; ours is ~3.5k. Verification: `usage.cache_read_input_tokens` is logged per call and the eval report prints the hit ratio; zero across a run means a silent invalidator slipped in.

### 6.4 Cancellation and the deadline

One `Task` per turn. The deadline is a `Task.sleep` raced against the loop in a task group; whichever finishes first cancels the other (C++: a `stop_source` fired by a timer thread). `URLSession` streaming tasks honour cancellation; tool `run`s check `Task.checkCancellation()` between engine calls; a cancelled turn produces `fallback(.deadline)`, and the deterministic lane runs with whatever time is left (it has its own 20 s translator timeout today — the two must share the deadline, so `Context` gets a `deadline` and the translator honours it; small change, listed in §11 phase 2). The user's Stop button cancels the same task.

### 6.5 Streaming to the UI (what is shown, and what is never shown)

Today no model call streams (`"stream": false` everywhere) and the bubble is appended whole by `HallieResponseCommit`. The agent lane streams the API response, but **unverified prose is never displayed**: a sentence can be removed by the verifier, and a family member must not watch a wrong fact appear and vanish. What streams:
- **Progress chips** derived from tool names as `tool_use` blocks arrive: "looking up Rick Breen…", "reading his paternal line…", "searching the catalog…". These are Swift strings keyed by tool name (a table), not model text. They replace the generic thinking indicator and make a 10-second turn feel attended.
- **The verified answer**, appended whole, as today, through the same `HallieResponseCommit.apply` sinks — no second commit path.
- Optionally (phase 3), the model's `prose` after verification revealed sentence by sentence for warmth; still post-verification.

`isThinking` stays the one flag; a chip strip under the avatar reads the lane's `progress` AsyncStream.

### 6.6 Logging

One line per turn through `appLog` (same sink as `[hallie-mode]`): `[hallie-lane] lane=agent model=claude-sonnet-5-5 effort=medium calls=4 tools=5 in=3812 cacheRead=14210 cacheWrite=3690 out=1420 usd=0.031 ms=6420 outcome=answered claims=4 dropped=0 subjectCheck=ok`. `HallieTranscriptEvent` gains optional `lane`, `model`, `usage`, `costUSD`, `droppedClaims`, `fallbackReason` (additive; old logs decode). The eval reads them for the A/B report.

---

## 7. Claims, citations, verification

Rev 5 §3.1 is the contract and is unchanged: typed `ClaimPayload`, cited ids, re-derivation per kind, canonical sentence per kind written by Swift, inferences only from the whitelist and only as "it looks like". Two additions:

1. **Turn-local provenance.** A citation is valid only if its id appeared in a `ToolResult` *of this turn* (`turnResults`). The verifier does not look ids up in the live stores first; it looks them up in the turn's result set, then re-derives. A fact about a person no tool returned this turn is dropped even if true. This is the rule that makes "the subject from the previous turn leaked forward" (Henry VIII → Philippa) impossible: Philippa's id was never returned this turn, so nothing about her can be said.
2. **Prose after claims.** The surviving claims become canonical sentences; the model's `prose` is then checked by the existing `HallieCompositionVerifier.verify(_:plan:personaName:)` (every sentence cites `[cN]`; no new year/number/name beyond the cited claims; filenames and dates exact). If prose fails, the canonical sentences are spoken (plainer, still right) — today's "template on model timeout" behaviour, by design.

### 7.1 `submit_answer`

```json
{"questionReading": "one sentence: what the asker wants",
 "subjectIDs": ["gedcom:@I40@"],  "unresolved": ["Henry VIII"],
 "outcome": "answered | declined | needsClarification",
 "declineReason": "notInTree | ambiguous | noMedia | noKnowledge | outOfScope | none",
 "claims": [{"id": "c1", "kind": "relationship", "cites": ["gedcom:@I1@","gedcom:@I40@","q:…"], "value": "greatGreatGrandfather(paternal) path=[…]"}, …],
 "prose": "Your paternal great-great-grandfather is John Breen [c1], born 1850 in Boston [c2][c3].",
 "offers": ["openFamilyTree", "showPhotos"]}
```

(The full JSON Schema, with the typed claim payloads per kind, is in the E1 spec §5.1 and `docs/hallie_tools.schema.json`.) Swift decodes into `AnswerProposal` (rev 5 §3.1 types); decoding failure → `fallback(.malformed)`.

### 7.2 Worked example — the 2026-09-07 "worst one"

> Q: how are we related, if at all, to king henry the 8th?

Agent: `resolve_person{name:"king henry the 8th"}` → `{ok:true, items:[]}` (notes mentioning him are not names — `people(matching:)` is token-exact on NAME records; FamilyTreeNameSearch returns no hit above threshold). `resolve_person{name:"we"}` is not a tool call the prompt allows; "we/I/me" are pre-bound in `<turn-facts>` to the owner id. The model submits `outcome: declined, declineReason: notInTree, unresolved: ["Henry VIII"], subjectIDs: ["gedcom:@I1@"]`, prose "Henry VIII isn't in this tree [c0]…", and may add a `familyItem`/`catalogCount` claim: "three people in the tree are recorded around his court" citing the `tree_people_where{filter{…}}`… — no: that filter does not exist, so it cannot cite it, so it cannot say it. (Adding a `notes_mention` tool later would make that sentence sayable; until then it is honestly absent.) Swift speaks the canonical decline with the offer "want me to look at who in the tree lived at his court?" only if a tool can back it. Nothing about Philippa can appear: her id was never returned this turn.

---

## 8. "Decline over guess", enforced structurally

Five properties; each is a test, not a prompt line.

| # | Property | Mechanism | Test |
|---|---|---|---|
| D-1 | No fact without a verified claim | only canonical sentences from surviving claims are spoken; uncited factual prose is removed (`HallieCompositionVerifier`) | `ClaimVerifierTests`: wrong value / missing id / foreign id / prior-turn id → dropped |
| D-2 | No subject without a resolved id | **SubjectCheck**: every name phrase in the question that `resolve_person` returned candidates for must be in `subjectIDs`; every name phrase that returned none must be in `unresolved`; `subjectIDs` ⊆ this turn's ids. Any miss → the turn becomes a decline naming the gap ("X is not in this tree") — Swift's sentence, not the model's | `SubjectCheckTests`: Henry VIII, "stephen parker and stephen parker jr" (two subjects, both must appear), "dad" rebound to Richard Sr |
| D-3 | A fallback never answers a different question | fallback runs only on *no submission* (deadline, malformed, budget, refusal); it runs the existing chain, whose cross-family fallbacks are already mode-gated (two-mode design §3.4C); **plus** its result passes the same SubjectCheck against any `resolve_person` results already gathered this turn | `FallbackSubjectTests`: scripted model times out after resolving "Henry VIII" → empty; deterministic lane's biography of the owner is refused → decline |
| D-4 | Ambiguity is a question, not a pick | `resolve_person` returns several candidates; the model must `needsClarification` or ask `relatives`/`person_facts` to disambiguate; submitting with two unrelated candidates in `subjectIDs` for one slot is a SubjectCheck failure | `AmbiguityTests`: two Richard Breens → which-one with qualifiers (never "Richard or Richard?") |
| D-5 | Declines are never dead ends | `declineReason` → a canonical offer table (notInTree → "search the tree for a name like X?"; noMedia → tree card if the tree knows the person — the 10/02 "show ellen ronan" case); the `dead_end_decline` flag in `grade_record` is the sensor | `DeclineOfferTests` + strict rows |

Why this beats another cue: a cue is a *recall* mechanism — it fires when the words match. The five properties are *gates* — they fire when the evidence is absent, whatever the words. The model is free to misread the question; it is not free to speak about anyone it did not look up.

---

## 9. Model selection (the eval decides; the policy is data)

```swift
public struct HallieLanePolicy: Sendable {
    public struct Row: Sendable { let mode: HallieMode; let turnKind: TurnKind; let lane: Lane; let model: ModelID; let effort: Effort }
    public let rows: [Row]                                   // first match wins; last row is the default
    public static let initial = HallieLanePolicy(rows: [
        .init(mode: .unknown, turnKind: .social,    lane: .agent, model: .haiku55,  effort: .low),
        .init(mode: .tree,    turnKind: .fresh,     lane: .agent, model: .sonnet55, effort: .medium),
        .init(mode: .tree,    turnKind: .followUp,  lane: .agent, model: .sonnet55, effort: .low),
        .init(mode: .catalog, turnKind: .fresh,     lane: .agent, model: .sonnet55, effort: .medium),
        .init(mode: .catalog, turnKind: .followUp,  lane: .agent, model: .sonnet55, effort: .low),
        .init(mode: .unknown, turnKind: .fresh,     lane: .agent, model: .sonnet55, effort: .medium),
    ])
}
```

`TurnKind` comes from the existing classifier and memory (social / fresh / follow-up / repair). Candidates and the recommendation before E1 (D3, D4):

| Model | Role | Why |
|---|---|---|
| `claude-haiku-5-5` | social, capability, help turns; maybe follow-ups | ~20× cheaper than Sonnet; social turns need no tools |
| `claude-sonnet-5-5` | **default runtime brain** | strong tool use; $2/$10; per turn ≈ $0.03 |
| `claude-opus-5-5` | lineage / multi-hop relationship turns *if* Sonnet trails on them | 2× Sonnet; try `sonnet effort: high` first (lower effort on a newer model often matches the tier above) |
| `claude-fable-5-1` | **judge** in the nightly advisory lane (LLM-as-judge over Sonnet's answers), reference run on the strict lane; not runtime unless E1 shows a gap worth 5× | $10/$50; 128K output; adaptive thinking always on |

The runtime brain is whichever row the E1 report fills in; the policy is a table so the cutover is a data edit. One model per turn, chosen before the first call (cache is model-scoped). Local lane rows (`lane: .local, model: .ollama("qwen…")`) are the offline fallback and the only rows when `EndpointClass.remote` is unreachable.

**Effort.** Adaptive thinking is on; `effort` is the only knob and it is per row. `low` for social/follow-ups, `medium` default, `high` only where the eval shows a gain (thinking tokens are billed as output: at Sonnet's $10/M, 1,000 thinking tokens is a cent per turn).

---

## 10. Why this is the industry pattern (for Rick's next projects)

Stated plainly, with the usual names, so the techniques transfer:

- **Tool use / function calling.** The model emits a structured call (`name` + JSON arguments) against a declared JSON Schema; the host executes and returns a result block; the model continues. Popularised in 2023 (OpenAI "function calling", Anthropic "tool use"); the research lineage is *Toolformer* (Schick et al., 2023) and *MRKL* (Karpas et al., 2022). `strict: true` adds constrained decoding so arguments always validate. In C++ terms: the model is an RPC client that only knows IDL-declared procedures; the host is the server and owns authorization.
- **The agent loop (ReAct).** Reason → act (call a tool) → observe (read the result) → repeat until done (*ReAct*, Yao et al., 2022). Our `HallieAgentLane` is exactly that loop with a budget and a deadline. The rev-5 "planner" shape is the one-shot version (plan all calls up front) — the right choice for a weak model, the wrong one for a strong model that benefits from reading results before choosing the next step.
- **Agentic RAG.** Classic RAG (Lewis et al., 2020) retrieves once, then generates. Agentic RAG lets the model decide *what* to retrieve, *how many times*, and *when to stop*, with retrieval exposed as tools. Our catalog is the retrieval layer; the tree, CyberBrain and catalog are the stores.
- **GraphRAG.** Microsoft's GraphRAG (Edge et al., 2024) builds a knowledge graph from text and lets the model traverse it. We are in the lucky position of *already having* the graph — the GEDCOM — so `relatives`, `relationship_between`, `ancestor_line` are graph traversals with exact answers, no entity extraction needed. The text-side (transcripts, captions, notes) is where a future local embedding index would add the "semantic" half.
- **Grounding and citations.** The output must point at retrieved evidence, and a checker verifies the pointer (often called *attribution* or *faithfulness* checking). Our twist is stronger than most: the citation must be an id returned *this turn*, and the value must *re-derive* from the source in code — the model proposes, Swift verifies. This is the pattern Anthropic documents as "citations" for documents, applied to structured data.
- **Abstention / selective prediction.** Letting a system say "I don't know" is studied as *selective QA* (Kamath et al., 2020) and calibration. Our §8 does it structurally: the decline is what remains when the gates fail, not a confidence threshold.
- **LLM-as-judge evals.** Using a stronger model to grade another's answers against a rubric (Zheng et al., 2023, "Judging LLM-as-a-judge", MT-Bench). We keep the deterministic `grade_record` flags as the gate and add a judge only in the *advisory* lane, because judges inherit the biases of their model; a judge never decides a cutover (rev 4's ≥ 200-questions-per-category rule stands).
- **Prompt caching.** Transformer inference recomputes the attention state (the KV cache) for every token of the prompt; providers let you pin a *prefix* so repeated prefixes are served from cache at ~10% of the price (Anthropic, 2024; the same idea as "prefix caching" in vLLM/SGLang). It only works if the prefix is byte-identical — hence §6.3's discipline about ordering and timestamps.
- **Structured outputs.** JSON-Schema-constrained decoding for the model's reply; here used through `submit_answer`'s strict schema so the proposal always decodes into `AnswerProposal`. The same mechanism exists as `output_config.format` for plain replies.

What is *not* standard and is ours: the data-class gate in the serializer type (§5), turn-local provenance (§7), and the SubjectCheck (§8). Those are the parts worth writing up when the eval shows they work.

---

## 11. Phased plan, with the tests for each phase

Every phase ships along the five CLAUDE.md dimensions (logic, scale, media matrix where media is opened, isolation, sensor). No phase edits `commitHallie` or the response-commit path beyond adding sinks.

| Phase | Work | Tests |
|---|---|---|
| **0 — Contract + tools (Swift, no model)** | `ClaimPayload`/`Citation`/`AnswerProposal` (rev 5 §8.1 0.1–0.4, unchanged); `AgentTool`, `AgentToolCatalog`, `ToolResult`, `DataClass`, `FamilyMembership`, `EndpointClass`, `RemoteSerializer`, `ClaimVerifier` with turn-local provenance, `SubjectCheck`; schema export to `docs/hallie_tools.schema.json` | `ToolAdapterTests` per tool (fixture tree + 40-record catalog + CyberBrain; privacy ceiling; truncation flag; budget clamp); `RemoteEndpointSensorTests` (§5.3); `ClaimVerifierTests`, `SubjectCheckTests` (§8); `ToolSchemaGoldenTests` (catalog → JSON equals the committed file); **scale:** 16,383-person graph + 100k presence snapshots through every tool under a stated budget; **isolation:** poisoned UserDefaults, no globals read by tools |
| **1 — E1 harness (Python, parallel with 0)** | see `hallie_e1_experiment.md`; the schema file is shared | `tests/test_hallie_e1.py` offline (dry-run); the go/no-go report |
| **2 — Claude client + agent lane, flag off** | `ClaudeMessagesClient` (URLSession, SSE streaming, usage decode, retries on 429/5xx, 20 s deadline) — one wrapper, no SDK exists for Swift; `HallieAgentLane` actor; `HallieLanePolicy`; API key in the **Keychain** via `SecItem*` (there is no Keychain precedent in the app; the web passphrase in UserDefaults is the anti-pattern to not repeat — D6); `hallie.agentLane.enabled` default off; shell `--lane agent`; `hallie_eval.py --lane agent`; `Context.deadline` shared with the translator | `ClaudeMessagesClientTests` against a local fake SSE server (stream parse, cancellation mid-stream, 429 retry, malformed event); `HallieAgentLaneTests` with a scripted transport (happy path, no-submission, hallucinated tool, two errors → fallback, deadline → fallback, refusal → decline, parallel tool round keeps order); `AgentPromptStabilityTests` (byte-identical prefix); adversarial injection rows; **isolation:** key never in logs/transcripts (grep sensor on the log sink); **scale:** 775-turn replay stays within the eval budget and prints cache hit ratio |
| **3 — Shadow + cutover** | nightly runs both lanes on the M4 (agent lane via API, deterministic baseline); per-category deltas; `HallieLanePolicy` rows flipped per rev-5 §7 rule (≥ 200 questions/category, 3 seeds, 0 unverified, 0 wrong-subject); progress chips in the UI; transcript fields; $/day cap in Settings | strict lane green under both lanes; `HallieLanePolicyTests` (first-match, default row, offline → local rows); UI: no O(records) work in view bodies; cost sensor: a run exceeding the cap stops and logs |
| **4 — Local lane parity + coverage** | same catalog over Ollama native tool calling on the Ultra (rev-5 planner shape, one call); Dossier backfill, segments and a local semantic index as **separate designs** feeding `search_media.items[].segment` and a future `search_text` tool | eval `--lane local`; the planner's tool-choice rate re-measured with the real schemas (codex's rev-5 request) |

Phase 2 starts only if E1 "wins" (E1 §1). Phase 0 is worth building regardless: the verifier, SubjectCheck and the serializer gate harden today's lane too (D-3 applies to the deterministic lane on its own).

---

## 12. Decisions for Rick (one per line; recommendation in bold)

- **D1 — Transcripts and captions: `familyText` (cloud OK) or `familyMedia` (local only)?** **Recommend `familyMedia` for E1 and phase 2**; the agent needs evidence *kinds* and ids far more than the words, and we can revisit with E1 numbers in hand.
- **D2 — Who is "living immediate family"?** **Recommend:** the owner + every People-tab profile with a kinship row to the owner, living = no death date; plus anyone in the tree born after 1926 without a death date; unknown → living.
- **D3 — Default runtime brain:** **Recommend Sonnet 5.5 at `medium` effort**, Haiku 5.5 `low` for social turns; let E1 overturn either.
- **D4 — Fable 5.1's role:** **Recommend judge + strict-lane reference only**, not the runtime brain (≈ 5× Sonnet per turn), unless E1 shows it alone clears the gate.
- **D5 — Spend caps:** **Recommend $150 total for E1, $5/day hard cap in the app** (Settings; the lane refuses and falls back when exceeded), with the spend line in every report header.
- **D6 — API key storage:** **Recommend macOS Keychain** (`SecItem*` in the app, `security` CLI item for the Python harness); never UserDefaults, env in launchd plists, or git. This also means moving the web passphrase out of UserDefaults later — separate issue.
- **D7 — Streaming UX:** **Recommend progress chips from tool names + verified answer appended whole**; no token-streaming of unverified prose, ever.
- **D8 — Lane default when both are available:** **Recommend agent lane first for tree/catalog/unknown fresh turns with a 20 s deadline → deterministic fallback; local lane only when offline.**
- **D9 — Inference claims for family viewers:** **Recommend unchanged from rev 3 D2** — dev mode only until two weeks of zero unverified facts.
- **D10 — E1 "wins" threshold:** **Recommend** ≥ +10 points flag-free on strict and ≥ +5 on the full corpus, with unverified-fact = 0, wrong-subject = 0, decline-correctness ≥ baseline, p95 ≤ 20 s.
- **D11 — Review tier:** **Recommend in-house `qa` + swift-expert, no codex pass** (read-only tools; no data-loss path) per the 09-26 spend policy.
- **D12 — Snapshot location for E1:** **Recommend `~/Library/Application Support/VideoScan/hallie-e1/`** (never in git; redaction report in the manifest).
- **D13 — Phase 0 now, regardless of E1?** **Recommend yes** — the verifier + SubjectCheck + serializer gate fix today's wrong-confident class on the deterministic lane too.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Cost runaway (a loop that keeps calling tools; a chatty model) | hard budgets per turn (§6.1), $/day cap (D5), usage logged per call, Batches API for cost-only eval reruns |
| Latency: 4–6 round trips at 1–2 s each plus tool time | `effort: low` on follow-ups; parallel tool rounds; progress chips; 20 s deadline → deterministic answer, never silence |
| Misclassifying a living immediate relative as deceased/non-family | conservative default (unknown → living); People tab is the source of truth and is reviewed by Rick; the sensor includes an "unknown death date" fixture |
| Transcript/caption words leak via a *filename* or *note* that quotes them | filenames/notes are `familyText` by Rick's ruling; if a note is found to carry transcript text, the note tool classifies it `familyMedia` (policy row, one line) |
| Prompt injection via GEDCOM NOTE / transcript / CyberBrain text | results are labelled data; no write tools; `OfferedAction` only from verified claims; adversarial rows in CI (rev 5 §11.3) |
| API drift (model ids, thinking params, forced tool choice, SDK shapes) | pin model ids and `promptVersion` in the eval meta; the `claude-api` reference's drift table is the checklist; `ClaudeMessagesClient` isolates all wire shapes in one file |
| Python E1 tools weaker than Swift engines → E1 under-reports the agent lane | `tool_gap` tagging (E1 §2); a win under handicap is a real win; a loss is re-run after phase 0 can export the Swift tools' results as fixtures |
| Thin categories give false confidence (clarify 26, lineage 15 rows) | rev-4 minimum (≥ 200/category, 3 seeds) before any cutover; the report marks under-sized categories |
| Switching models per turn kind fragments the cache | prefix is ~3.5k tokens; a miss costs ≈ $0.01; acceptable, measured in the hit-ratio line |
| Offline (no internet) or API outage | `EndpointClass.remote` unreachable → local-lane rows; the deterministic lane always answers |
| Rick's Claude usage cap / extra-usage reserve | E1 bills the API key, not the plan; spend is reported anyway |
| Two tool rounds exceed the prompt budget with large results | per-call byte caps + aggregate token estimate before each send; `truncated` is explicit so the model narrows |
| Verified-but-plain answers feel cold when prose fails | canonical sentences already carry Hallie's wording per kind (rev 5 §3.1); phase 3 may re-phrase *verified* sentences with a cheap second call |

---

## 14. Cross-references

- Rick's ruling and the experiment summary: `hallie_proposer_with_tools_design.md` §R6.
- Claim contract, knowledge tiers, budgets, cache rules: same doc §3, §3.1, §4, §6, §8b.
- Mode and the deterministic lane's gates: `hallie_two_mode_design.md` §3.4.
- Compound / filter queries (the `tree_people_where` shape): `hallie_compound_and_filter_queries_2026_10_09.md`.
- The failure class this removes: `docs/guides/hallie_live_failures.md` ("The shape behind most of them"; the 09-07 Henry VIII entry; 09-21 Dad Breen; 09-26 Dafydd).
- CyberBrain retrieval and privacy: `cyberbrain_design.md` §6.4, §8.
- Experiment: `hallie_e1_experiment.md`.
- North star check: `docs/project_goals.md` goals 5 and 6 ("Every answer says where the fact came from"; "never invent a family fact, an identity or a date").
