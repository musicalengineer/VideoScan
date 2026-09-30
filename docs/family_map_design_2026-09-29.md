# Family map — design (GH #227)

Rick 2026-09-29, after Donna's Walk Tree demo: keep the walk animation; when it
completes, clicking a place or name switches to a MAP — regions shaded by how
many ancestors were born there; click a region → names and counts.

## 1. What the data actually says (39k-person compiled tree, 2026-09-29)

Birthplace strings sampled from the current compiled generation (12,694 with a
recognisable trailing country):

| Country | Births | Second-level unit the strings carry | Distinct |
|---|---:|---|---:|
| England | 9,624 | **Historic counties**: Yorkshire 661, Suffolk 606, Kent 482, Essex 427, Cheshire 415, Lancashire 414, Norfolk 382, Devon 355, Somerset 312 … Cumberland 45, Westmorland 45, Huntingdonshire 19 | 425 spellings, ~45 real counties |
| Scotland | 1,586 | Historic counties: Aberdeenshire 115, Perthshire 98, Midlothian 93, Fife 82, Lanarkshire 80, Ayrshire 72 … Forfarshire, Haddingtonshire (pre-1975 names) | ~35 |
| Wales | 512 | Historic counties: Monmouthshire 65, Glamorgan 55, Denbighshire 44, Montgomeryshire 32 … | ~15 |
| Ireland | 85 | Counties (County Antrim, Kilkenny, Wexford, Galway …) and provinces | ~25 |
| US | 828 | 378 "British Colonial America" with the COLONY as the next component (Massachusetts Bay Colony 188, Massachusetts Bay 76, Connecticut Colony 41, Plymouth Colony 18, Province of Massachusetts Bay 17, New York Colony 15 …); 450 modern: Massachusetts 179, Rhode Island 55, Connecticut 38, Virginia 33, South Carolina 33, Maine 22, New York 21, NH 16, VT 11 … | 20 states |
| Canada | 31 | Quebec 12, Nova Scotia 12, New Brunswick 7 | 3 provinces |

The walk's own tally over ALL 39k (decorations.json): England 20,284 · Scotland
2,331 · Wales 720 · New England 838 · rest of US 69 · Canada 21 · Ireland 104 ·
elsewhere 825 · unknown 1,698.

**Design consequence:** the map that matters most is **England by historic
county**, then Scotland and Wales by historic county. "England = one blob with
20,284" is not a map. US-by-state is the second map (New England colonies fold
into states exactly as `BirthplaceClassifier` already folds them). The issue's
scope list (US states, England, Scotland, Wales, Ireland, Canada) stands; the
UK part goes one level deeper than the issue assumed.

The units must be **historic** counties (pre-1974 England/Wales, pre-1975
Scotland): the tree's births are 1300s–1800s and its strings say Yorkshire,
Cumberland, Westmorland, Forfarshire — modern council areas would mismatch
most of the data.

## 2. Borders (bundled, offline, no vendor account)

| Layer | Source | Licence | Prepared size |
|---|---|---|---|
| Historic counties of England, Scotland, Wales (+ NI) | Historic County Borders Project (Historic Counties Trust), SHP/KMZ, WGS84 | free for all personal, educational and commercial use; acknowledgement requested ("This mapping made use of data provided by the Historic County Borders Project") | ~0.6 MB after simplification |
| US states, Canadian provinces | Natural Earth 1:50m admin-1 (2.3 MB world file, filtered to US + CA) | public domain | ~0.4 MB |
| Ireland counties | Natural Earth 1:10m admin-1 filtered to IRL | public domain | ~0.1 MB |
| Country outlines (fallback shading for "England, no county") | Natural Earth 1:50m admin-0 map subunits (ENG/SCT/WLS/NIR/IRL/USA/CAN) | public domain | ~0.2 MB |

One prepared file `family-map-units.geojson` (FeatureCollection; properties
`key`, `name`, `country`, `kind` = county/state/province/country). Built by
`scripts/build_family_map_units.py` (dev-only; downloads, filters, simplifies
with Douglas–Peucker ≈ 0.01°, writes the file + `family-map-ATTRIBUTION.txt`).
The script is reproducible and committed; the downloads are not.

Target under 1.5 MB total. Attribution line goes in the About window.

## 3. Rendering: MapKit (recommended) vs our own canvas

| | MapKit `Map` + `MapPolygon` | Own `Canvas` projection |
|---|---|---|
| Look | a real map — coastlines, towns, pan/zoom; the "wow" | a chart; consistent with the fan's dark canvas |
| Offline | polygons draw; base tiles need network (cached after first view) | fully offline |
| Effort | lower for pan/zoom/labels | must write projection + pan/zoom |
| Risk | `_MapKit_SwiftUI` is a separate module — the SAME link hazard that crashed VideoPlayer on macOS 27 (52abfaaa): **link MapKit.framework explicitly + a link sensor like AVKitLinkSensorTests** | none |
| API | macOS 14+: `Map`, `MapPolygon`, `Annotation`, `MapReader`/`MapProxy.convert(_:from:)` for click → coordinate — all confirmed in the macOS 26 SDK | — |

**Recommendation: MapKit.** Donna's reaction is the point, and a real map with
shaded historic counties over real coastlines is it. Polygons are ours, so a
missing tile only greys the background.

## 4. Architecture (Core is pure and MapKit-free)

VideoScanCore (Foundation only, all testable without a display):
- `BirthplaceUnitResolver.resolve(_ place: String?) -> MapUnitHit?` — the
  place string → unit key + country + confidence. Same tokenisation as
  `BirthplaceClassifier` (right-to-left components, normalised); an alias
  table for the real spellings (Devon/Devonshire, Yorkshire + its ridings →
  Yorkshire, Fife/Fifeshire, Forfarshire → Angus, Haddingtonshire → East
  Lothian, Edinburghshire → Midlothian, Glamorgan/Glamorganshire,
  Caernarfonshire/Caernarvonshire, "County Antrim"/"Antrim", Massachusetts Bay
  Colony / Plymouth Colony / Province of Massachusetts Bay → MA, Connecticut
  Colony / New Haven Colony → CT, Province of New Hampshire → NH …). Unknown
  county but known country → the country unit (so "Yorkshire, England" shades
  Yorkshire; "England" alone shades England's outline).
- `MapUnits` — decode the bundled GeoJSON with JSONSerialization (own tiny
  decoder; MKGeoJSONDecoder stays out of Core); rings as `[(lat, lon)]`;
  bounding boxes; `unit(containing: coordinate)` by bbox prefilter + ray-cast
  point-in-polygon with holes and multipolygons.
- `FamilyMapTally.counts(...)` — per unit: people count, top surnames, member
  list (name, years, generation) from the walk result + the Highlight
  selection mask; optional `yearCeiling` for the time slider. One O(visited)
  pass; ≤ 50 ms at 39k.

App (FamilyTree/):
- `FamilyTreeMapView` — `Map` with one `MapPolygon` per unit that has a
  count, fill = a sequential ramp on log(count) (Rick's blue for his line /
  Donna's rose / violet for both, following `TreeWalkPalette`), stroke for
  every unit in scope; `Annotation` labels for the top N; `MapReader` click →
  `MapUnits.unit(containing:)` → side panel (same style as
  `TreeWalkHighlightPanel`: count, top surnames with counts, people nearest
  first). The camera opens on the bounding box of the shaded units.
- `FamilyTreeWalkSheet` gains a stage `.map(animator, highlighter,
  FamilyMapModel)`; "Show on map" button at Walk complete, and clicking a
  place row in the Highlight panel; "Back to the fan". Checked surnames /
  places filter the map exactly as they highlight the fan.
- Link `MapKit.framework` in the app target; `MapKitLinkSensorTests` (same
  shape as the AVKit sensor: dlopen RTLD_NOLOAD + dlsym a class symbol).

## 5. Stages

0. **Data prep** — the script, the prepared GeoJSON + attribution, a pytest
   that the file decodes, every unit has a key/name/country, total size < 1.5
   MB, and the key set covers the top-45 English, top-20 Scottish, top-12
   Welsh county names from §1 (synthetic list in the test — no personal
   data).
1. **Core** — resolver + alias table (tests: the §1 spellings resolve; the
   colonial forms fold to states; a lone country resolves to the country;
   scale: 40k strings < 100 ms), GeoJSON decoder + point-in-polygon (tests:
   a point in Yorkshire, in a hole, on a border, in the sea; 1,000 clicks <
   10 ms), tally (tests: counts add up to visited-with-a-unit; selection
   mask honoured; year ceiling).
2. **App** — the map view, the sheet stage, the side panel, the link sensor;
   About-window attribution. Rick's spot test + Donna.
3. **Time** — a year slider (births ≤ Y) and a "replay by generation" that
   moves the shading England/Scotland (1500s) → Massachusetts Bay (1630s) →
   west; reuse the fan's replay pacing.
4. **Flags (#229)** — same unit→country data, the country flag on cards.

Effort: stages 0–1 ≈ 1 day, stage 2 ≈ 1 day, stage 3 ≈ ½ day.

## 6. Five test dimensions

Logic (resolver, PIP, tally) · Scale (39k people tally; 1,000 clicks) ·
Media matrix (n/a) · Isolation (no network in tests; bundled file read from
the test bundle, never App Support) · Sensor (MapKit link sensor; a resolve-
rate floor on the synthetic county list; the GeoJSON size ceiling).

## 7. Open decisions (Rick)

1. MapKit real map (recommended) or our own offline canvas?
2. Bundle the Historic County Borders data under its acknowledgement
   licence (recommended — it is what makes the England map real).
3. Colonial New England births: shade the modern state (recommended; the
   classifier already does this) with a tooltip "recorded as Massachusetts Bay
   Colony".
