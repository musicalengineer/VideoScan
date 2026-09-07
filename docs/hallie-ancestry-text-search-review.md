# Hallie ancestry text search — review recommendation

September 7, 2026. Discussion proposal sent to Claude in team messages
#1157–#1158 and #1161–#1162; not an implemented feature.

## Rick's intended behavior

Find text already recorded in the family tree, including names such as
“Patrick, I Laird of Hailes Hepburn.” Search terms such as “Hailes,” “Laird,”
and “Hepburn” should discover the record without requiring structured title
metadata. Show the original wording, let Rick choose the person, then support
relationship and geographic follow-ups. Recorded wording is evidence of what
the imported tree says, not independent authentication of historical status.

## Smallest useful implementation

1. Add an explicit Hallie tree-text-search route using the existing compiled
   `GedcomFamilyGraph.Index.sidebarRows(containing:)`. The Family Tree sidebar
   already uses this in `FamilyTreeLiveModel.refilterNow`. It searches primary
   and alternate names, surnames, and IDs. Map matching rows through
   `sidebarOrder` and `ids` to stable person records. Bound/paginate output.
2. Preserve a selected result's GEDCOM identity and graph identity through
   follow-ups. Current conversation memory stores names; turning a selected
   record back into a name can lose disambiguation. Reuse the birthplace
   paging route's tree-token guard when the tree changes.
3. Extend location-question recognition using existing graph traversal.
   Core `originTrail(country:)` can match recorded place components despite
   its country-oriented parameter name. Natural-language detection is more
   constrained than the underlying capability. Report birthplace sequences
   as birthplace sequences, not proof of migration or residence.

The first search slice requires neither a new title schema nor a different
model. Current substring search is case-insensitive and contiguous; reordered
tokens, diacritic folding, and title synonym expansion are separate behavior
changes that need their own tests. Do not promise them from the existing API.

## Boundaries to preserve

- Keep text discovery separate from ordinary person identity resolution.
  Do not make every surname/title substring a resolved person.
- “In the tree” searches the whole tree. “My ancestors” requires a resolved
  starting person and ancestor filtering, not merely a matching surname.
- A maternal chain (mother, maternal grandmother, etc.) differs from all
  ancestors on the mother's side. Preserve this distinction in the question
  and response.
- Keep historical place text and uncertainty. A territorial designation in
  a name does not establish that person's birthplace.
- Dedicated GEDCOM title fields are currently not retained; handling those
  can follow separately if inventory shows relevant data outside NAME.

## Regression acceptance cases

Drive production parsing/loading, routing, and result construction—not just
hand-built cards: exact Hepburn example; partial name/title/place string;
alternate NAME; multiple same-display-name people; no match; collateral
match versus direct ancestor; selected-result follow-up; tree replacement;
unknown/ambiguous birthplace; explicit place target; maternal-side semantics.
Include a production-scale search budget and harvested Hallie chat examples.

Independent baseline verification: 24 Core `BirthplaceClassifierTests` and
`LineageTrailTests` passed, including a 131k-person pedigree sensor (~4.36s).
This verifies existing traversal, not the proposed Hallie routing.
