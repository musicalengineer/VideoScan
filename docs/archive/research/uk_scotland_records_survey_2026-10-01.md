# England & Wales, Scotland (and UK-wide) records — source survey for the Record Finder

Date: 2026-10-01 · Status: **SURVEY** (companion to `docs/research/irish_records_design_2026-09-30.md`) · Author: Claude for Rick · No code in this task.

Scope: the same question the Irish doc asked, for Great Britain. Which sites hold the records, can a search
be pre-filled by URL, and may the app fetch anything itself inside the existing `ResearchFetcher` /
Research Person runner (paced, cached per person, counts-only logging)? Everything below was probed
2026-10-01 from the M4 unless marked **unverified**. Probing was polite: ≤ 6 requests per host,
≥ 1.1 s apart, User-Agent `Mozilla/5.0 (Macintosh…) VideoScan-genealogy-survey/0.1 (personal
family-history app; one-off feasibility check)`; no bulk fetches. No family names or real person data
appear in this doc (public repo); worked examples are generic.

## Summary (10 lines)

1. Britain is better served than Ireland: three national-scale free indexes (FreeBMD, FreeCEN, FreeREG), the GRO index with mother's maiden name, and ScotlandsPeople as one paid site for nearly all Scottish records. But the access model is the same: **search by hand, bring the record back**.
2. **FreeBMD / FreeCEN / FreeREG are explicitly closed to software**: "Access … is only permitted manually via the search page… The use of front end programs or sites to enter search parameters is strictly forbidden" [1][2]. Their searches are POST + CSRF token, so they cannot even be pre-filled by URL — the app can only open the blank form.
3. **GRO (E&W)** index search sits behind a login (302 → `Login.asp`); births 1837–1934 & 1984→, deaths 1837–1957 & 1984→, PDF £8, online view £3 [3]. Link only.
4. **ScotlandsPeople** forbids "robots, spiders, crawlers, scraping … or automatic access tools" [4]; search requires login; images 6 credits (£1.50) [5]. Link to the category form only.
5. **ScotlandsPlaces closed on 24 June 2025** (its homepage says so; OS Name Books + tax rolls moved to ScotlandsPeople, HES material to trove.scot). Drop it.
6. Cloudflare / bot challenges seen today: British Newspaper Archive (403 on `robots.txt` too), Welsh Newspapers Online (403 "Just a moment"), UK Census Online search (403), CWGC (403 on everything). FindMyPast answers 200 but `robots.txt` disallows `/search/results`, `/*lastname=*` and `/1921-census`.
7. **Only one source qualifies for an unconditional automated adapter: TNA Discovery** (already proposed for Ireland) — and for England it is richer than expected: PROB 11 (PCC wills 1384–1858) and ADM 188 (RN ratings) are name-searchable item descriptions; verified JSON 200 today, OGL v3.
8. **Cornwall OPC database** is the one volunteer site that *technically* works (plain GET, robots `Allow: /`, no challenge, results in HTML; verified 854-row hit list) — but its copyright page allows personal research only and says "no transcription is to be copied in any way without the express consent" [6]. Adapter only after a permission email; link until then.
9. 🔴 **The app's existing `FindAGraveSource` fetches `/memorial/search`, which Find a Grave's `robots.txt` has disallowed since 2024-11-25** ("Disallow: /memorial/search") [7]. It still returns results (21 memorial links today) behind a reCAPTCHA-capable page. Recommend demoting it to a pre-filled link (decision for Rick).
10. A legitimate *offline* route exists: FreeUKGenealogy releases FreeBMD/FreeREG/FreeCEN data under **ODbL 1.0** on request (possible processing fee; a paid API is "intended") [8]. A local FreeBMD extract would give the app a real, ToS-clean index adapter — worth one email.

## 1. What the app already has

See `docs/research/irish_records_design_2026-09-30.md` §1 — same pieces: `FamilyTreeResearchLinks` (Core; pre-filled FamilySearch record search with `q.givenName/q.surname/q.birthLikeDate.from/to/q.birthLikePlace`), Research Person (`ResearchSources.swift`: `ResearchFetcher`, `URLSessionResearchFetcher`, `FixtureResearchFetcher`, `CachingResearchFetcher`, `ResearchSource` adapters — today `ChroniclingAmericaSource`, `FindAGraveSource`, `WikipediaSource`, `WebSearchSource`), person Documents, CyberBrain `officialRecord` sources, `PersonFactOverlayStore`. The Irish Phase A "I found it" bring-back is the delivery path for every link-only source below; nothing here needs new plumbing beyond more links and (for Discovery) more series.

## 2. Site survey (probed 2026-10-01)

Legend — Link: can a search be pre-filled by URL? Auto: may the app fetch it? "robots" = what `/robots.txt` says for `User-agent: *`.

### 2a. England & Wales

| Site | Holds / coverage | Cost / login | Link (pre-fill) | Auto | Terms / robots (quoted) | Citation key |
|---|---|---|---|---|---|---|
| **FreeBMD** (freebmd.org.uk; new UI at freebmd2.org.uk) | Volunteer transcription of the GRO quarterly BMD indexes, E&W 1837→; near-complete to the 1980s–90s (exact end **unverified**) | Free, no login | **No.** Classic search is `POST /cgi/search.pl` (multipart; fields `type, surname, given, start, end, districtid, countyid, sq, eq…`); FreeBMD2 is `POST /search_queries` with `authenticity_token`. GET params to `/search_queries/new` do **not** pre-fill (tested). Open the blank form. | **No** | "Access to the data held by FreeBMD is only permitted manually via the search page… The use of front end programs or sites to enter search parameters is strictly forbidden"; "for personal research purposes only" [1]. robots: `Disallow: /cgi/` (classic); FreeBMD2 lists `Disallow: /search_queries`, `/search_records` (group headed by ad-bot UAs, `User-agent: *` line commented out — intent is clear). | Event + surname, given + quarter/year + registration district + volume + page (the GRO reference) |
| **FreeCEN** | Census transcriptions 1841–1901 (+ some 1911), strongest for Scotland 1841/1851 and a few English counties; partial (coverage map at `/freecen_coverage`) | Free | **No** — `POST /search_queries` + CSRF; fields `search_query[last_name, first_name, start_year, end_year, birth_chapman_codes[], chapman_codes[], record_type, sex, occupation…]` | **No** | Same wording as FreeBMD: "only permitted manually… front end programs… strictly forbidden"; "Data extracted from FreeCEN must not be reproduced in any form" [2]. robots: `Disallow: /search_queries`, `/search_records` | Census year + county (Chapman code) + piece/folio/page + household |
| **FreeREG** | Parish register transcriptions (baptisms, marriages, burials), E&W + Scotland, 1538→, patchy by parish | Free | **No** — `POST /search_queries` + CSRF; fields `last_name, first_name, start_year, end_year, chapman_codes[], place_ids[], record_type, region, witness, fuzzy…` | **No** | FreeUKGenealogy T&Cs apply (FreeREG T&C URL 404'd today; wording assumed to match FreeBMD/FreeCEN — **unverified**). robots: `Disallow: /search_queries`, `/search_records` | County + parish + event + date + register type |
| **FreeUKGenealogy Open Data** | Bulk extracts of FreeBMD/FreeREG/FreeCEN | On request; may charge for processing; a paid API is "intended" | n/a | **Offline yes** (licensed copy) | "shared under the Open Database Licence 1.0 (ODbL)… We also intend to develop an API… subject to a usage fee"; contact info@freeukgenealogy.org.uk [8] | As per dataset + ODbL attribution |
| **GRO England & Wales** online index | Births 1837–1934 and 1984→two years ago (with mother's maiden name); deaths 1837–1957 and 1984→ (with age at death) [3] | Free account; PDF **£8.00**, online view **£3.00**, certificate £12.50 [3] | **No** — `/gro/content/certificates/indexes_search.asp` 302 → `Login.asp`. Link to the login page. | **No** (login wall; no robots.txt — `/robots.txt` redirects to the home page) | GRO T&Cs not re-read today (**unverified**); treat as personal-use. Note: www.gro.gov.uk serves an incomplete TLS chain — Python urllib fails verification, curl/Safari succeed. | GRO index ref: year + quarter + district + volume + page (+ MMN/age) |
| **1921 census** (FindMyPast only) | E&W household schedules, 19 June 1921 | Index search free; transcript £3.50, image £2.50, or Premium sub [9] | Search URL exists (`/search/results?firstname=&lastname=&…`, returned 200 to curl today); a 1921-specific dataset filter is **unverified** | **No** | FMP robots: `Disallow: /search/results`, `/*lastname=*`, `/1921-census`, `/transcript`, `/image-viewer`; FMP ToS forbid automated access (per Irish doc; T&C URL 404 today) | FMP record id + TNA ref (RG 15/piece/schedule) |
| **FindMyPast** (other E&W) | Censuses 1841–1921, parish registers (many county record office partnerships), BNA newspapers, military | Sub | As above | **No** | As above | Collection + record id |
| **UK Census Online** (ukcensusonline.com) | Census 1841–1911 indexes, BMD (third-party reseller) | Pay-per-view/sub | Landing page 200; `/search/` → **403 Cloudflare "Just a moment"** | **No** | robots: `Disallow: /app/` | Vendor id — low value; prefer FMP/Ancestry/FreeCEN |
| **Probate Search Service** (gov.uk "Search probate records") | Calendar of grants E&W 1858→ (wills index + copies) | Free search; copy of will £16 (**unverified**) | Landing `gov.uk/search-will-probate` 200; `probatesearch.service.gov.uk` returned **503** to scripts today; form not inspected | **No** (not verified) | — | Calendar year + name + registry |
| **TNA Discovery** (reuse from Irish doc) | Catalogue; name-searchable item descriptions in **PROB 11** (PCC wills 1384–1858), **ADM 188** (RN ratings 1853–1928), WO 97, WO 363/364, AIR 79, ADM 196… | Free; images often paid via TNA/FMP/Ancestry | Browser: `discovery.nationalarchives.gov.uk/results/r?_q=` | **Yes** — `API/search/records?sps.searchQuery=&sps.recordSeries=PROB 11` returned 200 JSON today (66 hits for a common Cornish surname, refs like `PROB 11/…/…`); ADM 188 likewise (173). T&C: key requested, ≤ 3,000 calls/day, 1 rps, identify client, "do not cache" [10] | OGL v3 [11] | TNA reference + Discovery id |
| **Online Parish Clerks — Cornwall** (cornwall-opc-database.org) | ~2.2 M transcribed entries: baptisms, banns, marriages, burials, + extras (wills index, MIs, muster rolls, land tax…) | Free, no login | **Yes (verified)** — `GET /search-database/baptisms/index.php?t=baptisms&year_from=&year_to=&parish=&forename1=&surname1=&bf=Search` → HTML table "Showing 1 to 50 of N records", 50/page | **Technically yes; permission needed** | robots: `User-agent: * Disallow: /adm/ /login/ Allow: /`. Copyright: personal research allowed "provided that the source (Cornwall OPCs) is acknowledged properly"; "no transcription is to be copied in any way without the express consent of the copyright holder" [6]. Automated access not addressed. | Parish + event + date + OPC database row |
| **Online Parish Clerks — Lancashire** (lan-opc.org.uk) | ~6.5 M BMB entries [12] | Free | Search under `/Search/` and `/cgi-bin/` (frameset site; parameters not inspected — **unverified**) | **No** | robots: `Disallow: /cgi-bin/`, `Disallow: /Search/` | Parish + register + entry |
| **Other OPCs** (Dorset, Kent, Somerset, Sussex, Wiltshire, Essex; Devon has no single OPC database — **unverified**) | Per-parish transcriptions, mostly static HTML pages | Free | Parish pages addressable; search forms vary | Not surveyed | Volunteer copyright, personal use typical | Parish page URL |
| **GENUKI** | Reference: per-county/parish pages listing where every register, census and MI set is held | Free | **Yes** — `genuki.org.uk/big/eng/{CHAPMAN}` (e.g. `/big/eng/CON` 200), parish pages beneath; Scotland `/big/sct/…`, Wales `/big/wal/…` | No need (reference) | robots: `User-agent: * Crawl-delay: 20`, `Disallow: /search*`, `/gazetteer`; explicitly blocks `anthropic-ai`, `Claude-Web`, `GPTBot`, `CCbot`… | Page URL |
| **Deceased Online** | Burial/cremation registers for ~participating UK councils, some with grave maps/photos | Register to search; views pay-per-view or sub (£9.99/15 views; £99/yr 250) [13] | Home-page form is `GET dec_search.php` with `s` (surname), `f` (forenames), `b`/`e` (burial/cremation year from/to), hidden `n,l,a`, checkboxes `c,i,u` — **pre-fill plausible but not tested** | **No** | "you may not utilise any data mining, robots, or similar data gathering and extraction tools…" [13]. robots blocks only AhrefsBot, GPTBot | Burial authority + cemetery + register entry |
| **Find a Grave** (UK coverage: patchy, volunteer) | Memorials + photos | Free | Yes — `/memorial/search?firstname=&lastname=&birthyear=&birthyearfilter=&deathyear=&deathyearfilter=&location=` (200; 21 memorial links in the HTML) | **No** — robots `Disallow: /memorial/search` (updated 11/25/2024) [7] | (ToS URL 404'd today) | Memorial id |
| **BillionGraves** (UK: modest, GPS-tagged headstone photos) | Headstone images + transcriptions | Free / BG+ sub | `/search/results?given_names=&family_names=&country=United%20Kingdom` → 200 but a JS app (no results in HTML) | **No** | robots: `User-agent: * Content-Signal: search=yes,ai-train=no,use=reference; Allow: /`; disallows ClaudeBot, anthropic-ai, GPTBot… | Grave id |
| **CWGC** (Commonwealth War Graves, UK-wide) | WWI/WWII war dead, burial place, next of kin | Free | Search URL shape `/find-records/find-war-dead/search-results/?Surname=&Initials=` — **unverified** (403 to scripts on every path incl. robots.txt, even with a Safari UA) | **No** | — | CWGC casualty id |
| **British Newspaper Archive** | ~90 M pages UK & Irish papers 1700s–2000s | Sub; free search snippets | Shape `/search/results?basicsearch=&exactsearch=false&retrievecountrycounts=false` (date-range path form `/search/results/{yyyy-mm-dd}/{yyyy-mm-dd}?…`) — **unverified** | **No** — 403 Cloudflare "Security Check" on `/robots.txt` and search | — | Title + date + page + BNA article id |
| **Welsh Newspapers Online** (National Library of Wales) | ~1.1 M pages, ~120 titles, to 1919; free, OCR text, IIIF images [14] | Free | Shape `newspapers.library.wales/search?query=&range[min]=&range[max]=` — **unverified** (Cloudflare) | **No** — 403 "Just a moment" to script and to curl with a Safari UA; no public API [14] | Reuse statement not readable today (**unverified**); content itself out of copyright | Title + date + page + NLW id |
| **FamilySearch** (E&W) | Index collections below; many parish register images (browse) | Free account | Yes — record search with `f.collectionId` (§5) | **No** (see Irish doc §2/Phase C: hints-only API, production key closed, display rule) | Personal, non-commercial | ARK of the index entry |

### 2b. Scotland

| Site | Holds / coverage | Cost / login | Link (pre-fill) | Auto | Terms / robots (quoted) | Citation key |
|---|---|---|---|---|---|---|
| **ScotlandsPeople** (NRS) | Statutory births 1855→ (images ≥100 yrs), marriages (≥75), deaths (≥50); **OPRs 1553–1854** (baptisms/banns/burials); RC registers; census 1841–1921; wills & testaments 1513–1925; valuation rolls 1855–1940; OS Name Books + tax rolls (moved from ScotlandsPlaces); poor relief, prison registers | Free account to search indexes; image 6 credits = **£1.50** (1 credit = 25p); wills 10 credits; valuation rolls 2 [5] | **Category form only** — `/search-records/statutory-records/stat_births` (and `stat_marriages`, `stat_deaths`, `/census-returns/census`, `/church-registers/church-births-baptisms`, `/legal-records/wills`, `/tax-records/vr`…). Form is a Drupal POST rendered only after login ("Register or login to search births records"); a guessed `/record-results?…` URL 404s. | **No** | "use robots, spiders, crawlers, scraping or other data extraction, data mining or automatic access tools" is prohibited; content for "personal or professional family history research… private study or educational use" only; Crown copyright [4]. robots: `Disallow: /search/`, `/search?` | Record type + year + RD number/name + entry no. (e.g. "Statutory registers Births {year} {RD}/{n} {entry}"); OPR: parish no. + parish + date |
| **Old Parish Registers — other routes** | FamilySearch indexes much of the OPR baptisms/marriages (collections 1771030, 1771074); FreeREG has a little | Free | FamilySearch link (§5) | No | As above | ARK |
| **ScotlandsPlaces** | — | — | — | — | **Closed 24 June 2025** ("the website is no longer available"); robots still served | — |
| **NRS online catalogue** (catalogue.nrscotland.gov.uk/nrsonlinecatalogue) | Item-level catalogue of NRS holdings (court, estate, church, kirk session) | Free | **No** — ASP.NET WebForms postback (`__VIEWSTATE`, `txtKeyword`, `txtReference`, `txtDateFrom/To`); link to `search.aspx` | **No** (Cloudflare fronted, passive challenge script injected; no robots.txt — 404) | Not read (**unverified**) | NRS reference (e.g. `CH2/…`) |
| **National Library of Scotland** | OS maps (maps.nls.uk), directories, Scottish post office directories | Free | Map viewer URLs by lat/long | Not surveyed | — | Map sheet / directory page |
| **FreeCEN (Scotland)** | Best free coverage of 1841/1851 Scottish census | Free | No (see 2a) | No | See 2a | See 2a |

## 3. Worked example (generic)

An ancestor born in a Cornish mining parish c.1850 who moved to Lancashire, and a spouse born in Lowland
Scotland c.1855. What each route can add:

| Question | Record | Where | Route |
|---|---|---|---|
| Birth registration + mother's maiden name | GRO birth index 1837–1934 | GRO (login) / FreeBMD | Link → bring-back GRO ref; PDF £8 |
| Baptism, parents' names, father's occupation | Cornish parish register | **Cornwall OPC** | Link now; adapter if OPC permits |
| Households 1851–1911, birthplaces, occupations | Census | FreeCEN (partial) / FMP / Ancestry / FamilySearch 1881 & 1911 indexes | Link + bring-back |
| Still alive in 1921? | 1921 census | FMP only (index free, image £2.50) | Link |
| Scottish spouse's birth (statutory 1855→: parents' marriage date and place!) | Statutory birth | ScotlandsPeople (£1.50 image) | Link + bring-back |
| Spouse's parents' baptisms pre-1855 | OPR | ScotlandsPeople / FamilySearch 1771030 | Link |
| Grandparents' wills | PCC wills pre-1858 (PROB 11); calendars 1858→ | **TNA Discovery API**; Probate Search | **Adapter** (Discovery); link (probate) |
| Navy or army service | ADM 188 / WO 97 / WO 363 | **TNA Discovery API** | **Adapter** (reference), images paid |
| Burial place | Council burial registers; headstones | Deceased Online, Find a Grave, BillionGraves | Link |
| Newspaper notices | Local press | BNA (sub), Welsh Newspapers Online (free, Wales to 1919) | Link |

Expectation: an English line usually reaches the 1700s through parish registers (from 1538, survival
varies); a Scottish line reaches 1855 cleanly (Scottish statutory births name the parents' marriage) and
then the OPRs, which are thinner and often lack mothers' maiden names before c.1820.

## 4. Ranked: automated adapter vs. link + "I found it"

Criteria for a true adapter (all required): plain HTTP GET with no challenge; robots does not disallow
the path; terms do not forbid automated access; results parseable; per-person, paced (≥ 1 s), cached per
subject, counts-only logging.

**Tier 1 — automated adapter (qualifies today)**
1. **TNA Discovery API** — extend the Irish `DiscoverySource` with English series: `PROB 11` for anyone dying in England/Wales before 1858, `ADM 188` / `ADM 139` / `ADM 196` for anyone flagged navy, `WO 97` / `WO 363` / `WO 364` / `AIR 79` for army/RAF. ≤ 3 requests per person, 1 rps, identified UA, store reference + Discovery id only (their "do not cache" line). OGL v3.

**Tier 2 — adapter only after written permission (link until then)**
2. **Cornwall OPC database** — clean GET, robots allow, verified HTML results. Copyright forbids copying transcriptions without consent and is silent on automation, so email the OPC coordinator describing: one person at a time, ≤ 3 requests, 1 rps, store counts + row links only, show the source acknowledgement. If yes, `CornwallOPCSource` for people born/married/buried in Cornwall.
3. **FreeUKGenealogy ODbL data** (offline) — request a FreeBMD (and later FreeCEN) extract; a local, licensed index searched on-device is the only ToS-clean way to automate the E&W BMD indexes. Needs Rick's call on any fee and on disk size.

**Tier 3 — pre-filled link + "I found it" bring-back**
4. FamilySearch (E&W and Scotland collections, §5) — best pre-fill, free.
5. FindMyPast incl. 1921 census — pre-fillable, free index search.
6. Find a Grave — **demote the existing adapter to this tier** (robots disallow).
7. Genuki — county/parish reference link (not a search).
8. Deceased Online — GET form, pre-fill to verify in a browser.
9. BillionGraves — pre-fill works in a browser (JS app).

**Tier 4 — blank-form link only (no pre-fill possible, or login first)**
10. FreeBMD / FreeCEN / FreeREG (POST + CSRF; automation forbidden).
11. GRO (login).
12. ScotlandsPeople (login; terms forbid automation).
13. NRS catalogue, Probate Search, Lancashire OPC (form/postback; 503/robots).
14. BNA, Welsh Newspapers Online, CWGC, UK Census Online (bot challenge to scripts; browser URL shapes **unverified** — pin after one manual check).

Explicitly not to do, anywhere: headless browsers, UA spoofing, cookie replay of a logged-in session,
or fetching a path robots disallows. The challenge page / robots line is the site saying "humans only".

## 5. URL templates for feature work

Placeholders in `{braces}`; percent-encode values (`ResearchText.percentEncoded`). **V** = verified today
(HTTP 200 + expected content), **B** = shape believed correct but blocked to scripts — verify once in a
browser and pin with a test, **F** = form landing only.

### Adapter endpoints
```
V  https://discovery.nationalarchives.gov.uk/API/search/records?sps.searchQuery={surname}%20{given}&sps.recordSeries={series}&sps.resultsPageSize=20
       series ∈ {PROB 11, ADM 188, ADM 139, ADM 196, WO 97, WO 363, WO 364, AIR 79}   (Accept: application/json)
V  https://discovery.nationalarchives.gov.uk/details/r/{discoveryId}              (citation link)
V  https://www.cornwall-opc-database.org/search-database/baptisms/index.php?t=baptisms&year_from={y1}&year_to={y2}&parish={parish}&forename1={given}&surname1={surname}&bf=Search
       (marriages/burials/banns: same pattern with t={table} — path names B, check in a browser)
```

### Pre-filled links
```
V  https://www.familysearch.org/search/record/results?q.givenName={given}&q.surname={surname}&q.birthLikeDate.from={y-5}&q.birthLikeDate.to={y+5}&q.birthLikePlace={England|Wales|Scotland}&f.collectionId={id}
       (shape as shipped in FamilyTreeResearchLinks; familysearch.org 403s to scripts, fine in a browser)
   Collection ids (confirmed via collection pages in search results today):
       1473014  England, Births and Christenings, 1538–1975
       1473015  England Marriages, 1538–1973
       1473016  England, Deaths and Burials, 1538–1991
       2285338  England and Wales, Birth Registration Index, 1837–2008
       2285732  England and Wales, Marriage Registration Index, 1837–2005
       2285341  England and Wales, Death Registration Index, 1837–2007
       2562194  England and Wales Census, 1881
       1921547  England and Wales Census, 1911
       1770890  Great Britain, Deaths and Burials, 1778–1988
       1771030  Scotland, Births and Baptisms, 1564–1950
       1771074  Scotland, Marriages, 1561–1910
       (1841–1901 E&W and Scotland census collection ids: UNVERIFIED — look up before shipping)
V  https://www.findmypast.co.uk/search/results?firstname={given}&lastname={surname}&yearofbirth={y}&yearofbirth_offset=5
       (firstname/lastname verified 200; yearofbirth names from the Irish doc; 1921-only filter B)
V  https://www.findagrave.com/memorial/search?firstname={given}&lastname={surname}&birthyear={y}&birthyearfilter=5&deathyear={d}&deathyearfilter=5&location={place}
B  https://billiongraves.com/search/results?given_names={given}&family_names={surname}&country=United%20Kingdom
B  https://www.deceasedonline.com/dec_search.php?s={surname}&f={forenames}&b={yearFrom}&e={yearTo}
B  https://www.britishnewspaperarchive.co.uk/search/results?basicsearch={terms}&exactsearch=false&retrievecountrycounts=false
B  https://newspapers.library.wales/search?query={terms}&range%5Bmin%5D={y1}&range%5Bmax%5D={y2}
B  https://www.cwgc.org/find-records/find-war-dead/search-results/?Surname={surname}&Initials={initials}
V  https://www.genuki.org.uk/big/eng/{CHAPMAN}      (e.g. CON, LAN, DEV); /big/sct/{code}; /big/wal/{code}
V  https://discovery.nationalarchives.gov.uk/results/r?_q={surname}%20{given}
```

### Blank forms (no pre-fill possible)
```
F  https://www.freebmd.org.uk/cgi/search.pl            (classic)  ·  https://www.freebmd2.org.uk/search_queries/new
F  https://www.freecen.org.uk/search_queries/new
F  https://www.freereg.org.uk/search_queries/new
F  https://www.gro.gov.uk/gro/content/certificates/indexes_search.asp   (→ login)
F  https://www.scotlandspeople.gov.uk/search-records/statutory-records/{stat_births|stat_marriages|stat_deaths}
F  https://www.scotlandspeople.gov.uk/search-records/census-returns/census
F  https://www.scotlandspeople.gov.uk/search-records/church-registers/{church-births-baptisms|church-banns-marriages|church-deaths-burials}
F  https://www.scotlandspeople.gov.uk/search-records/legal-records/wills
F  https://catalogue.nrscotland.gov.uk/nrsonlinecatalogue/search.aspx
F  https://www.gov.uk/search-will-probate
```

Region rule for the links (mirrors the Irish county rule): place string → England (Chapman code from
county name), Wales, Scotland; Cornwall adds the OPC link; anyone with a pre-1858 English death adds
PROB 11; occupation/notes matching soldier/sailor/army/navy/RAF adds the military series.

## 6. Decisions for Rick

1. 🔴 Find a Grave: demote `FindAGraveSource` to a pre-filled link (robots disallows `/memorial/search` since 2024-11-25), or keep it and accept the robots breach?
2. Approve extending the Discovery adapter with PROB 11 / ADM / AIR series (same caps as the Irish proposal).
3. Email the Cornwall OPC coordinator for permission (Tier 2)? I can draft it.
4. Email FreeUKGenealogy about an ODbL FreeBMD extract (possible fee; size unknown)?
5. Order: fold these links into the Irish Phase A pass (one `FamilyTreeResearchLinks` change, one bring-back sheet) rather than a separate feature.

## 7. Honest limits

- Every high-value E&W and Scottish index (GRO, FreeBMD, ScotlandsPeople, FMP census) is human-only by terms or login. Automation saves Rick the typing (pre-filled links) and the filing (bring-back); it does not do the searching for him outside Discovery.
- Several URL shapes are marked **B** because the site challenged every script request; they must be clicked once in Safari and pinned by a test before shipping.
- FreeREG's own T&C page 404'd today; the FreeBMD/FreeCEN wording is assumed to cover it (same organisation, same software).
- GRO's T&Cs, NRS catalogue licence, Probate Search terms and Welsh Newspapers Online reuse statement were not read today.

## 8. Sources (fetched 2026-10-01)

[1] https://www.freebmd.org.uk/terms.html · [2] https://www.freecen.org.uk/terms-and-conditions · [3] https://www.gro.gov.uk/gro/content/certificates/faq.asp (coverage and fees, read via curl) · [4] https://www.scotlandspeople.gov.uk/terms-and-conditions · [5] https://www.scotlandspeople.gov.uk/help-and-support/our-charges · [6] https://www.opc-cornwall.org/Structure/copyright.php · [7] https://www.findagrave.com/robots.txt · [8] https://www.freeukgenealogy.org.uk/about/opendata/open-data-for-use/ · [9] https://whodoyouthinkyouaremagazine.com/news/how-to-view-1921-census-records-online · [10] http://www.nationalarchives.gov.uk/terms-and-conditions/discovery-for-developers-about-the-application-programming-interface-api/ · [11] https://www.nationalarchives.gov.uk/terms-and-conditions/policy-on-use-of-website-and-catalogue-data/ · [12] https://lan-opc.org.uk/whatsnew.html · [13] https://www.deceasedonline.com/terms.php · [14] https://en.wikipedia.org/wiki/Welsh_Newspapers_Online · FamilySearch collection pages: https://www.familysearch.org/en/search/collection/{1473014, 1473015, 1473016, 2285338, 2285732, 2285341, 2562194, 1921547, 1770890, 1771030, 1771074} (ids confirmed via search-engine listings; the pages themselves 403 to scripts).

Probe log (status to a scripted GET, identified UA):
- 200, no challenge: freebmd.org.uk (`/robots.txt`, `/cgi/search.pl`), freebmd2.org.uk, freecen.org.uk, freereg.org.uk, freeukgenealogy.org.uk robots, scotlandspeople.gov.uk (`/robots.txt`, `/`, `/search-records`, `/search-records/statutory-records/stat_births`), scotlandsplaces.gov.uk (closure notice), cornwall-opc-database.org (robots, form, one results page: 854 rows), lan-opc.org.uk (robots, frameset), genuki.org.uk (robots, `/big/eng/CON`), deceasedonline.com, ukcensusonline.com landing, findmypast.co.uk (robots; search results 200 with a reCAPTCHA badge), findagrave.com (robots; search 200, 21 memorial links), billiongraves.com (robots; search 200, JS shell), discovery API (3 queries, JSON).
- Redirect: gro.gov.uk index search → `Login.asp`; `/robots.txt` → home page. TLS: incomplete chain (Python fails, curl ok).
- 200 with passive Cloudflare script: catalogue.nrscotland.gov.uk (`/robots.txt` 404).
- 403 Cloudflare challenge: britishnewspaperarchive.co.uk (robots + search), newspapers.library.wales (robots + search, also with a Safari UA), ukcensusonline.com `/search/`.
- 403 (non-Cloudflare): cwgc.org (robots + search, also with a Safari UA).
- 503: probatesearch.service.gov.uk.
- 404 (moved T&C pages): freereg `/cms/terms-and-conditions`, findmypast `/terms-and-conditions`, findagrave `/terms-of-service`.
