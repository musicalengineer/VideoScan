# Catalog write safety — design

**Status:** proposed, 2026-08-14. Supersedes the ad-hoc mtime guard currently
on `feature/catalog-write-safety`.
**Author:** Claude. **Review:** codex (#370, #376, #377). **Director:** Rick.

---

## 1. The problem, stated precisely

`catalog.json` is a **41 MB single-document database** rewritten wholesale on
every save, with **multiple concurrent writers across process boundaries**:

| Writer | Kind |
|---|---|
| VideoScan.app | interactive, long-lived, saves on debounce + on quit |
| `findtagd` | daemon, journal ingest |
| `merge_dossier_jsonl` and other Python tools | batch, expects live reload |
| maintenance scripts (`catalog_reduce.py`) | occasional, bulk |
| future MFO jobs | batch |

Readers include the headless Hallie shell and viewer Macs via `CatalogSync`.

On 2026-08-14 this produced real data loss: a maintenance script reduced the
catalog 18,142 → 8,760 records; the app was launched mid-operation, loaded the
pre-reduction file, and wrote its stale in-memory copy back over the result.
**9,382 records vanished with no error and no torn file**, then the stale copy
was written *again* on quit.

The failure was **not** a torn write. Atomic rename was already in place and
worked. Both writes were individually well-formed and correctly serialised.
The loser was simply *stale*. This distinction drives the entire design:

> **Mutual exclusion and lost-update prevention are different problems and
> need different mechanisms.** A lock alone would not have prevented this.

---

## 2. The honest architectural answer

This is a database problem being solved with a file. The canonical answer —
Rick's "solved many times" — is **SQLite**: single-file, embedded,
multi-process, ACID, WAL, the most widely deployed database engine in
existence. Records become rows, saves become transactions, a 41 MB rewrite
becomes an `UPDATE` of the rows that changed, and concurrency becomes the
engine's problem rather than ours.

Anything hand-rolled here is a worse SQLite. That should be stated plainly
rather than discovered in two years.

**But** migration touches every persistence path, the DTO layer, `CatalogSync`,
the Python tools, and the bundle import/export format. So this document
specifies a layered plan: what is correct *now*, what is correct *next*, and
the destination — with each layer independently shippable and each one leaving
the system better than it found it.

---

## 3. Patterns applied

Named deliberately, so reviewers can check the implementation against the
canonical form rather than against my prose.

| Pattern | Origin | Applied to |
|---|---|---|
| **Optimistic Concurrency Control** | Kung & Robinson, 1981 | The core lost-update fix. Version-stamp the document; write conditionally. Same shape as SQL `WHERE version = ?`, CouchDB `_rev`, etcd CAS, DynamoDB conditional writes, HTTP `If-Match`/ETag. |
| **Compare-And-Swap** | — | The atomic primitive under OCC: "replace generation N with N+1, only if still N". |
| **Single-writer principle** | LMAX Disruptor; actor model | One in-process owner of the mutation path. Eliminates a bug class rather than detecting it. |
| **Lease / ephemeral ownership** | Chubby, ZooKeeper | Locks expire, so a hung or `SIGKILL`ed holder cannot block forever. |
| **End-to-end argument** | Saltzer, Reed & Clark, 1984 | Verify integrity at the endpoint. Do not trust "the filesystem said it wrote". Hence read-back checksums. |
| **Write-ahead logging** | ARIES | Layer 2: append the delta, apply later. Turns a 41 MB rewrite into a small append. |
| **Fail-open for advisory mechanisms** | operational practice | An advisory lock that bricks saving when it malfunctions is a worse bug than the one it prevents. |

---

## 3b. Investigation results (2026-08-14 afternoon) — who actually writes?

Rick proposed the simplest rule: *scripts are blocked while the app runs.*
Investigated before adopting:

- **`findtagd` never writes catalog.json** (`FindTagCLI.swift:10`, explicit).
  The daemon writes journals; the app ingests and saves. Not a concurrent
  writer.
- **The dossier pipeline concurrently writes BY DESIGN.**
  `VideoScanModel+LiveReload.swift` polls catalog.json every 30 s precisely so
  external workers (`dossier_batch.py` on other hosts → `merge_dossier_jsonl.py`)
  can write while the app runs. Blanket exclusion would kill a supported,
  actively used workflow.
- The live-reload merge is **field-partitioned**: dossier-channel fields
  (captions, transcripts, OCR, inferred dates) merge from disk; user-channel
  fields (starRating, people, dispositions, notes) are never overwritten.

**Conclusion — the catalog has two channels with two owners**, and the merge
function between them already exists and is tested. Therefore:

1. **App on stale generation → reconcile, then save.** Run the existing
   dossier merge, then write. Refusing outright (my first design) throws away
   dossier work; clobbering (main today) loses it silently. Note this closes a
   race that exists TODAY without any scripts misbehaving: an app save landing
   inside the 30 s poll window silently clobbers freshly merged dossier fields.
2. **User-channel scripts (reduce/purge/dedup) → refuse while the app runs.**
   Rick's rule, applied exactly where it is correct. Human-run, rare, and
   "quit the app first" costs nothing.
3. Generation counter + per-write flock under both, as below.

## 4. Layer 0 — correct now

### 4.1 Generation counter replaces mtime

**mtime is not a generation identity.** It fails open on: `stat` returning nil,
a file deleted and recreated, changes inside the coarse-timestamp window,
equal-or-older replacements, backdated writes, and — concretely — **preserved
timestamps**: `shutil.copy2`, which the very script that caused the incident
uses, preserves mtime by design.

Replace it with a monotonic counter **inside the document**:

```json
{
  "version": 6,
  "generation": 12345,
  "writerID": "RicksM4/VideoScan/4711",
  "savedAt": "2026-08-14T19:12:00Z",
  "records": [ … ]
}
```

`version` and `generation` are the **first two keys** so a reader can obtain
the generation from the first ~200 bytes without parsing 41 MB. The staleness
check therefore costs one short read, not a full decode.

**Write protocol (CAS):**

1. Acquire the advisory lock (§4.2).
2. Read only the header of `catalog.json`; extract `generation`.
3. If it differs from the generation this session loaded → refuse with
   `.staleGeneration(loaded:onDisk:)`. **Do not retry blindly** — the
   in-memory copy must be reconciled first, or the retry reintroduces exactly
   the lost update the check exists to prevent.
4. Write with `generation + 1` via atomic rename.
5. Read back and verify SHA-256 (§4.4).
6. Update the session's loaded generation.
7. Release the lock.

Schema note: `generation` is **additive and optional** on read (absent ⇒ 0),
so older builds and existing catalogs load unchanged. No version bump needed.

**Amendment 2026-08-19 (GH #165 — the 248 → 1 reset).** "First two keys" was
a promise the encoder did not keep: `JSONEncoder` on this OS emits keyed
objects in per-process-random order (`CodingKeys` order is *not* honoured), so
the live file was written `{"records":[…36 MB…],"generation":248,…}`, the
head-only probe returned nil, load baselined at 0 and the next save stamped 1.
Three changes, all in `CatalogStore.swift` / `CatalogGenerationSidecar.swift`:

1. **The header is hand-built.** `CatalogSnapshotDTO` is no longer `Encodable`;
   the only way to bytes is `encoded(using:)`, which writes
   `{"version":V,"generation":G,"savedAt":…,"savedFromHost":…[,"masterArchive":…],"records":[…]}`
   itself and lets the encoder handle only the scalars and the records array.
   Every writer (saveNow, saveAsync, writeSnapshot, writeSnapshotAsync,
   exportCatalog, bundle export) therefore agrees by construction. Snapshots
   carry the real current generation, never 0.
2. **The probe reads both ends.** `headerProbe` reads the first 4 KB and, if a
   stamp is missing, the last 4 KB (lossy UTF-8 so a split multibyte
   character cannot blank the window). Every historical layout — any
   permutation of the six top-level keys around `records` — is covered.
3. **No silent downgrade.** `catalog.generation.max` beside catalog.json
   remembers the highest generation ever seen (bootstrapped once from every
   `catalog*.json` sibling). A load whose on-disk generation is *below* that
   mark logs at fault level and the next write stamps `max(seen, onDisk)+1`;
   a probe miss on a file that decodes with a generation logs at error level
   and uses the decoded value. The OCC comparison still uses the true on-disk
   value, so a foreign writer bumping a regressed file is still caught.
   The sidecar is a one-line text file: an operator can seed it by hand.

### 4.2 Per-write lock, not process-lifetime

The current implementation holds the lock for the app's whole session. That is
too coarse and codex is right that it breaks the supported live
`merge_dossier_jsonl` reload — an external tool could never write while the app
was open.

**Acquire per write, hold for the critical section only.** Combined with OCC
this is safe: if a writer sneaks in between another's read and write, the
generation check catches it. Mutual exclusion protects the write itself;
OCC protects the *decision* to write.

The lock keeps `flock(2)` with `O_CLOEXEC` — kernel-released on crash,
`SIGKILL`, and force-quit, so no stale lock survives a dead process. It
**fails open**: if the lock file cannot be created, journal loudly and proceed.

Add a **lease timestamp** in the lock metadata so a pathologically long holder
is visible to waiters and to humans reading the file.

### 4.3 Blocker: future-schema load must disable writes

Independent of concurrency, and present on `main` today: `load()` refuses a
newer-schema catalog and returns `[]`, but **does not disable writes** — so the
unconditional save on quit can overwrite a newer catalog with an empty one.

`load()` must set a latch (`writesDisabledReason`) that every write path
checks. This is a data-loss path and should be fixed regardless of the rest of
this document.

### 4.4 Integrity and reporting

- **Read-back SHA-256** after every write. Atomic rename guarantees no torn
  file; it does not guarantee the bytes that landed are the bytes produced.
  Truncation, media errors, and filesystems that lie about durability all
  survive an atomic write. Cost measured: 400 MB in 0.14 s.
- **Typed errors** with frozen numeric codes and an `isTransient` flag.
- **Append-only JSONL journal** beside the catalog, opened and closed per
  append — a clobber attempt is exactly when you cannot assume the process
  survives to flush a buffer. Needs bounding (§6).

---

## 5. Layer 1 — single writer

Introduce a `CatalogWriter` actor as the **sole** mutation path in-process.
Every save routes through it; `saveNow`, `saveAsync`, `scheduleSave`, and
`writeSnapshot` become thin callers. It owns the lock, the generation, and the
journal, and it serialises writes without the main actor blocking.

Give it a **bounded waiter queue**: callers may opt to wait for the lock with a
timeout rather than fail immediately. That is the "waiters are fine" Rick asked
for, and it belongs here rather than as an unused API on the lock.

For external cooperation, publish the write protocol as a tiny documented
contract so the Python tools can implement it in ~20 lines: take the lock,
check generation, write, verify, release. `catalog_reduce.py` becomes the
reference implementation.

---

## 6. Known gaps, tracked

| Gap | Severity |
|---|---|
| Journal is unbounded and its append is not race-safe across processes | medium — needs size cap + rotation, and `O_APPEND` |
| Read-back verification doubles peak memory on a 400 MB payload | medium — stream the hash instead of holding two buffers |
| No child-process sensor proving `O_CLOEXEC` actually holds | low — testable by spawning and checking lock availability |
| `scheduleSave` / `writeSnapshot` not yet behind the precondition | high — until Layer 1, these bypass every guard |
| External Python writers do not cooperate | high — the original incident path |

---

## 7. Recommendation

Ship **Layer 0** as one reviewed slice: generation counter, per-write lock,
future-schema write latch, integrity, typed errors. It is small, independently
testable, and closes the actual incident plus a live data-loss bug.

Then **Layer 1**, which is where the design becomes genuinely sound rather than
merely defended.

Then evaluate **SQLite** honestly against the cost of continuing to maintain a
hand-rolled concurrent document store. The answer will probably be SQLite, and
knowing that now should stop us gold-plating the JSON path.

**Do not merge the current `feature/catalog-write-safety` branch as "safe".**
It is a real improvement over `main` — which has no lock, no staleness check,
no checksums, and no error reporting — but its mtime guard is the wrong
mechanism and should be replaced by §4.1 before anyone relies on it.
