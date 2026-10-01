Confirming pass for GH #235 (closes codex r4 F1). Range 16fcfe04..69ea1a6f (merged to main as d1aee8c5).

Files in scope (do not explore outside these):
- VideoScan/VideoScan/FamilyTree/FamilyMapModel.swift — isOwnBirthEvent and its patterns
- VideoScan/VideoScanTests/FamilyMapModelTests.swift
- VideoScan/VideoScanTests/FamilyTreeBirthFlagTests.swift
- VideoScan/VideoScanTests/FamilyMapNotesAdversarialTests.swift

Invariant to attack: no family note places a person on the map unless it opens with a run of names that are ALL that person's own (canonical or alias, at least one given name), followed by 'was born' / ', born'. Rules 1–3 (Born…/Birth…/She was born… openers) were deleted; rule 4 is unchanged. Your r4 F1 counterexamples are now negatives through the real familyBirthPlace lookup under both GEDCOM and name linkage.

Accepted false negatives (do not report): notes that don't open with the person's own name, e.g. 'Born in Cork.', 'She was born in Cork.'

Evidence already run (Debug): RED with tests only = 36 tests / 27 issues; GREEN after fix = 44 Swift Testing tests in 5 suites, 0 issues.

Wanted: verdict closed / fix/N. Any finding must be a concrete note string that places the wrong person through rule 4 or a regression in a previously-passing positive. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
