# Irish genealogy integration — deep dive (GH #230)

Rick 2026-09-29: "my tree cuts off much earlier on my maternal side given the
difficulty in connecting to the Irish equivalent of familysearch.org … Just a
technical connection issue... we'll see."

Short answer: there is no Irish FamilySearch. The Irish records are spread
over five government sites with five different access models, and two of the
five actively block anything that is not a browser. But (1) the census has a
clean JSON API we can use tonight, (2) FamilySearch itself already indexes
the Irish civil records and its official Records API is free for individual
developers, and (3) for the two blocked sites the right tool is a browser
the app drives, not a scraper. Details and evidence below — every claim was
probed from the M4 on 2026-09-29.

## 1. The sites, what they hold, and how they can be reached

| Site | Holds | Access model (probed) | Automatable? |
|---|---|---|---|
| **irishgenealogy.ie** (GRO civil records) | Births 1864–1925, marriages 1845–1950, deaths 1871–1975 — **indexed and with register images**. This is where Mary Christina's 1904 birth entry, Ellen Ronan's 1882 birth and the O'Connor–Ronan marriage live. | Web form with URL parameters (`church-or-civil=civil&lastname=…&location=…&event-birth=1&yyfrom=…&yyto=…`). **HTTP 403 to any non-browser client**, even with a Safari user-agent (WAF). | Not by HTTP. By browser (see §3C) or deep link (§3D). |
| **Census 1901 / 1911** (National Archives of Ireland) | Every household: names, ages, birthplace, religion, occupation, relationship — plus the original form images (PDF). | The old `census.nationalarchives.ie` is **offline** (connection refused). The new site is WordPress in front of a **JSON API**: `GET https://api-census.nationalarchives.ie/census/query?census_year=1911&surname=O'Connor&firstname=…&county=Cork&townland=…` → `{results:[…], meta:{count,next,prev}}`; fields include `surname, firstname, age, sex, townland, ded, county, house_number, relation_to_head, religion, occupation, marriage_years, children_born, birthplace, images[{form, side, url}]`. `…/census/facets` gives counts per field. Wildcards work in the form; `age` is exact in the API (filter client-side). Plain GET, no key, no cookie. | **Yes, today.** |
| **Catholic parish registers** (NLI, registers.nli.ie) | Baptisms/marriages 1740s–1880 as page images, arranged by parish; **no index**. The index exists only on FamilySearch/Ancestry/FindMyPast. | **403** to non-browser clients. | Browse-by-parish deep link only; the index via FamilySearch. |
| **FamilySearch** | "Ireland Civil Registration Indexes 1845–1958" (births 1864–1913 — covers 1882 and 1904), the Catholic parish register **index**, census 1901/1911 index, Griffith's, and more. Rick's tree already comes from here. | The app pulls the tree through `getmyancestors` (user login). The **official Records API** (`/platform/search/records?q.givenName=…&q.surname=…&q.birthLikePlace=…&q.birthLikeDate.from=…&f.collectionId=…`) needs a free app key: individuals qualify via the Solution Provider application (developers.familysearch.org); the key works in the sandbox immediately and production after approval. | **Yes, with a key** (Rick applies once). |
| **The National Archives (UK) Discovery** | WO 97 soldiers' documents to 1913, WO 363/364 WWI service records, medal rolls — Christopher O'Connor was a *soldier* in 1904. | Public JSON API, no key: `https://discovery.nationalarchives.gov.uk/API/search/records?sps.searchQuery=O'Connor Christopher&sps.recordSeries=WO 97`. Probed: 128 hits without a series filter, incl. `WO 363/O194–O195` "O'Connor, Christopher" (WWI). | **Yes, today.** |
| RootsIreland (IFHF), FindMyPast, Ancestry | Transcriptions of parish registers by county centre; paid. | Login + paywall; no API. | No (Rick by hand). |
| Griffith's Valuation (askaboutireland.ie), Tithe Applotment (NAI) | 1820s–1860s land occupiers — the pre-civil-registration bridge. | Web forms; not probed tonight. | Later. |

## 2. What the probes found about Rick's line tonight

- **1901 census, Cork City:** *Ellen Ronan, 19, domestic servant, Lower Glanmire Road, North East Ward, born Cork City* (house 14). Born 1882 ✓, Cork City ✓ — a strong candidate for the great-grandmother, three years before she registered Mary's birth from Fullers Lane. (Seven other Ellen Ronans in Co. Cork that year; none fits as well.) Confirmation = the O'Connor–Ronan marriage (Cork, c. 1901–1904) on irishgenealogy.ie, which names her father.
- **1911 census:** *no O'Connor household at Fullers Lane* and no Christopher O'Connor of soldiering age in Cork. The family had left Cork by April 1911 — a soldier's posting (barracks are enumerated where they stood, possibly in England) or the emigration ("one of the nine who came to America"). Worth checking: the 1911 **England & Wales** census for a Christopher O'Connor, soldier, born Cork, with wife Ellen and daughter Mary (b. Cork ~1904).
- **Christopher O'Connor, soldier:** TNA Discovery lists WO 363/O194–O195 "O'Connor, Christopher" (WWI service records, images on FindMyPast/Ancestry) — if he served on into the war. His pre-war attestation (regiment, birthplace, next of kin) would be in WO 97 only if discharged to pension by 1913.
- Ellen Ronan's own birth (1882, Cork) is on irishgenealogy.ie and in FamilySearch's civil index; her parents' names are on that register image.

## 3. Approaches, in the order I'd do them

**A. Census adapter in Research Person (1 day, works tonight).** A new
`ResearchSource` (the existing adapter protocol: fixture fetcher in tests,
paced URLSession in production, disk cache, counts-only logging) that queries
the census JSON API for a person's name ± 5 years of age, county from the
birthplace, and returns findings with the household, ages, birthplace,
religion, and the form-image URL as the citation. Rick presses Run, reads,
presses Confirmed → CyberBrain (the path that already exists). Free, no key,
no scraping.

**B. FamilySearch Records API (½ day of code after Rick gets a key).** Rick
applies for a free developer key (one form). Then the same Research Person
pane searches the Irish civil index and the parish-register index by name +
place + date window, returning the indexed event (date, district, parents'
names where indexed) with a FamilySearch link as the citation. This is the
closest thing to "the Irish FamilySearch" because it *is* FamilySearch.

**C. Browser-driven research for the blocked sites (irishgenealogy.ie, NLI).**
These sites refuse non-browser clients, and a scraper that disguised itself
would be both fragile and against their spirit. The honest automation is a
browser Rick is logged into, driven by the assistant: the `claude-in-chrome`
skill can open the pre-filled search, read the results and the register
image, and hand the transcription back for a note — with Rick watching. For
the app: a **"Research on irishgenealogy.ie"** action that opens the
pre-filled search URL (name, county, event, year window) in Rick's browser,
and a **paste-back** box on the person card that turns the result into a
sourced CyberBrain event (the birth-certificate pattern from tonight).

**D. TNA Discovery adapter (½ day).** Same shape as A; for anyone the tree
calls a soldier (Christopher). Returns catalogue references and dates; the
images are on the paid sites, so the finding says "record exists: WO 363/O194"
and links the Discovery page.

**E. The pre-1864 bridge (later).** Parish registers (NLI images via
FamilySearch's index), Griffith's Valuation and Tithe Applotment — this is
what takes the Cork line back past civil registration, and it is where the
"twice as many ancestors on Donna's side" gap really lives: the Puritans
kept town records from 1630; Irish Catholic parish registers mostly start in
the 1820s and many earlier records burned in 1922. Some of that gap is not a
connection problem; it is history.

## 4. Why FamilySearch has less for Cork (the honest part)

FamilySearch's Irish coverage is thin before 1864 because the sources are
thin: civil registration starts in 1864 (1845 for non-Catholic marriages),
most Catholic registers start 1820–1840, the 1821–1851 censuses were
destroyed in 1922, and Griffith's (1847–64) names occupiers, not families.
The realistic ceiling for a Cork Catholic line is roughly the 1790s–1820s
via parish registers, unless the family appears in estate papers. The tools
above get Rick to that ceiling faster; nothing gets past it for free.

## 5. Tests and safety (when we build A/B/D)

Five dimensions as usual: logic (parsers over fixture JSON), scale (a
2,000-hit surname paged and capped), isolation (fixture fetcher, never the
network in tests; the census API's `Origin`/`Referer` headers pinned),
sensor (a weekly nightly probe that the census API still answers one known
query — so a silent API change shows up as a red row, not a blank pane),
and privacy (logging stays counts-only; no names in logs).
