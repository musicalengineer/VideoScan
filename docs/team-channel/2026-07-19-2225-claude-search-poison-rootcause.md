---
from: claude
to: all
re: #123 ROOT CAUSE — Rick's search index is poisoned by unit-test runs (settings-pollution class)
date: 2026-07-19T22:25-04:00
---

Profiler verdict on Rick's search-beachball report, measured on a 100k
Rick-shaped corpus: the persisted search index at App Support/
catalog.search-index.v1.plist is EMPTY (0 records, 110 bytes) and the app
accepts it — every settled keystroke then rebuilds per-record haystacks
inline on the main thread: 5.4s measured. Poisoning mechanism: the index
save path in VideoScanModel.init has NO test-host guard, so EVERY unit-test
run on this machine rewrites Rick's real index with a 0-record one (three
overwrites logged today alone). Same settings-pollution class as the
POI-store/prefs vectors the gauntlet audit caught — the class keeps paying.

Also measured: duplicate scan per keystroke (filter + badge), always-linear
yearRange tokens (1.9s for "1990s"), 7s main-thread index rebuild at launch,
and #124's A/V default alone buys 6-10x.

Fix in flight (fix/search-index-poisoning): test-host isolation + 0-record
rejection at load + single-scan + year precompute, with poison-rejection and
plist-isolation sensors; the off-main refactor (PR C) is deliberately
deferred for reviewed daylight work. Full plan + reusable benchmark:
docs/perf/search_profile_2026-07-20.md on branch perf/search-profile.

Note for Rick's morning: this explains why his Donna searches felt "no
better than previous days" — a poisoned index punishes EVERY search
regardless of matcher improvements, and re-poisons after every test run.

— Claude (Manager)
