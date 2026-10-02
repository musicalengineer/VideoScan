---
tier: truth
paths:
  - VideoScan/VideoScan/Hallie/HallieTurnExecutor*.swift
  - VideoScan/VideoScan/Hallie/Archivist*Executor*.swift
  - VideoScan/VideoScan/Hallie/*Answer*.swift
  - VideoScan/VideoScan/Hallie/HallieLineage*.swift
  - VideoScan/VideoScan/Hallie/HallieAncestorStatistics*.swift
  - VideoScan/VideoScan/Hallie/HallieTreeStatistics*.swift
  - VideoScan/VideoScan/Hallie/HallieCompositionVerifier.swift
  - VideoScan/VideoScan/Hallie/HallieResponseCommit.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+TurnMemo.swift
  - VideoScan/VideoScan/Hallie/HallieVitalDates.swift
  - VideoScan/VideoScan/Hallie/HallieMarriageDate.swift
  - VideoScan/VideoScan/Hallie/HallieServiceStory.swift
  - VideoScan/VideoScan/Hallie/HallieClarification*.swift
  - VideoScan/VideoScan/Hallie/HallieGeneralAnswerBoundary.swift
  - VideoScan/VideoScan/Hallie/LLM/**
---
# Hallie: answers and their truth

## Invariants
1. **HAL-1** Every family fact in an answer is grounded: composed in Swift from catalog / tree / CyberBrain data that carries a citation. The LLM only translates questions and phrases a verified plan; the composition verifier rejects any name, date, place or relation not in the plan.
2. **HAL-2** Abstain over guess: an unparsed constraint (side, branch, family-line scope, relative clause, qualifier) gives a clarification or an abstention, never a broader answer presented as the narrow one.
3. **HAL-3** The right person: a name resolves through People ↔ CyberBrain aliases and identity rulings; an ambiguous name asks "which one", never silently takes the first match.
4. **HAL-4** Within a turn no answer is built from a read older than a write Hallie made in that same turn, and the next turn always reads fresh.
5. **HAL-5** Ages and dates are stated at their precision: no negative or "about 0" ages; dual years and about/before/after qualifiers survive; a living person's age is not computed from a guess.
6. **HAL-6** Catalog answers (counts, superlatives, "show me") count the same records the Catalog would show, and a decline says it is declining rather than inventing.
7. **HAL-7** General knowledge from the LLM is labelled as such and never mixed into a family-fact sentence.

## Known and accepted (do not report)
- Rare given names or nicknames with no alias on file are declined ("I don't know who that is"); adding aliases is a data task.
- Phrasing variety comes from the LLM; only the facts are checked.
