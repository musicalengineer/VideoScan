# Kinship inference — validate, derive, confirm, and answer across both worlds

**Status:** PROPOSED 2026-08-29 (Rick: "go"). Design before code. Reviewer: codex.
**Owner:** Claude. **Director decisions taken:** siblings default to FULL; no step/adoptive relations in this generation.

## Why
Rick enters his relationships to everyone in the contemporary People tab (privacy: these people are never on FamilySearch). He wants (1) sanity checks on save, (2) everyone else's relations auto-derived ("Tim is my brother" ⇒ Tim is uncle of my sons, brother-in-law of Donna, son of Dad & Mom…), (3) a one-time, non-tedious confirmation of derivations, and (4) Hallie answering across People-tab people and GEDCOM people alike.

## Model: store primitives, derive everything else
Today: `POIProfile.kinships: [Kinship]` rows `(relation: KinshipRelation, anchor: KinshipAnchor)`; `KinshipRelation` has 12 cases incl. derived ones (grandparent, auntUncle, cousin, in-laws); `FamilyKinshipOverlay` composes paths with a whole-chain table; anchors can point at a profile (uuid) or a tree person (FSID / pointer).

Change: **only four relations are storable primitives** — `parent`, `child`, `spouse`, `sibling` (sibling only when the shared parents are not both recorded; the sheet upgrades it to parent edges when they are). The other eight remain in the enum for DISPLAY/derivation only; the editor stops offering them, and existing rows of derived kinds are migrated on load: kept as `confirmedDerivations` (see below) if the derivation engine reproduces them, else shown in the review sheet as "unconfirmed claim" (never silently dropped; never quarantined).

Graph: undirected `spouse`, `sibling`; directed `parent→child`; nodes = profile uuids ∪ tree persons (by FSID). Inverse edges are implicit (one row, both cards show it). Derivations = path composition over this graph, plus the GEDCOM graph reached through anchors: a profile anchored to a tree person (Rick=GVQV-NW3, Dad=Sr) is the SAME node; contemporaries inherit ancestry through it. Sex from the profile (or tree record) genders the word; unknown sex → neutral word ("sibling", "parent's sibling") never a guess. Birthdates (profile birthday or tree BIRT) give "older/younger" and ages; approximate dates → "about".

## 1. Validation on save (deterministic; every rule a unit test)
Errors (block save, say why): self-relation; a parent/child cycle of any length (DFS over parent edges incl. tree ancestors); > 2 parents; spouse of self; duplicate row.
Warnings (save allowed, shown once): parent not older than child when both birthdates known; spouse birth years > 40 apart; sex-inconsistent gendered term when sex is KNOWN (the editor shows the neutral term); sibling row while both parents recorded (offer "convert to shared parents").

## 2. Derivation engine (`FamilyKinshipInference`, pure, testable)
Input: primitive edge set + anchors + graph. Output: for each ordered pair (a,b) within N hops (N=4 default), the best English term or route text, with the path as provenance. Rules: parent∘parent = grandparent (…great-); sibling-of-parent = auntUncle; child-of-sibling = nieceNephew; child-of-parent's-sibling = cousin (degree/removed via existing kinshipTerm math when through the tree); spouse-of-sibling / sibling-of-spouse = siblingInLaw; parent-of-spouse = parentInLaw; spouse-of-child = childInLaw; anything else = route text (existing behaviour). Half siblings: shared exactly one parent → "half-brother". Never fold through two spouse hops (kept from 8/28 fix). Cost: graph is tiny (dozens of contemporaries) + O(depth) tree walks; memoised per graph generation (existing seam).

## 3. Review sheet (one-time per change set, not per row)
After Save on any profile with new primitives: "Derived from what you entered" — grouped per affected person, one line each: "Tim — your brother → son of Richard Harding Breen Sr & Eileen Latta; uncle of Michael, Kevin, …; brother-in-law of Donna". Buttons: Confirm all · Fix… (opens that person). It STOPS only on genuine ambiguities: sibling with no recorded parents ("full or half? — assuming full"), spouse vs partner, a contradiction between rows on two profiles. Confirming writes `confirmedDerivations: [DerivationConfirmation(pairKey, term, pathHash, by: "Rick", at: Date)]` on Rick's profile (attestation, not an edge). A later edit that changes a confirmed path re-lists just that line.

## 4. Hallie
New/extended shapes on the existing lineage path: "how is Tim related to Martha Lamson", "who are Tim's ancestors", "is Kevin related to Donna's side", "how old was Dad when Tim was born". Resolution: PersonResolver verdict (one verdict rule), then the unified node; answer composed deterministically with basis "from Rick's entries (confirmed 8/29) + the family tree"; CyberBrain items for confirmed derivations so the proposer can cite them; verifier drops any claim not on a path. Web/shell get the same.

## Not in scope
Step/adoptive/foster relations; multiple marriages ordering in the sheet beyond dates; writing any of this to FamilySearch.

## Tests (five dimensions)
Logic: rule matrix + derivation matrix (Rick's family as fixture: Dad Sr, Mom, Rick, Tim, Donna, four sons, Ann/Bob). Scale: 100 contemporaries × 39k tree, derivation < 50 ms/query. Isolation: injected POI store + defaults, no real App Support. Sensors: "Tim ↔ Martha Lamson = 8th-great-grandmother through Rick's parents" pinned; validation never blocks a legal save.

## Plan
A (2 days): primitives-only editor + validation + inference engine + review sheet + migration. B (1 day): Hallie cross-world shapes + CyberBrain attestations. C: golden answers with Rick's sentences.

## Amendments after codex review (#830/#831/#833, 2026-08-29) — ACCEPTED
1. **Identity ≠ relationship.** `POIProfile` gains an optional durable `treeIdentity` (FSID preferred; pointer+source fingerprint fallback). It is the ONLY profile→tree bridge; fail closed on stale/colliding pins. Rick and Donna get explicit pins. Name/alias matching becomes a review *suggestion*, never graph identity. `FamilyKinshipOverlay.bridge()` name-guessing is retired.
2. **Sibling basis is stored.** `sibling` rows carry `basis: .attestedFull | .attestedHalf(sharedParent) | .unspecified`. An unspecified sibling supports sibling/uncle/in-law composition only; shared parents are PROPOSED in the review sheet and become facts only when attested. Half-sibling wording requires complete disjoint second-parent evidence or attestation (one known shared parent + one unknown ≠ half).
3. **Legacy derived rows are lossless.** Rows of derived kinds that the engine cannot reproduce move to `unresolvedClaims` (raw row + resolution state), shown read-only in the sheet until Rick resolves them. Never edges, never dropped.
4. **Confirmation scope is small.** Attest only foundational assumptions and the change set (shared parents, spouse vs partner, child rows); show a bounded consequence summary; derive distant facts on demand. Attestations live in a profile-independent atomic ledger (not on Rick's profile); keys = stable identities (uuid/FSID) + normalized edge, never @I pointers.
5. **Hybrid boundary.** Overlay hops bounded to reach an explicit pinned bridge; then indexed GEDCOM ancestry/path with budgets. No 39k expansion per pair. Local-only queries must work with graph == nil.
6. **Dates keep precision.** Year-only → compare years only when strictly different; no exact age/order from manufactured Jan 1. "How old was Dad when Tim was born" is a new explicit AST operation (age-at-person-event), deterministic.
7. **Determinism.** Route search has a stable tie-break (lexical on normalized identity, then hop kind) and operation-specific preference (direct/explicit first; blood for common-ancestor); order-reversal tests.
8. **Validation additions:** semantic duplicates across inverse rows/profiles; conflicting relations on one resolved pair; dangling/stale anchors; >2 parents after node dedup; sibling vs ancestor/descendant contradiction; cycle check canonicalizes orientation, includes GEDCOM ancestry without O(39k) in the save path. The sex-inconsistency rule is dropped (relations are neutral).
9. **CyberBrain:** citations generated at query time from primitives + attestations; no per-pair items.
