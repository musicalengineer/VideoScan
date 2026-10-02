# Irish records — Record Finder design and feasibility (GH #230)

Date: 2026-09-30 · Status: **PROPOSED** · Author: Claude (Manager) for Rick · No code in this task.

Rick (#230): "Donna's tree has twice as many people since those puritans were great record
keepers… my tree cuts off much earlier on my maternal side given the difficulty in
connecting to the Irish equivalent of familysearch.org. We need an automated way to pull
data from the various irish sites so it is as easy."

## Summary (10 lines)

1. There is no Irish FamilySearch. The records are split across ~8 sites with 4 access models; two hold the data that matters most (civil BMD with images, Catholic registers) and both sit behind a Cloudflare browser challenge — a scraper is out, a pre-filled browser link is in.
2. Verified today: NAI census 1901/1911 has a public JSON API (no key, CORS `*`, `Crawl-delay: 1`); UK TNA Discovery answers JSON without a key (OGL v3); irishgenealogy.ie, NLI registers, Griffith's, NAI genealogy portal and johngrenham.com all return the Cloudflare challenge to any non-browser client.
3. FamilySearch is NOT a shortcut: its hints/records API may show only a title + confidence and must send the user to familysearch.org ("Historical records data can only be displayed to users by FamilySearch products"); production keys are still closed to individuals (docs/research/familysearch_api_notes.md). Its pre-filled record-search URL works in a browser and already ships in the app.
4. The app already has 70% of Phase A: `FamilyTreeResearchLinks` (Irish-born → links), `Research Person` (adapter protocol, fixture fetcher, per-host pacing, disk cache, Confirmed → CyberBrain), person Documents (BC/DC/MC + sidecar), `PersonFactOverlayStore` (audited, undoable non-GEDCOM facts).
5. **Phase A "Record Finder"** (≈3 days): fix the two dead/blocked links, add verified pre-filled searches for six sites, and an "I found it" bring-back that files the PDF as a person document and writes one CyberBrain `officialRecord` source. Zero ToS risk; nothing touches the GEDCOM.
6. **Phase B** (≈2 days, only two sites qualify): census 1901/1911 adapter on the JSON API and a TNA Discovery adapter for anyone the tree calls a soldier — both inside the existing Research Person runner, paced, cached per person, counts-only logging.
7. **Phase C** (FamilySearch hints): blocked by the production-key rule and the display rule; park it, revisit if either changes. Yesterday's doc's "free Records API for individuals" claim is wrong.
8. Realistic yield for a Cork early-1900s line: civil BMD 1864→ with images, Cork & Ross Catholic registers to c.1880 (some Cork city parishes NOT on irishgenealogy.ie → NLI/FindMyPast index), 1901/1911/1926 census, Calendars of Wills 1858→, Griffith's 1850s, Tithe 1820s–30s; then the wall (§6).
9. 🔴 Privacy: `docs/research/irish_genealogy_integration_2026-09-29.md` is committed and pushed (26262834) with real family names, a street, census hits and a soldier's record reference in a public repo. Rick decides: rewrite (per the 8/03 precedent) or scrub in a follow-up commit.
10. **Recommended first step:** Rick rules on item 9 today; then Phase A as one `feature` pass (links fix + bring-back), tested along the five dimensions with no network in tests.

## 1. What the app already does (read before designing)

| Piece | File | What it gives us |
|---|---|---|
| Irish-born → research links | `VideoScanCore/.../FamilyTreeResearchLinks.swift` (+ `FamilyTreeResearchLinksTests`) | Region from the place string (32 counties), four Irish links, a pre-filled FamilySearch record search. Two links are stale: `www.census.nationalarchives.ie` (connection refused, site retired Feb 2025) and `civilrecords.irishgenealogy.ie` (old host; new combined form since Feb 2025). |
| Research Person | `FamilyTree/ResearchSources.swift`, `ResearchPerson.swift`, `ResearchStore.swift`, `ResearchPersonSheet.swift` | `ResearchFetcher` protocol (URLSession 20 s / 2 MB / per-host pause; `FixtureResearchFetcher` in tests), `CachingResearchFetcher` per subject, `ResearchRunner` fan-out, verdict per finding, "Tell Hallie". |
| Finding → CyberBrain | `FamilyTree/ResearchAttestation.swift` → `CyberBrainWriter.Testimony(origin: .researchFinding, citation:…)` | One attributed item + one source with URL, retrieval date, `sourceKind: .officialRecord`, confidence `confirmed` only after Rick reads it. |
| Person documents | `FamilyTree/FamilyAssetStore+Documents.swift`, `FamilyTreeDocumentsUI.swift` | `People/<person>/Documents/documents.json` sidecar; kinds BC/DC/MC/Other; PDF/PNG/JPG verified by magic bytes; SHA-256; 48 MB cap; Trash not delete. |
| Non-GEDCOM facts | `PersonFactOverlayStore` (used by `FamilySearchPersonRefresh*.swift`) | Audited, undoable overlay of dates/places over the GEDCOM; the GEDCOM itself is never edited (docs/research/familysearch_api_notes.md). |
| Tree source | `FamilySearchPull.swift` (`getmyancestors` via Terminal) | FamilySearch stays the tree editor. |

Design rule carried over: local GEDCOM is the source of truth; every external fact is a *source with a citation*, never an edit.

## 2. Site survey (all probed 2026-09-30 from the M4 unless noted)

Legend — Auto: can the app fetch it? Link: can a search be pre-filled by URL?

| Site | Holds / coverage | Cost | Link | Auto | Terms (quoted or paraphrased) | Citation |
|---|---|---|---|---|---|---|
| **irishgenealogy.ie** (GRO civil + church) | Civil indexes **with register images**: births 1864–1924/25, marriages 1845–1949/50 (1845–63 non-Catholic only), deaths 1871–1974/75 (1864–70 index only); +1 year each Q1. Church: Cork & Ross RC baptisms/marriages/burials with images to c.1880 (Cork city parishes St Mary & St Anne, St Patrick's, Blackrock NOT online), plus Dublin, Kerry, Carlow. [1][2][3] | Free; PDF download of images | Yes — combined form since Feb 2025 (name, district/parish, event, year range, mother's surname). Old `civil-perform-search.jsp?namefm=&namel=&location=&yyfrom=&yyto=&type=B` URLs redirect; verify the new parameter names in a browser before shipping. Record pages carry `record_id=` [3] | **No** — Cloudflare managed challenge on every path incl. `/robots.txt` (403 to curl and to the fetch tool) | Site usage policy: "freely accessed and downloaded for personal use or professional family history research… any form of unauthorised reproduction, including the extraction and/or storage in any retrieval system or inclusion in any other computer programme… is prohibited" [4] | Site + record type + registration district + year + `record_id`; file the PDF |
| **NAI census 1901/1911** (+1821–51 fragments, +1926 since 18 Apr 2026) | Household returns, all fields, form images (PDF) [5] | Free | Yes — `nationalarchives.ie/collections/search-the-census/search-results/?census_year=1911&surname=…&firstname=…&county=…&townland=…&ded=…` (200; c19 form adds barony/parish/house_number; 1926 has its own form) | **Yes** — `GET api-census.nationalarchives.ie/census/query?census_year=&surname=&firstname=&county=` → `{results:[…], meta:{count,next,prev}}`, 10/page via `offset`, `Access-Control-Allow-Origin: *`, no key; `/census/facets`, `/census/query_c19`; `robots.txt`: `Crawl-delay: 1`. Image URLs `/census/image/<id>.pdf` | Site usage policy same wording as above [6]; **1926 census is CC BY 4.0** with required attribution [7]. NAI's own site links the results page ("Link to these search results", "Download list"), so per-person lookups are ordinary use; bulk extraction is not. | Year + county + DED + townland/street + house no. + NAI image id |
| **NAI genealogy portal** (Tithe 1823–37, Soldiers' Wills 1914–17, Calendars of Wills 1858–1920, will registers, marriage licence bonds, Valuation Office books) [8] | Free | Form only (Cloudflare) ; old `titheapplotmentbooks.` / `willcalendars.` hosts time out | **No** (Cloudflare) | As NAI above | Calendar year + name + registry |
| **Griffith's Valuation** (askaboutireland.ie) 1847–64 | Occupier → townland/parish; page images and maps | Free | Yes (`index.xml?action=doNameSearch&familyname=&county=…`, verify in browser) | **No** (Cloudflare) | Not readable by script; treat as personal-use | County + parish + townland + page |
| **NLI Catholic registers** (registers.nli.ie) | Page images by parish, mostly 1740s–1880; **no index** [9] | Free | Parish/register pages addressable (`/registers/vtls…`); no name search | **No** (Cloudflare) | NLI site usage policy | Parish + register + microfilm + page |
| **FindMyPast (.ie)** | NLI Catholic register **index** (free with account, 10 M records, 1671–1900) [10]; WO 97 British Army service records 1760–1913 (paid) [11] | Free index / sub | Search URL exists (`/search/results?lastname=&firstname=&yearofbirth=…`) but 403 to scripts | No; no API | ToS forbids automated access | Collection + record id |
| **Ancestry** | Ireland Catholic Parish Registers 1655–1915 index; WO 363/364 images | Sub ($24.99+/mo) | `ancestry.com/search?name=first_last&birth=1904_cork-ireland` (200) | No API since ~2012 | — | Collection + record id |
| **RootsIreland** (county heritage centres) | Parish transcriptions by county centre, esp. West Cork/Skibbereen, Mallow | Sub, 500–1,500 views/month cap | Form only | **No** — "You may not use bots, page-scrapes, crawlers, spiders, robots, deep-links…" [12] | Personal research only; no republishing | Centre + record no. |
| **FamilySearch** | Ireland Civil Registration Indexes 1845–1958 (collection 1408347, index only, no parents) [13]; census 1901/1911 index; Catholic registers index; Griffith's | Free account | Yes — `search/record/results?q.givenName=&q.surname=&q.birthLikePlace=&q.birthLikeDate.from=&f.collectionId=` (already in the app; 403 to scripts, fine in browser) | **No** for records: hints API shows title + confidence only and must link out [14][15]; no third-party records search; production key closed to individuals [16] | Terms: personal, non-commercial; don't redistribute content | ARK URL of the index entry |
| **TNA (UK) Discovery** | Catalogue of WO 97 (soldiers' documents to 1913), WO 363/364 (WWI), medal rolls; images on FMP/Ancestry | Free catalogue | `discovery.nationalarchives.gov.uk/results/r?_q=…` | **Yes** — `API/search/records?sps.searchQuery=&sps.recordSeries=WO 97` returned JSON (200, no key) today; T&C ask for a key request, ≤3,000 calls/day, 1 rps, identify the client, "do not cache"; catalogue data is **OGL v3** [17][18] | OGL v3 | TNA reference (e.g. `WO 97/…`) + Discovery id |
| **Military Archives of Ireland** | MSPC 1916–23, Bureau of Military History, Army Census Nov 1922 | Free | `/search?q=` (200) and `/gs?q=&collection=` | Plain site, no challenge; not needed for a 1904 British-Army father | Copyright per collection | Collection + file ref |
| **PRONI** (NI) | Will calendars 1858–1965 (+ images), street directories 1819–1900, Valuation Revision Books 1864–1933 (six NI counties) [19] | Free | `apps.proni.gov.uk/WillsCalendar_IE/WillsSearch.aspx` (200; ASP.NET postback, not pre-fillable) | No | Crown copyright / OGL | PRONI ref |
| **johngrenham.com** | Surname maps, parish maps, per-parish source lists | Sub (surname pages partly free) | Cloudflare; robots.txt carries Content-Signals | No | Content-signal robots (AI/collection restricted) | Page URL |
| **IGP-web / Ireland Genealogy Projects Archives** | Volunteer headstone photos + transcriptions (Cork: Cloyne, Midleton…), memorial cards [20] | Free | Freefind search form (`search.freefind.com/find.html?si=13812782&query=`) | Static HTML, no challenge; low value for city lines | "Photographers own the copyright… Do not copy Photos" | Page URL |
| Virtual Record Treasury (virtualtreasury.ie) | Reconstructions of 1922 losses (census substitutes, 1766 religious census, Down Survey…) | Free | Site search | robots allow; not surveyed further | — | Item URL |
| data.gov.ie | Only CSO *statistical* census tables (CC BY 4.0); no NAI person-level open data [21] | — | — | n/a | — | — |

## 3. Worked example (generic — no family data in this repo)

An ancestor born in Cork city in the early 1900s; the family holds her civil birth certificate
(father recorded as a soldier, mother's maiden name known). Her parents' generation was a large
family, most of whom emigrated to America. What each phase can realistically add:

| Question | Record | Where | Phase |
|---|---|---|---|
| Parents' marriage (names of both fathers, ages, addresses, witnesses) | Civil marriage register image, c.1895–1904, Cork district | irishgenealogy.ie | A (link + bring-back) |
| Mother's own birth (her parents' names, address) | Civil birth image 1864→ | irishgenealogy.ie; index also on FamilySearch | A |
| Mother's baptism and her siblings (the "large family") | Cork & Ross RC registers to c.1880 (city parishes partly missing → NLI image + FindMyPast index) | irishgenealogy.ie / NLI / FMP | A |
| Household in 1901 and 1911: who was still in Cork, ages, birthplaces, occupations | Census returns + form image | NAI JSON API | **B** |
| Was the family still in Ireland in 1926? | 1926 census (released Apr 2026, CC BY 4.0) | NAI (form; API path not yet probed) | A now, B later |
| Father's regiment, birthplace, next of kin | WO 97 (if discharged to pension by 1913) / WO 363–364 (if he served in WWI); the app can find the *reference*, images are paid | TNA Discovery API → FMP/Ancestry | B (reference) + A (link) |
| Grandparents' generation: townland, parish | Griffith's 1850s; Tithe 1823–37 (occupiers only, no families) | askaboutireland / NAI portal | A |
| Deaths/wills of the grandparents | Civil deaths 1864→ (images 1871→); Calendars of Wills 1858→ | irishgenealogy.ie / NAI portal | A |
| Emigrant siblings in America | Out of scope here; Chronicling America adapter already exists | — | existing |

Expectation: this takes a Cork Catholic line from the early 1900s back to roughly the 1820s–40s
(register start dates), with names but few dates before civil registration. See §6.

## 4. Phases, least risk first

### Phase A — Record Finder (pre-filled links + "I found it" bring-back)

Scope
- `FamilyTreeResearchLinks`: replace the two stale hosts; add verified pre-filled links: NAI census (1901/1911 URL above, plus 1926 and c19 forms), irishgenealogy.ie (new combined form — parameter names to be verified in a browser and pinned by a test), Griffith's name search, NLI registers (parish landing page, chosen from the county), FindMyPast Irish Catholic index, TNA Discovery search for anyone whose GEDCOM occupation or notes say soldier/army, PRONI when the county is one of the six. Keep `isPrefilled` honest per link.
- Bring-back on the person card ("I found it"): drag the downloaded PDF/JPG in → files it via `importPersonDocument` (kind BC/DC/MC/Other; census → Other with note "Census 1911 return"), then one sheet with site, record type, year, district/parish, record id/URL, and a free-text transcription → `CyberBrainWriter.Testimony(origin: .researchFinding, sourceKind: .officialRecord)`. Same path `ResearchAttestation` uses today; validator refuses empty subject/text.
- Optional tick: "also propose birth/death date to the overlay" → `PersonFactOverlayStore` with audit + undo (existing refresh machinery). Never the GEDCOM.
- Where: Family Tree card context menu next to "Research Person…"; `docs/guides/source_layout.md` → `FamilyTree/`.

Effort ≈ 3 days (1 links + tests, 1.5 bring-back sheet + document/CyberBrain wiring, 0.5 verify URLs by hand and pin).

New data for the example: everything in §3 marked A — the marriage image, the mother's birth and baptism, siblings, Griffith's/Tithe placement, wills. This is where most of the missing generations are.

Privacy: no names/URLs in logs (counts only, as Research Person); documents and CyberBrain live under App Support / People, never in git; the doc fixture for tests is a synthetic PDF.

Tests (five dimensions): logic — URL builders per site, region rules, kind mapping, citation title; scale — 100k synthetic people through `regions`/`links` under a time budget (no O(records) work in a view body); media — n/a (document import already has magic-byte tests); isolation — `FixtureResearchFetcher` only, a test that fails if any adapter is constructed with the URLSession fetcher in the test target, poisoned UserDefaults; sensor — a pinned table of the six exact URLs (a redesign shows up as a red row, not a 404 for Rick) plus one nightly *browser-free* HEAD probe of the NAI results page (200 expected) reported as a row in the nightly.

Decisions for Rick: (a) confirm the irishgenealogy.ie parameter names from one real search (I cannot fetch the site); (b) whether the bring-back may propose dates to the overlay or only file documents/sources in v1.

### Phase B — automated index fetch, only where terms permit

Exactly two sources qualify today:
1. **NAI census 1901/1911 JSON API** — `CensusIrelandSource: ResearchSource` in the existing runner. Query surname + given (first token) + county from the Irish place; age filtered client-side against birth year ± 5; ≤ 5 pages (50 rows) per run; 1 request/second (site asks `Crawl-delay: 1`); cached per subject in `ResearchStore` (a personal-research cache, not a retrieval system — keep it per person, purge with the dossier); finding = household row with the form-image URL as citation; images are linked, not downloaded, until Rick presses "I found it" (Phase A path). Add 1926/c19 endpoints after probing.
2. **TNA Discovery** — `DiscoverySource` for people with a soldier marker: `sps.searchQuery="<surname> <given>"`, `sps.recordSeries` in {WO 97, WO 363, WO 364}, ≤ 3 requests per run, `User-Agent: VideoScan/<version> (contact)`, honour the "do not cache" line by storing only the reference + Discovery id in the finding, not the JSON body. Ask TNA for the courtesy key as their T&C request, even though the endpoint answers without one.

Explicitly **not** automated (terms or challenge): irishgenealogy.ie, NLI, Griffith's, NAI portal, RootsIreland, FindMyPast, Ancestry, johngrenham. No headless browser, no UA spoofing — the Cloudflare page is the site saying "humans only".

Effort ≈ 2 days. New data: 1901/1911 households (the strongest "who was still in Cork" evidence) and the soldier's record reference. Privacy: counts-only logs; API responses cached under the person's research folder only. Tests: logic (parsers over fixture JSON incl. `next` paging, an empty result, a 1,244-hit surname capped), scale (10k-row synthetic response under budget), isolation (no network; fixture fetcher; `Origin`-free requests pinned), sensor (nightly one-known-query probe of `api-census…/census/query` — count > 0 — as a nightly row, red on drift).

Decision for Rick: approve two adapters with these caps; approve emailing TNA for the key.

### Phase C — FamilySearch hints / records search

Blocked twice: production keys require a registered business (docs/research/familysearch_api_notes.md); and even certified hinting apps may show only title + confidence and must hand off to familysearch.org [14][15]. `getmyancestors` does not expose hints. Park; revisit if FamilySearch opens individual keys. The pre-filled search link (Phase A) is the working substitute. Effort 0 now.

## 5. Consolidated decisions for Rick

1. 🔴 The 09-29 doc with real names on `origin/main`: rewrite history (as on 8/03) or scrub-commit. Also decide whether §2 of that doc's *findings* move to a private note under App Support.
2. Phase A v1: documents + CyberBrain only, or also overlay date proposals?
3. Approve Phase B's two adapters and caps; approve the TNA key email.
4. Order: A before B (B's findings need A's bring-back to become documents).

## 6. Why the Irish side stops early (honest part)

- **1922:** the Public Record Office at the Four Courts burned on 30 June 1922 — the 1821–51 census returns (bar fragments), most Church of Ireland registers, and original wills to 1858 are gone; calendars and indexes survived [22].
- **1861–91 censuses** were destroyed by government order before 1922; 1901 and 1911 are the only complete surviving censuses (1926 released April 2026).
- **Civil registration** starts 1864 (non-Catholic marriages 1845). Before that, only church registers.
- **Catholic parish registers** mostly begin 1820–40 (Cork city is unusually early: St Mary's 1748, St Finbarr's 1756, SS Peter & Paul 1766), record baptisms and marriages only, often no ages or addresses.
- **Griffith's (1847–64) and Tithe (1823–37)** name occupiers, not families; they place a surname in a townland, which is the pre-1864 bridge.
- So for a Cork line the tooling ceiling is roughly the 1790s–1820s, and beyond that only estate papers or the Virtual Record Treasury's reconstructions. Donna's line benefits from New England town records kept from the 1630s; the gap is history first, connection second. Tooling makes reaching the ceiling faster; nothing gets past it for free.

## 6a. Implementation notes (2026-10-01, Phase A + B built)

- **Downgrade compatibility (no code; QA P3-10).** New dossiers (`People/<key>/research/dossier.json`)
  can hold findings whose `source` is `irishCensus`, `tnaDiscovery` or `recordFinder`, plus the
  optional fields `servedInMilitary`, `documentPath` and `fullText`. Builds from BEFORE 2026-10-01
  decode the optional fields fine but **cannot decode the new source names**: their Research pane
  shows a "could not read" error for that person. The file itself stays intact — every writer now
  does read-modify-write under a per-key lock and an unreadable dossier is never overwritten —
  but do not run an older build's Research pane against an archive this build has written. The
  new build reads every older dossier (pinned by `dossiersSavedBeforeTodayStillDecode`).
- Find a Grave is a pre-filled link, not a fetcher (robots.txt; Rick 2026-10-01).
- Region detection classifies each place on its own by whole words; a place with a US marker is
  the United States unless a later comma-part names a British-Isles country (New England's
  Suffolk/Essex/Norfolk/Kent/Wales/Derry/Antrim stay American).

## 7. Sources (fetched 2026-09-30)

[1] https://irishheritagenews.ie/irish-civil-records-whats-online-and-whats-not/ · [2] https://irishgenealogy.ie/en/news/98-church-records-available-online-www-irishgenealogy-ie · [3] https://irishheritagenews.ie/?p=23468 (Feb 2025 makeover) · [4] https://irishgenealogy.ie/site-usage-policy · [5] https://nationalarchives.ie/collections/search-the-census/ · [6] https://nationalarchives.ie/site-usage-policy/ · [7] https://nationalarchives.ie/?p=8233 (Permission to reuse Census 1926, CC BY 4.0) · [8] https://nationalarchives.ie/article/our-genealogy-website · [9] https://registers.nli.ie/ · [10] https://www.findmypast.co.uk/irish-parish-records · [11] https://angloboerwar.com/forum/11-research/38-wo97-british-army-service-records · [12] https://www.rootsireland.ie/terms-and-conditions/ · [13] https://www.familysearch.org/en/search/collection/1408347 · [14] https://developers.familysearch.org/main/docs/integrating-hints · [15] https://developers.familysearch.org/main/docs/family-tree-matching-and-hinting · [16] docs/research/familysearch_api_notes.md (certification guide, 2026-08-25) · [17] http://www.nationalarchives.gov.uk/terms-and-conditions/discovery-for-developers-about-the-application-programming-interface-api/ · [18] https://www.nationalarchives.gov.uk/terms-and-conditions/policy-on-use-of-website-and-catalogue-data/ · [19] https://www.nidirect.gov.uk/articles/public-record-office-northern-ireland · [20] https://www.igp-web.com/IGPArchives/ · [21] https://data.gov.ie/dataset?q=census+1911 · [22] https://www.findmypast.com/articles/irish-records-office-destruction/four-courts-destruction-what-was-lost

Probe log: irishgenealogy.ie, registers.nli.ie, askaboutireland.ie, genealogy.nationalarchives.ie, johngrenham.com → Cloudflare "Just a moment" (403) on `/robots.txt` and content paths, curl with a browser UA and the fetch tool alike. www.census.nationalarchives.ie, titheapplotmentbooks., willcalendars. → connection refused / timeout. nationalarchives.ie results page and api-census JSON → 200 (1,244 hits for a common Cork surname, 10/page, 27 fields, 6 form images per household). discovery.nationalarchives.gov.uk API → 200 JSON, no key. findmypast.ie and familysearch.org search URLs → 403 to curl (browser fine); ancestry.com → 200.
