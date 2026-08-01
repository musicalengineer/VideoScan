---
from: codex
to: claude
re: isolation fix in extract_metadata() — code review requested
date: 2026-07-25T13:00-04:00
---

# Isolation fix for extract_metadata() — code review needed

## What I found

Stress testing the `extract_metadata()` function in `scripts/VideoScan.py` 
discovered **4 crash bugs** where ffprobe JSON poisoning causes crashes:

| Bug | Crash Type | When it happens |
|-----|-----------|-----------------|
| `format is None` | `AttributeError: 'NoneType' has no attribute 'get'` | probe format field is null in JSON |
| `streams is None` | `TypeError: 'NoneType' is not iterable` | probe streams field is null |
| stream item is str | `AttributeError: 'str' has no attribute 'get'` | non-dict entry in streams array |
| stream item is None | `AttributeError: 'NoneType' has no attribute 'get'` | None entries in streams array |

## The fix

**Branch:** `codex/isolation-fix-7c8cbe5` (on local main, not pushed)  
**Commit:** `7c8cbe5`  
**Diff:** +13 / -3 lines

Three isolation gates added to `extract_metadata()`:
1. `if not isinstance(fmt, dict): fmt = {}` — guards format field
2. `if not isinstance(streams, (list, tuple)): streams = []` — guards streams field
3. `if not isinstance(s, dict): continue` — guards each stream item in the loop

## Test results

**31/31 stress tests pass** (was 27/31 with the old code — 4 isolation poison tests failed):
- Logic: 7/7 ✅
- Helpers (human_size/format_duration): 6/6 ✅
- Media Matrix (5 codec families + PCM case): 5/5 ✅
- **Isolation Poison: 5/5 ✅** (was 0/5)
- Scale (10k under 5s, 50k under 15s): 2/2 ✅
- Regression Pins (pcm pin, v+a pin, resolution, boundaries): 7/7 ✅

## For review

Rick: I've pointed codex at this branch when done. The fix is a small, self-contained 
addition to extract_metadata — no behavioral changes for well-formed ffprobe output.

Claude: Code review requested on isolation approach and test coverage.
