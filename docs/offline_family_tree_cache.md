# Offline Family Tree Cache

## Goal

Keep Hallie's family-tree answers and the Family Tree tab useful when the
designated Master Archive is temporarily offline, without weakening archive
authority or creating a second editable family tree.

The cache is a read-only, derived snapshot of a GEDCOM file that VideoScan
previously read from the safely mounted Master Archive. It is not a backup,
sync service, or source of truth. Photos are a separate problem and are not
copied by this design.

## Required invariants

1. The Master Archive's `40_Family_Tree/GEDCOM` directory remains authoritative.
2. VideoScan refreshes the cache only while the designated archive is online
   and its recorded volume identity matches. A same-named or wrong-UUID volume
   must not refresh it.
3. An offline session may read a cached snapshot but may never write through it.
4. The UI and Hallie must say that the tree is an offline snapshot and show its
   capture time. They must not claim that the Master Archive was consulted in
   the current session.
5. A corrupt, incomplete, identity-mismatched, or unprovenanced cache fails
   closed. The existing demo tree may still appear, but it must remain labeled
   as demo data.
6. The existing no-Master legacy Application Support GEDCOM path remains a
   separate compatibility mode. It must never be mistaken for an offline cache
   of a designated Master Archive.

## On-disk representation

Use Application Support because the snapshot is private application state:

```text
~/Library/Application Support/VideoScan/family-tree/offline-cache/
  manifest-v1.json
  tree-<sha256>.ged
```

The manifest should contain:

- schema version;
- SHA-256 of the exact GEDCOM bytes and cached filename;
- byte count;
- source filename and source modification date;
- capture timestamp;
- designated Master Archive volume identity, using the same stable identity
  already enforced by `masterArchiveIdentityRefusal()`;
- source-relative path (`40_Family_Tree/GEDCOM/<name>.ged`);
- parsed person and family counts;
- parser/schema version, so incompatible parser changes can invalidate or
  rebuild the cache.

Write the GEDCOM and manifest into a private staging directory, validate and
parse the staged GEDCOM, `fsync` as appropriate, then atomically replace the
published manifest. Content-addressing prevents a partial replacement from
making old metadata point at new bytes.

Retain only the active snapshot plus one previous valid snapshot for recovery.
Cleanup is best-effort and must never delete the active file before the new
manifest is durable.

## Refresh policy

Refresh after `FamilyGraphFileLoader` has selected and successfully parsed the
newest valid archive GEDCOM, not merely after seeing a `.ged` extension.

Skip the write when the active manifest already has the same byte hash. This
makes normal app launches read-only in practice and avoids unnecessary SSD
writes. A viewer/read-only VideoScan session may read an existing cache but
must not refresh it; cache publication belongs to an authorized read-write
session with a safely verified Master Archive.

Do not refresh from:

- an explicitly supplied standalone `--gedcom` path;
- the no-Master legacy Application Support directory;
- a designated archive whose volume is offline or identity-refused;
- a symlink, alias, non-regular file, empty file, or failed parse;
- a file that changes identity, size, or modification metadata while it is
  being hashed and copied.

## Load policy and state

Replace the current binary live/unavailable distinction with an explicit
source descriptor carried beside the parsed graph:

```swift
enum FamilyGraphSource: Equatable, Sendable {
    case masterArchive(file: String, modifiedAt: Date?)
    case offlineCache(sourceFile: String, capturedAt: Date, sha256: String)
    case legacyApplicationSupport(file: String, modifiedAt: Date?)
    case demo
    case unavailable(reason: String)
}
```

Loading order:

1. No Master designated: preserve the current preferred/legacy Application
   Support behavior. Do not consult a cache associated with some old Master.
2. Master designated and safely online: load the archive directly. Refresh the
   cache only under the policy above.
3. Master designated but unavailable: load only a valid cache whose recorded
   volume identity matches the currently designated Master.
4. No valid matching cache: remain unavailable/demo with an honest explanation.

The graph and its `FamilyGraphSource` must be installed as one value so a UI
reload cannot display cached people with live-archive provenance, or vice versa.

## User-facing behavior

The Family Tree tab should use a persistent amber banner, for example:

> Master Archive is offline. Showing the read-only family-tree snapshot saved
> August 25, 2026 at 1:20 PM.

Hallie's basis line should similarly say:

> Basis: offline GEDCOM snapshot captured from the verified Master Archive on
> August 25, 2026; the archive is not connected now.

Photo and crest lookup remains unavailable unless separately cached under an
equally explicit policy. A cached GEDCOM must not cause `FamilyAssetStore` to
claim that `40_Family_Tree/People` is online.

The Reload control should re-read the cache while offline and the archive while
online. It should not imply that an offline refresh contacted or synchronized
with Ancestry, FamilySearch, or any network service.

## Suggested implementation seams

- Add `OfflineFamilyGraphCache`, injected with its root and `FileManager`, to
  own manifest validation, atomic publication, and bounded cleanup.
- Extend `FamilyGraphFileLoader.Outcome` or introduce a higher-level loader
  result that carries the selected URL and `FamilyGraphSource` together.
- Have `FamilyAssetConfiguration` carry the designated archive identity needed
  to validate a cache, rather than inferring authority from a pathname.
- Have `FamilyTreeLiveModel` publish the source descriptor and derive its banner
  from that value.
- Pass the same descriptor into Hallie's graph inputs so deterministic answers,
  cards, shell output, logs, and provenance follow-ups agree.

Do not put offline-cache fallback inside `FamilyAssetStore.photoURLs`; GEDCOM
relationships and presentation images have different authority and privacy
requirements.

## Test matrix

- Online verified Master loads directly and publishes one valid snapshot.
- Identical source bytes do not rewrite the cache.
- New valid GEDCOM atomically replaces the active manifest and retains the
  previous valid snapshot.
- Newer corrupt GEDCOM does not replace the last good snapshot.
- Offline matching Master loads the cache and reports cached provenance in the
  tab, Hallie app, and standalone shell.
- Wrong UUID, another designated Master, missing manifest fields, hash/size
  mismatch, parser-version mismatch, symlinked cache file, truncated write, and
  path traversal all fail closed.
- Read-only/viewer mode never creates, replaces, or deletes cache files.
- No-Master legacy mode never consumes a cache tied to a former Master.
- Cached GEDCOM availability never makes photos or crests appear online.
- A source replacement during copy is rejected rather than publishing mixed
  bytes and metadata.

## Rollout

Land the source descriptor and cache reader first with no writer enabled. Test
it against synthetic manifests and explicit fixtures. Then enable atomic cache
publication behind diagnostics, and finally expose the offline banner and
Hallie provenance. This keeps the authority change observable and reversible.
