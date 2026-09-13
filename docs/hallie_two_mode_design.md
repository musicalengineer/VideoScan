# Hallie — two-mode session state (Catalog / Family tree)

Status: **ACCEPTED for implementation**, 2026-09-13 (Rick: "implement hallie two mode"; steps 0–4 first on feature/hallie-two-mode). Rick's direction: *"Hallie kinda needs 2 modes (automatically switching): catalog/archive questions and family-tree questions (including bios)."* Scope: a session-level `HallieMode`, a pure classifier, per-mode continuation context, and gating of which lane runs first and which fallback is permitted. **Not** a rewrite of the detectors, the translator, or the executors. Baseline: main `3e663856`.

Codex is concurrently extracting `commitHallie` (`ArchivistChatWindow.swift:1277-1401`) plus its two call sites (`:1180`, `:1263`) on `refactor/hallie-boundaries-20260913`. This plan does not edit that function or those lines; §6 lists the one adjacent site to coordinate.

---

## 1. Current routing architecture

### 1.1 Where a turn enters

| Step | Anchor |
|---|---|
| Typed text → `ask(_:)`; pending which-one replies are consumed first | `VideoScan/VideoScan/ArchivistChatWindow.swift:1027-1097` |
| `askLocally(_:)` captures the selected record, splits conjunctions, runs one coordinator call per clause | `ArchivistChatWindow.swift:1101-1198` |
| `HallieAppTurnCoordinator.execute(question:records:referent:…memory:…telling:drill:picker:)` | `VideoScan/VideoScan/HallieAppTurnCoordinator.swift:468-683` |
| Modal states that own the turn before anything else: picker → drill → pronunciation → telling → photo caption | `HallieAppTurnCoordinator.swift:489-523` |
| Spelling repair of the opener, catalog-stats snapshot, then the model-free step off-main | `HallieAppTurnCoordinator.swift:525-546` → `preTranslationOffMain` `:715-771` |
| Shell client: same `preTranslation` call with its own `Session.memory` | `VideoScan/VideoScan/HallieShellCLI.swift:692-743` (Session), `:1001-1020` (call) |
| Web client: one `ConversationMemory` per browser session | `VideoScan/VideoScan/HallieWebBridge.swift:45`, `:225`, `:288` |

### 1.2 The deterministic chain (`HallieTurnExecutor.preTranslationSingle`)

`VideoScan/VideoScan/HallieTurnExecutor+Conversation.swift:801-963`, in this exact order:

1. Repair turn about the last answer — `:819` (`HallieRepairTurn.isRepair`, `HallieRepairTurn.swift:95-125`)
2. Bare "yes" to a pending retry offer — `:832` (`memory.pendingOffer`)
3. Selection-date question with a row selected — `:843`
4. Capability question — `:850`; help / small talk / reset — `:853`
5. Persona question ("where were you born, Hallie") — `:865`
6. **Record recogniser** (a named file / "this video") — `:880` (`ArchivistRecordQuestion.detect`)
7. **Bare name = biography** via the exact-name identity oracle — `:896` (`HallieBareNameQuestion.detect`, `HallieBareNameQuestion.swift:52-79`; `NameIdentity` `:83-99`; `isExactPersonName` `:104+`)
8. General-advice gate — `:919-930`; **bare field follow-up about the last graph person pulled ahead of it** — `:939-945` (`ArchivistFollowUpResolver.graphAttributeResolution`, `ArchivistFollowUpResolver.swift:242-299`)
9. **Knowledge lanes** `knowledgeLaneTurn` `:970-1054`: app navigation `:980` → surname reference `:987` → media-activity ask `:993` → tree correction `:1000` → family-wide service `:1013` → **biography/field detector** `HalliePersonFactQuestion.detect` `:1017` (`HalliePersonFactQuestion.swift:6-76`, opener regex at `:46`, oracle guard at `:72`) → property ask `:1026` → trail paging `:1042` → **`HallieLineageQuestion.detect`** `:1048` (`HallieLineageQuestion.swift:154-420`; tree statistics `:207`, superlatives `:213`, kinship apposition `:331`, kinship `:332`)
10. **Catalog lanes** `catalogLaneTurn` `:1060-1099`: relationships overview `:1071` → research `:1077` → roster `:1084` → provenance `:1089` → **catalog-wide stats** `:1095` (`HallieCatalogStats.detect`, `HallieCatalogStats.swift:165-233`)
11. **Follow-up resolver** `followUpTurn` `:1104-1201` → `ArchivistFollowUpResolver.resolve` (`ArchivistFollowUpResolver.swift:186-217`): paging `:359` → local family-tree shape `:399` → newest/oldest `:485` → media action `:557` → graph attribute `:242` → refinement (`ArchivistFollowUpResolver+Refinement.swift:266-344`). `.none` → pronoun rewrite (`HalliePronounContinuity.rewrite`, `:1118`) → **`.translate`**.

### 1.3 After `.translate` (the model step)

`HallieAppTurnCoordinator.swift:573-656`: demand-start Ollama → `generalVerdictOffMain` `:592` (Swift decides general-knowledge vs archive) → `interpretTurn` `:605` → `.archive(ast)` executes as-is; `.conversation(kind)` is re-checked by `HallieConversationGuard.requiresArchive` (`HallieTurnInterpretation.swift:98-130`; note `archiveWords` `:73-87` already mixes catalog and kin vocabulary in ONE set) and, if so, re-translated with the archive-only schema `:627`.

There is **no post-translation check that the AST's family (catalog vs graph) agrees with what the sentence asked**. That is the hole every strict miss went through.

### 1.4 Execution and its own cross-family fallbacks

`HallieTurnExecutor.execute` `HallieTurnExecutor.swift:973-1219`:

- `.presence` → `photoAsk` (tree person's photo, never a catalog search) `:985`, else presence executor.
- `.aggregate` → `HallieAggregateFallback.route` `:1126` can turn an unresolved anchor into a **presence search** `:1131` or a surname tree `:1138`, else decline.
- `.graph` → relative facts `:1163`, common ancestor `:1171`, then `graphPreflight` `:1186` (`HallieTurnExecutor+GraphPreflight.swift:26-101`) whose step 0 `placeQuestionAsCatalogSearch` `:115-141` turns a graph question into a **catalog cross search**.

Those two are the *executor-level* catalog fallbacks a tree-mode session must be able to refuse.

### 1.5 Where conversation context lives

`HallieTurnExecutor.ConversationMemory`, `HallieTurnExecutor+Conversation.swift:15-322`:

| Field | Line | Meaning |
|---|---|---|
| `lastResultSet` / `lastShownList` | `:26`, `:31` | last cited list (AST + citations + counts) |
| `lastRefinable` | `:36` | list a non-list answer carries (`.list(ast)` or `.wholeCatalog`) |
| `lastAST`, `lastChain`, `lastPeople`, `lastYears` | `:44-50` | last executed AST and refinement chain |
| `lastSubject` | `:58` | the ONE person the last answer was about (canonical) |
| `lastPhotoAttachment` | `:62` | photo shown last turn |
| `lastExchange` | `:70` | question/route/outcome/answer/candidates for repair |
| `lastRecordDecline`, `pendingOffer` | `:77`, `:89` | record gap; one-reply retry offer |
| `pronounReferents` | `:288` | `[lastSubject]` or `lastPeople` |
| `followUpSnapshot` | `:308-322` | **nil unless `lastAST` or `lastResultSet` is set** |

`record(intent:result:question:)` `:125-219` sets all of it. Holders: app `@State hallieMemory` (`ArchivistChatWindow.swift:277`; written only inside `commitHallie` at `:1300`), shell `Session.memory` (`HallieShellCLI.swift:736`), web `session.memory` (`HallieWebBridge.swift:288`).

Existing "mode-like" precedent: telling / drill / picker sessions ride on `Response` (`HallieAppTurnCoordinator.swift:94-102`) and are stored by `commitHallie` (`:1297-1299`). **The new mode must not follow that precedent** — it should live inside `ConversationMemory` so (a) all three clients get it through the `record` call they already make and (b) `commitHallie` needs no edit while codex owns it.

What memory does **not** keep: the offered actions (`Result.offeredActions`, `HallieTurnExecutor.swift:552`), whether the last question was a *count*, the relation last asked about, or any notion of which family of question the conversation is in.

---

## 2. Where each observed misroute happens

| Case | Path taken | Why the fallback fired |
|---|---|---|
| **strict-005** "tell me all about Edward III" | Before `81ac3f7e`: opener regex at `HalliePersonFactQuestion.swift:46` was exactly "tell me about" → no lane → `.translate` → model `presence person=edward iii keyword=all about`. Now fixed by regex widening. | Structural residue: `:72` `guard relative \|\| isKnownPerson(subject) else { return nil }` — any "about X" whose X the oracle rejects still falls to the translator and a catalog search. In tree mode that must be a decline ("not in the tree"), never a search. |
| **strict-004** "whom did he marry" / **strict-015** "tell me about his parents" | Fixed (`HallieLineageQuestion` spouse shape; `HalliePersonFactQuestion.swift:24-25` steps aside for pronoun kin). | Structural residue: `followUpTurn` `.none` → `HalliePronounContinuity.rewrite` → `.translate` (`+Conversation.swift:1118-1121`) is mode-blind; the translator may still return `presence`, and nothing checks. |
| **cs030** "play the longest video in the archive" | `HallieCatalogStats.detect` nil ("longest" is not in its vocabulary, `HallieCatalogStats.swift:121-147`). `mediaResolution` (`ArchivistFollowUpResolver.swift:557-653`): verb `play`, content = `["longest","archive"]` — "catalog" is referent filler (`:537`) but **"archive" is not** — no items → `.searchThenPlay("the longest video in the archive")` `:652` → translator → `aggregate anchorPeople:["archive"]` (prompt describes aggregate as "who appears with named anchorPeople", `OllamaQueryTranslator.swift:~1104`) → `HallieAggregateFallback.route` `:1126` → `.decline`. | No deterministic catalog superlative-by-duration exists; `dateOrderResolution` `:485-516` knows only newest/oldest. The scope word "archive" was read as a person. |
| **cc001→cc002→cc003** count chain | cc001 → `HallieCatalogStats .total` (`+Conversation.swift:1095`) → `refinableQuery: .wholeCatalog` (`HallieCatalogStats.swift:329`) with `intent == nil`, so `record` sets `lastRefinable` but **not** `lastAST`/`lastResultSet` (`+Conversation.swift:168-171`). cc002 "How many of those are from the 90s?": stats detector refuses on the digit (`HallieCatalogStats.swift:173`); `followUpSnapshot` is nil (`:308`); `refinementResolution` sees "how" in `sentenceVerbs` (`+Refinement.swift:148-155`) → `readsAsSentence` → `.none` → `.translate`. The v2 AST has no count intent (`ArchivistQueryAST.swift:46-57`; only the retired v1 prompt had `intent:"count"`, `OllamaQueryTranslator.swift:1262-1270`), so the model returns a plain `presence(1990–1999)` list. cc003 "and how many from the 80s": `scanLeads` peels "and", residual still contains "how" → sentence → `.translate` again. | The **count scope** exists nowhere — not in memory, not in the AST. Each turn re-asks the model from scratch. |
| **lv260911-003** "show me" after Rick's biography | Memory: `lastAST = graph biography`, `lastSubject = "Richard Harding Breen Jr"`, offered actions **not retained**. `graphAttributeResolution`: no field word → nil. `mediaResolution`: verb `show`, words `["me"]`, no items, not `play` → nil (`:604`). Refinement: "show" is a sentence verb → nil → `.none` → `.translate("show me")`. | The turn is elliptical and the thing to show (photo card / "Open in Family Tree" offer) was never remembered. |
| **lv260907-002** highest royalty/title | No lane claims it: tree statistics needs a count ask (`HallieLineageQuestion.swift:207`, `HallieTreeStatisticsQuestion.swift` `countAsk`), superlative kinds are birth/death/children/depth only (`HallieLineageQuestion.swift:98-102`), trace shapes need a trailing "back [to X]" (`:284-309`). → translator → a whole-tree `graph familyTree` (per the advisory artifact `~/Library/Logs/VideoScan/hallie-eval/visible-20260913-1020/advisory.graded.jsonl`, `queryDescription` for `lv260907-002`) → tree summary prose. Zero flags because the corpus row has `expect: kinship` and no `expectedRoutes`/`mustContain`. | Correct answer needs the titled-ancestors route (`docs/hallie_titled_ancestors_design.md`). This design only guarantees the *mode* is right and the fallback is an honest decline. |
| **lv260907-004** "search the family tree for a title like king" | `familyTreeResolution` (`ArchivistFollowUpResolver.swift:399-460`): "family tree" found; `after = ["for","a","title","like","king"]` → the `for` branch `:436-449` → `people = ["title like king"]` → `.localQuery(graph familyTree)` → "I don't find title like king". | A person slot is filled without asking the oracle. Tree-mode subject resolution must reject it. |
| **lv260902-003** Thankful Pratt photo challenge | `HallieRepairTurn.whyCues` (`HallieRepairTurn.swift:40-42`) has "why did you / why are you / why would you / why do you keep" but not "why do you ask" → not a repair; no biography pattern; lineage nil → translator → `graph death` (the sentence says "died") → date answer. | A challenge about Hallie's own *offer* needs (a) a cue and (b) the offer remembered. |
| **lv260907-003** "not in videos, in family tree" (ledger row 2) | Refinement with a subtractive lead → `.declineNotRefinable("I can only drop a person, not a topic word")` (`+Refinement.swift:332-334`). | A follow-up can edit filters but cannot change *family*. This is exactly a mode correction. |

Common shape: **the last resort of the chain is always the translator, and the translator's output is executed whatever family it lands in.** The mode makes that last resort mode-aware.

---

## 3. Design

### 3.1 `HallieMode`

```swift
// HallieMode.swift (new)
enum HallieMode: String, Sendable, Equatable, Codable {
    case unknown   // session start, or a turn that no signal settles
    case catalog   // videos / photos / files / counts / play / reveal
    case tree      // people, relations, vital facts, biographies
}
```

Held on `ConversationMemory` (not on `Response`, not `@State`):

```swift
// HallieTurnExecutor+Conversation.swift — inside ConversationMemory
private(set) var mode: HallieMode = .unknown
/// The user forced it (pill / ":mode" / "in the family tree, not videos").
/// Stays until reset or the user picks Auto. Never persisted.
private(set) var forcedMode: HallieMode?
private(set) var tree = TreeContext()
private(set) var catalog = CatalogContext()
var effectiveMode: HallieMode { forcedMode ?? mode }
```

### 3.2 Per-mode context (the part mode selection alone does not fix)

```swift
struct TreeContext: Sendable, Equatable {
    /// Canonical subject (today's `lastSubject`, kept in sync — not duplicated logic).
    var subject: String?
    /// The relation last asked about the subject ("his parents" → .parents),
    /// so "and their parents?" / "and her husband?" chain off the right person.
    var lastRelation: ArchivistQueryAST.Graph.Relation?
    /// What the last tree answer OFFERED to show: openFamilyTree(Person),
    /// a photo attachment, a gallery offer. "show me" acts on this.
    var lastOffers: [HallieTurnExecutor.OfferedAction]
    var lastPhoto: HalliePhotoAttachment?      // alias of lastPhotoAttachment
}

struct CatalogContext: Sendable, Equatable {
    /// Last list query (today's lastResultSet?.ast ?? lastAST when presence/cross/record).
    var lastQuery: ArchivistQueryAST?
    var resultCount: Int?                       // last exact matchCount
    /// The question was a COUNT ("how many…"); follow-ups stay counts.
    var countScope: CountScope?                 // .wholeCatalog | .query(ast)
    var chain: ArchivistFollowUpResolver.Chain? // alias of lastChain
}
```

Only four fields are genuinely new state: `mode`, `forcedMode`, `countScope`, `lastOffers` (+ `lastRelation`, phase 2). Everything else is a typed view over fields memory already keeps, so `record` stays one function.

Transitions inside `record(intent:result:question:)` (`+Conversation.swift:125`):

- `result.route` ∈ {graph, telling} → `mode = .tree`; ∈ {presence, cross, aggregate, record, temporal} → `.catalog`; `.reset` → `.unknown` + clear forced; follow-up/help/smalltalk/capability/conversation → unchanged.
- A **declined** turn still sets the mode the classifier chose (a "not in the tree" decline keeps you in tree mode). This needs the chosen mode on the `Result`: add `let mode: HallieMode?` (defaulted nil, copied by every copy helper — `HallieResultCopyRoundTripTests` walks them, `HallieTurnExecutor+Conversation.swift:1470-1508`).
- `countScope`: set when `HallieCountAsk.isCountAsk(question)` and the result answered with `matchCount` (→ `.query(ast)`) or was `catalog-stats total/years` (→ `.wholeCatalog`). Cleared by any non-count catalog answer or a tree answer.
- `lastOffers = result.offeredActions` filtered to show-able ones (`openFamilyTree*`, `revealFolder`) plus a synthesized `.showPhoto` when `attachments` carries a photo, on every tree answer; cleared on tree answers with none.

### 3.3 `HallieModeClassifier` (pure)

```swift
// HallieModeClassifier.swift (new)
enum HallieModeClassifier {
    struct Oracle {
        let isExactPersonName: (String) -> Bool   // NameIdentity.isExactPersonName
        let isKnownPerson: (String) -> Bool       // loose oracle
        let isNamedFile: (String) -> Bool         // ArchivistRecordQuestion / record index
    }
    enum Reason: Equatable {
        case forced
        case explicitCue(HallieMode, String)      // "marry", "videos", "in the family tree"
        case subjectResolved(HallieMode, String)  // "Edward III" → tree person
        case sticky(HallieMode)                    // elliptical turn inherits
        case conflict                              // both families cued, nothing settles
        case none
    }
    struct Verdict: Equatable { let mode: HallieMode; let reason: Reason }

    static func classify(_ question: String,
                         memory: HallieTurnExecutor.ConversationMemory,
                         oracle: Oracle) -> Verdict
}
```

Decision order (first that settles wins):

1. **Forced** → that mode.
2. **Scope override phrases** (either family): "in the family tree", "in the tree", "not in (the) videos", "from the tree" → `.tree`; "in the archive/catalog/videos/footage/collection", "not in the tree" → `.catalog`. These beat everything, including stickiness — they are how a user corrects a wrong guess by talking.
3. **Explicit cue words**, two disjoint sets built by splitting today's `HallieConversationGuard.archiveWords` (`HallieTurnInterpretation.swift:73-87`) into `catalogCues` (archive, catalog, video(s), clip(s), recording(s), footage, film, movie, tape, mxf, transcript, caption, file(s), play, watch, reveal, longest/shortest/biggest, "how many videos|clips|files") and `treeCues` (`HalliePronounContinuity.kinNouns` `:29-38` + born, birth, died, death, buried, married, marry, wedding, spouse, ancestor(s), descendant(s), lineage, generation(s), related, relationship, biography, "tell me (all|more|everything) about", "who is/was"). One family only → that mode. Both → step 4.
4. **Subject resolution**: the name phrase after about/of/with/for or a leading possessive; `isExactPersonName` → `.tree`; `isNamedFile` → `.catalog`. A tree person **plus** a media noun ("videos of nathaniel parker") → `.catalog` (media noun outranks the person: that is the existing `.personVideos`/presence road). "photo(s) of <tree person>" → `.tree` (today's `photoAsk`, `HallieTurnExecutor.swift:985`).
5. **Stickiness**: elliptical turn — a third-person pronoun, a lead ("and", "what about", "how about"), or ≤ 4 content words with no cue — inherits `memory.effectiveMode` when it is not `.unknown`.
6. Otherwise `.unknown` (reason `.none` or `.conflict`). Unknown means "today's chain, unchanged"; the classifier never guesses (codex's abstention rule, `docs/hallie_intent_recognizer_design.md`).

Every verdict is logged once per turn like the general lane does (`HallieAppTurnCoordinator.swift:600`):
`[hallie-mode] mode=tree reason=explicitCue(marry) forced=false — "whom did he marry"`.

Worked examples:

| Turn (after…) | Verdict |
|---|---|
| "tell me all about Edward III" (fresh) | tree · explicitCue("tell me all about") |
| "show me" (after a biography) | tree · sticky |
| "show me" (after a list) | catalog · sticky |
| "and how many from the 80s" (after a count) | catalog · sticky (+ countScope) |
| "play the longest video in the archive" | catalog · explicitCue("play"/"video"/"archive") |
| "videos of nathaniel parker" (after his bio) | catalog · media noun outranks subject |
| "photos of nathaniel parker" (after his bio) | tree · photo of a tree person |
| "not in videos, in family tree" | tree · scope override → mode correction (§3.6) |
| "how am I related to King Edward III" | tree · explicitCue("related") |
| "what country?" (after a birthplace) | tree · sticky |
| "Ireland and the UK are part of Europe aren't they?" | unknown → general lane (unchanged) |

### 3.4 Gating: which lane runs first, which fallback is allowed

**A. In `preTranslationSingle`** (`+Conversation.swift:801`): compute the verdict once, after steps 1-7 (repair, offer, selection date, capability, commands, persona, record recogniser, bare name — none of these are mode-dependent and all must keep their precedence). Then:

```
switch verdict.mode
case .tree:
    treeFollowUpTurn(...)            // NEW: "show me", "and his X", bare field (§3.5)
    knowledgeLaneTurn(...)           // unchanged
    catalogLaneTurn(...)             // only provenance / roster / research (mode-neutral)
    followUpTurn(...) with catalog media/paging/refinement DISABLED
    → .translate(question, mode: .tree)
case .catalog:
    catalogCountFollowUp(...)        // NEW: sticky count scope (§3.5)
    catalogSuperlative(...)          // NEW: longest/shortest (§3.5)
    catalogLaneTurn(...)
    followUpTurn(...)                // unchanged
    knowledgeLaneTurn(...)           // still runs: an explicit tree shape mid-catalog flips
    → .translate(question, mode: .catalog)
case .unknown:
    today's order, unchanged
```

`PreTranslation.translate` gains `mode: HallieMode` (default `.unknown` keeps every existing test site compiling).

**B. After translation — `HallieModeGate.reconcile`** (new, pure, shared by the app coordinator at `HallieAppTurnCoordinator.swift:609-633`, the shell at `HallieShellCLI.swift:1038+`, and the web bridge):

```swift
enum HallieModeGate {
    enum Outcome: Equatable {
        case keep
        case rewrite(ArchivistQueryAST, note: String)   // basis note, visible
        case decline(HallieTurnExecutor.Result)
    }
    static func reconcile(ast: ArchivistQueryAST, mode: HallieMode,
                          question: String, memory: ConversationMemory) -> Outcome
}
```

- `mode == .tree` and AST ∈ {presence, cross, aggregate, event}: if the sentence has a media noun → `.keep` (the classifier was overruled by the words; log it). Else, if the AST names one person → `.rewrite(.graph(people:[p], operation: field guards' choice — `ArchivistGraphQuery.asksForRelation/asksForAPlace/asksForABiography`))`. Else → `.decline` "I read that as a family-tree question, but I couldn't tell who it is about — name the person" (route `.graph`, outcome `.declined`, `mode: .tree`). **Tree mode never executes a catalog search.**
- `mode == .catalog` and AST is `.graph`: if a media cue exists → `.rewrite(.presence(people: payload.people))`; else `.decline` "I'm looking in the catalog — did you mean the family tree?" with an `.ask` chip that re-asks under tree mode. **Catalog mode never opens a biography by accident.**
- `.unknown` → `.keep`.

**C. Deterministic cross-family fallbacks become mode-gated** (each a one-line guard on an existing branch, no new logic):

| Fallback | Anchor | Rule |
|---|---|---|
| `.searchThenPlay(remainder)` | `ArchivistFollowUpResolver.swift:604`, `:652` | in tree mode with no media noun → `nil` (falls to tree follow-up / decline) |
| `placeQuestionAsCatalogSearch` | `HallieTurnExecutor+GraphPreflight.swift:32` | in tree mode → decline "not a person I know in the tree", never a cross search |
| `HallieAggregateFallback.route → .presence` | `HallieTurnExecutor.swift:1131` | in tree mode → `.decline` |
| Unresolved biography subject (`HalliePersonFactQuestion.swift:72`) | | in tree mode → `.answer(decline "X is not in the tree")` instead of `nil` → translator |
| `familyTreeResolution` filling `people` | `ArchivistFollowUpResolver.swift:427-449` | require `isKnownPerson`; otherwise decline naming the phrase (fixes lv260907-004's "remember it?" offer) |

The mode reaches the executor through `Context` (add `let mode: HallieMode` with default `.unknown`, `HallieTurnExecutor.swift:415-472`); the coordinator's `captureContext` (`:869`) and the shell's context builder set it from memory.

### 3.5 Per-mode continuation handlers (the acceptance cases)

**Catalog: sticky count scope** — `HallieCatalogCountFollowUp` (new, pure):
- Trigger: `mode == .catalog`, `memory.catalog.countScope != nil`, and the turn is a count ask or an elliptical fragment ("and the 80s?", "how many of those are from the 90s", "what about 2005").
- Extract filters with the existing `extractYears` / `contentGroups` (`+Refinement.swift:373`, `:218`) — reuse, do not duplicate; strip "how many / of those / are / from" as count filler.
- Build `Intent(ast: scope AST with the new year range written over the old one, refinementNote: "counting: <chain>", countOnly: true)`. `ListFields.yearStart/yearEnd` are scalar (`+Refinement.swift:490-514`), so a new decade **replaces** the previous decade rather than intersecting — verify against `applyCumulative` (`~:530-600`) and pin with a test.
- `Intent.countOnly` (new Bool, default false) makes the presence route phrase "N videos from the 1980s" and cite at most a handful, and `record` keeps `countScope` alive. `.wholeCatalog` scope maps to `.presence(.init(mediaKind: nil))` exactly as `dateOrderedTurn` does (`+Conversation.swift:1221`).
- Also fix `followUpSnapshot` (`:308`) to synthesize that AST when `lastRefinable == .wholeCatalog` and `lastAST == nil`, so "of those" has a referent. Guard the media-action path (`declineNoPriorResultTurn` `:1257` already handles `.wholeCatalog`) so "show me the second one" after a count keeps today's behaviour.
- Cancellation / interleaving: an intervening tree question clears `countScope` (mode flips); an intervening unrelated catalog list clears it (non-count answer). Both are tests.

**Tree: "show me" and elliptical kin** — `HallieTreeFollowUp` (new, pure):
- "show me" / "show it" / "let me see" / "open it" with no content and `mode == .tree`: exactly one entry in `tree.lastOffers` → `Result` with `immediateOfferedAction` = that offer (a photo → re-attach `tree.lastPhoto`; `openFamilyTree(Person)` → the same chip path `commitHallie` already performs at `ArchivistChatWindow.swift:1383-1389`, so no new UI plumbing); several → clarification "his photo, or his place in the family tree?" as `.ask` chips; none → "show you what — a photo, or his family tree?" with chips built from the subject. Identity is carried by `personID` where the offer has it (`openFamilyTreePerson`) so a stale action against a renamed profile cannot fire — the same rule codex asked for.
- "and his/her/their parents?", "and the grandparents?", "her husband?" — already claimed by `HallieLineageQuestion.kinship` with a pronoun (`+Conversation.swift:718-737`); the new handler only fills `tree.lastRelation` and, for "and their parents?" after "his parents", resolves "their" to the relatives named in the last answer (phase 2; needs the graph result's named relatives on `Result` — flagged, not in scope).
- Bare field ("what country?") — already `graphAttributeResolution`; unchanged, but in tree mode it runs before the general-advice gate for *every* mode (it already does at `:939`).

**Catalog: duration superlative** — `HallieCatalogSuperlative` (new, pure): "(play|show|find|what is) the (longest|shortest|biggest|smallest|largest) (video|clip|file|recording|one)? (in|of) (the)? (archive|catalog|collection|library)?" → `.run(Intent(ast: .presence(.init(mediaKind: .video)), playAfterAnswer: verb == play, sortOrder: .durationDescending))`. Extend `DateOrderRequest` to an `OrderRequest` with `.newest/.oldest/.longest/.shortest` (`HallieTurnExecutor.swift:234-243`; consumer `+DateOrdered.swift`). Ties are broken by path for determinism; unavailable media goes through the existing honesty gates in `perform`/`play` (`ArchivistChatWindow.swift:1406`, `:1465`). Add "archive", "collection", "library" to `referentFiller` (`ArchivistFollowUpResolver.swift:533`) so "play the longest one in the archive" is a bare referent when a list is up.

**Tree: challenge to an offer** (lv260902-003) — phase 2, but the state it needs lands now: `tree.lastOffers` and `tree.lastPhoto`. The detector is one more `whyCues` family in `HallieRepairTurn` ("why do you ask", "why did you offer/suggest", "why would you want") that, with a photo/gallery offer in memory, answers from `HallieBiographyPhotoOffer`'s own photography-floor knowledge rather than searching. Not in this change; listed so the state is not designed twice.

**Tree: titled ancestors** (lv260907-002/-004) — out of scope; `docs/hallie_titled_ancestors_design.md`. This change guarantees the honest decline in tree mode and the correct `mode=tree` in the graded output so the grader can finally flag those rows.

### 3.6 Surfacing and correcting the mode

**App header pill.** In `identityHeader` (`ArchivistChatWindow.swift:517-650`), under "Family Archivist" (`:612-614`): a small capsule `HallieModePill(mode: hallieMemory.effectiveMode, forced: hallieMemory.forcedMode != nil)` reading "Family tree" / "Catalog" / "Listening" (for `.unknown`), tinted per mode, with a `Menu` on click: **Family tree · Catalog · Automatic**. Choosing one calls `hallieMemory.force(.tree)` / `.force(.catalog)` / `.unforce()` — new mutating methods on memory. `hallieMemory` is already `@State` in the view (`:277`), so the pill needs no change to `commitHallie` and no new state. When technical details are on, the "answered by …" line (`:353-361`) appends " · family tree" / " · catalog".

**Correction by talking.** `HallieModeCorrection.detect` (new, pure): "not in videos, in the family tree", "I meant the catalog", "no, the archive", "check the tree instead" → in `preTranslationSingle` right after the repair step (`:819`): force the opposite mode and **re-run `memory.lastExchange.question`** under it (the same re-ask shape `isTreeCorrection` uses at `:1000-1008`). This closes ledger row 2 (lv260907-003) and gives the user an out that costs one sentence.

**Shell.** `:mode` prints the current mode/forced state; `:mode tree|catalog|auto` forces (`HallieShellCLI.swift:~1419`, beside `:reset`). Diagnostics line "mode: tree (sticky)" after "interpreted: …" (`:1036`).

**Web.** The bridge answer JSON gets `"mode"`; the page shows the same pill text. (`HallieWebBridge.swift:288` records memory already.)

### 3.7 Eval harness: asserting the mode per turn

- `HallieTranscriptEvent` gains `let mode: String?` (`VideoScan/VideoScan/HallieConversationLog.swift:53`, next to `route`), defaulted nil in the initializer so old logs decode.
- Shell: `transcriptEvent(...)` (`HallieShellCLI+Render.swift:35-84`) takes `mode:` from `state.memory.effectiveMode`.
- App: `queueTranscriptWrites` (`ArchivistChatWindow.swift:706-750`) is **outside** codex's hunks (`:1177`, `:1260`, `:1274-1404`). Phase 1 fills `mode` there from `hallieMemory.effectiveMode` for the assistant events being written (accurate for one-clause turns; a split turn logs the last clause's mode). Phase 3, after codex's `HallieResponseCommit` merges, carries it per message via `ArchivistMessage.mode` (`:174`) so multi-clause turns are exact. Flagged in §6.
- `scripts/hallie_eval.py`: `build_records` adds `"mode": ans.get("mode")` (`:252-318`); corpus rows may carry `expectMode: "tree"|"catalog"`; `grade_record` (`:511`) adds flag `mode_mismatch` when set and different. Additive: no existing field, flag, or artifact format changes (codex's note that format changes are a separate decision is respected — this is a new optional key).
- Corpus: `tests/hallie_strict_regressions.json` strict-004/005/015 get `expectMode: tree`; new strict rows for the count chain (cc001-003 as one scenario, `expectMode: catalog`, `mustMatch` a decade count), "show me" after Rick's biography (`expectMode: tree`, `expectedOutcome: answered`, `mustMatchAttachmentOutline` or offered action), cs030 (`expectMode: catalog`, `expectedRoutes: ["presence"]`), lv260907-002/-004 (`expectMode: tree`, `expectedRoutes: ["graph"]`, `mustNotContain: ["remember"]`), lv260902-003 (`expectMode: tree`, `mustNotContain: ["born"]` until phase 2 lands the answer). Expectation edits are reviewed separately from code, per the handoff note.
- `tests/test_hallie_eval.py`: `mode` passes through `build_records`; `mode_mismatch` fires and does not fire; old records without `mode` grade unchanged.

---

## 4. Implementation plan

Each step is independently mergeable and leaves the strict lane green.

| # | Step | Files | Tests (CLAUDE.md dimensions) |
|---|---|---|---|
| 0 | **Pin today's behaviour** for the seven cases as a red/green sensor suite using the `HallieStrictReplayFamilyIntentTests` pattern (fixture GEDCOM + `preTranslation` + `execute`, `VideoScanTests/HallieStrictReplayFamilyIntentTests.swift:80-110`) plus a synthetic catalog (`HallieConversationMemoryTests.swift:14-70` `run` helper). | new `VideoScanTests/HallieTwoModeReplayTests.swift` | Sensor: each case asserts the *current* misroute so the flip is visible in the diff. |
| 1 | `HallieMode`, `HallieModeClassifier` (pure). | new `HallieMode.swift`, `HallieModeClassifier.swift`; split `HallieConversationGuard.archiveWords` into two named sets (`HallieTurnInterpretation.swift:63-87`) and have the guard union them so its behaviour is byte-identical. | Logic: cue tables, subject resolution, stickiness, overrides, conflict → unknown. Scale: 10,000 classifications with an oracle backed by a 40k-person synthetic graph under a stated budget (the oracle is the only O(tree) call; the classifier must ask it at most twice per turn). Isolation: classifier reads no globals. |
| 2 | Memory: `mode`, `forcedMode`, `TreeContext`, `CatalogContext`, `countScope`, `lastOffers`; transitions in `record`; `force/unforce`; `followUpSnapshot` synthesis for `.wholeCatalog`; `Result.mode`. | `HallieTurnExecutor+Conversation.swift:15-322`, `HallieTurnExecutor.swift:538-647` and copy helpers (`+Conversation.swift:1470-1508`, `Result.adding/offering/carryingProvenance/applying` `:650-760`) | Logic: transition table; reset clears; declines keep mode. Isolation: three memories (app/shell/web shapes) do not share state; poisoned UserDefaults has no effect (mode is never persisted — test that `archivist.*` keys cannot pre-set it). Sensor: `HallieResultCopyRoundTripTests` extended for `mode`. |
| 3 | Gate in `preTranslationSingle`; `HallieTreeFollowUp` ("show me"); `HallieCatalogCountFollowUp`; `Intent.countOnly`; `PreTranslation.translate(mode:)`. | `HallieTurnExecutor+Conversation.swift:801-963`, new `HallieTreeFollowUp.swift`, `HallieCatalogCountFollowUp.swift`, `HallieTurnExecutor.swift:145-217` (Intent), `HallieTurnExecutor+Presence.swift` (countOnly phrasing) | Logic: cc001→cc002→cc003 yields two independent decade counts and the 80s replaces the 90s; intervening tree question / unrelated list clears scope; "show me" after biography performs the one offer, asks with two, offers with none; stale `personID` refused. Scale: count re-run over 100k presence snapshots within the existing presence budget (`ArchivistQueryBench.swift`). |
| 4 | `HallieModeGate.reconcile` after translation in all three clients; mode-gated fallbacks (§3.4 C); `Context.mode`. | new `HallieModeGate.swift`; `HallieAppTurnCoordinator.swift:609-633`, `:869-990`; `HallieShellCLI.swift:1038-1100`; `HallieWebBridge.swift:~225`; `ArchivistFollowUpResolver.swift:604,652,427-449`; `HallieTurnExecutor+GraphPreflight.swift:32`; `HallieTurnExecutor.swift:1131`; `HalliePersonFactQuestion.swift:72` | Logic: stub translator returns `presence` for "tell me all about X" in tree mode → no catalog search, honest decline or graph rewrite (`HallieAppV2IntegrationTests.swift:110-180` dependency pattern); returns `graph` for "play donna at the cape" in catalog mode → presence. Isolation: gate is pure. Sensor: strict-004/005/015 with `expectMode`. |
| 5 | `HallieCatalogSuperlative` + `OrderRequest` (duration); `referentFiller` += archive/collection/library. | new `HallieCatalogSuperlative.swift`; `HallieTurnExecutor.swift:234-243`; `HallieTurnExecutor+DateOrdered.swift`; `ArchivistFollowUpResolver.swift:533` | Logic: cs030 resolves locally, deterministic tie order, `playAfterAnswer` set. Scale: sort of 100k snapshots by duration under budget. Media matrix: N/A — no media is opened by this code (playback stays behind `perform`/`play`); state this in the PR. |
| 6 | `HallieModeCorrection` ("not in videos, in family tree") → force + re-ask `lastExchange.question`. | new `HallieModeCorrection.swift`; `+Conversation.swift` after `:819` | Logic: lv260907-003 re-runs row 1 under tree mode; a correction with nothing to re-ask declines honestly. |
| 7 | UI: `HallieModePill` in `identityHeader`; technical-details suffix; shell `:mode`; web label. | `ArchivistChatWindow.swift:517-650`, `:353-361`; new `HallieModePill.swift`; `HallieShellCLI.swift:~1419`, `+Render.swift:35`; `HallieWebBridge.swift`, `HallieWebPage.swift` | Logic: shell `:mode tree` forces and `:reset` clears (shell harness pattern `HallieLiveMissShellTests.swift:1-60`). UI: no O(records) work in the view body — the pill reads one enum. |
| 8 | Transcript `mode`, harness `expectMode` / `mode_mismatch`, corpus rows. | `HallieConversationLog.swift:53`, `HallieShellCLI+Render.swift:35-84`, `ArchivistChatWindow.swift:706-750`, `scripts/hallie_eval.py:252-318, 511-600`, `tests/hallie_strict_regressions.json`, `tests/hallie_eval_corpus.json`, `tests/test_hallie_eval.py` | Logic: python tests for pass-through and the flag; old records unaffected. Sensor: nightly strict lane now asserts mode on the seven rows. |
| 9 | Phase 2 (separate designs, state already in place): titled-ancestors route; photo-offer challenge explanation; `lastRelation` chaining for "and their parents?". | — | — |

Sequencing: 0 → 1 → 2 → 3 → 4 are the core and should land together on one branch (`feature/hallie-two-mode`) with the sensor suite flipping from red to green; 5, 6, 7, 8 can follow as small PRs. Step 8's app-side transcript line is the only item that touches a file codex is editing, and not their hunks.

---

## 5. Risks — what could flip

| Risk | Where | Mitigation |
|---|---|---|
| Stickiness swallows an explicit catalog ask after a biography ("videos of nathaniel parker", "photos of donna" pinned as a catalog search at `HallieLineageQuestion.swift:224`) | classifier step 4/5 | Media noun outranks subject and stickiness; both pinned by tests before the gate lands. |
| Tree mode declines a legitimate translator `presence` for a sentence with an unusual media word ("the Christmas tape") | `HallieModeGate` | The gate's media-noun escape uses the union of `mediaNouns` (`+Refinement.swift:137`), `HallieAggregateFallback.mediaWords`, and `HallieCatalogStats` overview keys — one shared `HallieMediaVocabulary` constant, added in step 1. |
| `followUpSnapshot` synthesis for `.wholeCatalog` changes "show me the second one" after a count | `+Conversation.swift:308`, `HallieConversationMemoryTests` `memoryRecordsOnlyListAnswersAndForgetsOnFreshNoEvidence` (`:224`) | Synthesize only for the refinement/count path; media actions keep `declineNoPriorResultTurn` (`:1238-1293`). Existing test stays as the sensor. |
| `readsAsSentence` still rejects "and how many from the 80s" | `+Refinement.swift:199-214` | The count handler runs *before* `followUpTurn` in catalog mode; refinement itself is untouched. |
| Advisory rows that today are unflagged because they went to the catalog and "answered" (lv260907-002 pattern) will start declining in tree mode and pick up `declined_expected_answer` | grader `:560` | Intended: a decline is the honest answer until the titled route lands. Note it in the corpus row `notes` so nobody "fixes" it back. |
| `HallieAppV2IntegrationTests` depends on "what do you know about X" reaching the translator (`HalliePersonFactQuestion.swift:44-45`) | step 4 | Unknown-mode sentence keeps today's chain; in tree mode the gate rewrites a returned `presence` to a graph biography — which is the answer that test wants anyway. Run the suite in step 4. |
| "tell me about dad" / People-tab aliases (strict-011, GH #180) | `HalliePersonFactQuestion.swift:60-73` | Untouched; bare kin words still bind to the owner before the oracle guard. |
| The general-knowledge lane ("Ireland and the UK are part of Europe…") must not become tree mode by stickiness | classifier step 5 | A full sentence with a verb and no cue is not elliptical; it stays `.unknown`. `HallieGeneralKnowledgeLaneTests` is the sensor. |
| Forced mode surprising the family later in the session | UI | Never persisted; reset clears; pill shows "forced" tint; the correction sentence unforces when it names the *other* family. |
| Codex's `HallieResponseCommit` extraction | `ArchivistChatWindow.swift:1177, 1260, 1274-1404` | This plan edits none of those lines; memory carries the mode so `commitHallie`'s existing `hallieMemory.record` call (`:1300`) is sufficient. The per-message transcript mode is deferred to after their merge (§3.7). |

---

## 6. Overlap with codex's branch

- **Do not touch**: `commitHallie` (`ArchivistChatWindow.swift:1277-1401`), its call sites (`:1180`, `:1263`), `HallieResponseCommit.swift`, `HallieResponseCommitTests.swift`, `HallieAppV2IntegrationTests.swift` hunks in their diff.
- **Adjacent, coordinate**: `queueTranscriptWrites` (`:706-750`) for the transcript `mode` field. Their diff does not include it today; if `HallieResponseCommit` grows to own transcript events, the mode field moves with it. Message them the field name (`HallieTranscriptEvent.mode`) before step 8.
- **Shared, additive only**: `HallieAppTurnCoordinator.Response` is *not* extended (the mode is in memory), so their `Response`-consuming extraction sees no signature change.

---
