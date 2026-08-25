# VS app gets gedcom data using its own script loosely based on getmyancestors or similar

Status: design decision — step 1 (depth cap, docs, Hallie route) landed 2026-08-25; steps 2–4 in progress (codex)
Date: 2026-08-25

## Decision

Do **not** replace `getmyancestors` with a VideoScan-owned FamilySearch network
client today.

Keep the present Terminal hand-off to an independently installed, unmodified
`getmyancestors`, but correct and harden VideoScan's orchestration around it:

1. Remove VideoScan's artificial eight-generation limit.
2. Let one `getmyancestors -a N` invocation walk as far as requested, stopping
   naturally when a line has no more parents.
3. Treat process exit status, not merely a GEDCOM trailer, as the first success
   condition.
4. Stage each run separately, validate it, record provenance, and install it
   only after all checks pass.
5. Keep the FamilySearch username/password prompt in Terminal, inside the
   external tool. VideoScan must not receive, forward, store, or log either the
   password or an access token obtained by this unsupported login path.

If FamilySearch later grants VideoScan an approved Production app key, replace
the external tool with a clean-room **native Swift** implementation based on
FamilySearch's published API and OAuth/PKCE documentation. A separate Python
network script would add deployment and security surfaces without solving the
app-key problem.

The requested title says "using its own script." The conclusion of this review
is narrower: VideoScan should own the request, run protocol, validation,
manifest, installation, and Hallie-facing data model. It should not yet own the
FamilySearch authentication/API client.

## Why the sparse tree changes the depth calculation

The theoretical size of a perfect pedigree is not a useful estimate for this
archive. Most of Rick's lines stop before seven generations. A few lines may
continue much farther, but the traversal should follow only parent links that
actually exist.

The correct work model is a frontier walk:

```text
frontier = {starting person}
seen = {}

for generation in 1...requestedDepth:
    frontier -= seen
    if frontier is empty: stop successfully
    fetch the people in frontier
    seen += frontier
    frontier = the returned, non-empty parent IDs
```

Repeated ancestors caused by pedigree collapse are identified by FamilySearch
person ID and fetched once. Missing parents simply remove a branch from the
next frontier. Therefore a request for twenty or forty generations is a depth
ceiling, not a demand for a complete binary tree.

A safety cap is still appropriate to prevent an accidental or malicious
unbounded run. The first revised UI should allow `1...40` ancestor steps, with
8, 12, 20, and 40 as convenient choices. Forty is a product safety limit, not
a FamilySearch API fact, and can be revisited using measured person/request
counts.

## What getmyancestors 1.2.0 actually does

The current VideoScan implementation assumes the FamilySearch
`/platform/tree/ancestry` endpoint's eight-generation request ceiling also
limits `getmyancestors`. It does not.

The installed `getmyancestors` 1.2.0 code:

- accepts an arbitrary integer for `-a/--ascend`;
- starts with the signed-in user's person ID or one or more supplied IDs;
- loops `range(args.ascend)`;
- discovers parents from the current people;
- reads people through batched `/platform/tree/persons?pids=...` requests;
- subtracts already-seen FamilySearch IDs;
- stops early when the parent frontier is empty;
- optionally retrieves spouses/marriages, sources, notes, memories, and
  contributors; and
- emits `_FSFTID` in the GEDCOM for each FamilySearch person.

Consequently, this is already valid:

```sh
getmyancestors -a 20 -m -u <username> -o <staging-file.ged>
```

The tool prompts for the password because VideoScan deliberately omits `-p`.
There is no need to perform three eight-generation pulls or merge them merely
to reach generation twenty.

### Depth semantics

`-a 1` performs one parent step. The GEDCOM contains the starting person plus
the parents that were found. VideoScan should label the setting **Ancestor
steps** or explain this explicitly instead of implying that the starting
person consumes one of the requested generations.

## Why VideoScan should not copy the network client

### Production access remains blocked

VideoScan cannot currently obtain its own FamilySearch Production app key
under the eligibility rules recorded in `familysearch_api_notes.md`.
Reimplementing HTTP calls does not change that.

The external tool currently:

- posts the FamilySearch username and password to the FamilySearch login
  service itself;
- uses a third-party client ID and redirect URI;
- exchanges the resulting authorization code for a Production access token;
  and
- does not implement the native-app OAuth/PKCE flow required for a new
  approved VideoScan integration.

Copying this behavior into VideoScan would make VideoScan responsible for the
password, borrowed key, and unsupported login flow while still leaving it
without an approved key. That is strictly worse than the current Terminal
boundary.

### GPL boundary

`getmyancestors` 1.2.0 is GPLv3-or-later. Calling an independently installed,
unmodified executable through a command line and files provides a clear
process boundary similar to VideoScan's use of `ffmpeg`.

Copying, translating, or closely adapting the tool's implementation into a
VideoScan-owned script could create GPL distribution obligations and an
ambiguous derivative-work boundary. This document is an engineering decision,
not legal advice; the conservative policy is:

- do not vendor its source;
- do not paste or transliterate its algorithms or GEDCOM writer;
- do not embed its default client ID or redirect URI in VideoScan;
- keep it separately installed and separately licensed; and
- base any future native implementation only on FamilySearch's public
  specifications and synthetic black-box fixtures.

## Current VideoScan workflow

The `feature/familysearch-pull` branch currently provides:

- a **Get Family Tree** sheet;
- explicit executable discovery in known locations;
- a preview of the exact command;
- a generated `.command` file opened in Terminal;
- a deliberate press-Return confirmation;
- an external `getpass` password prompt;
- a watcher for the staged GEDCOM;
- parsing and actual-depth reporting; and
- an explicit **Install family tree** step.

Those are good boundaries and should remain. The problems are in depth,
completion signaling, run isolation, cancellation wording, and provenance—not
in the basic Terminal hand-off.

## Problems to correct before merging the feature

### 1. Artificial eight-generation clamp

`FamilySearchPullRequest.ascendRange` is currently `1...8`, and the command
builder clamps larger programmatic requests to eight. Raise the product range
to `1...40` and add tests proving that 20 and 40 are emitted unchanged.

The existing documentation that instructs the user to re-root every eight
generations and merge exports is incorrect for `getmyancestors` and should be
removed when the code is changed.

### 2. A GEDCOM trailer does not prove success

VideoScan currently treats a file ending in `0 TRLR` as complete.
`getmyancestors` writes its GEDCOM in a Python `finally` block, so a failed,
cancelled, or partially completed traversal may still contain a syntactically
valid trailer.

The generated Terminal command should write a separate success sentinel only
after the external process exits zero, for example:

```text
<run-directory>/completed.json
```

The sentinel must contain no credentials or tokens. VideoScan may offer
installation only when all of these are true:

1. the exit-zero sentinel exists;
2. the GEDCOM ends with `0 TRLR`;
3. the GEDCOM parses;
4. it contains the requested starting `_FSFTID` when one was supplied;
5. person and family counts are internally consistent; and
6. the preflight comparison has completed.

### 3. Shared staging paths

Each pull should use a unique directory such as:

```text
~/Library/Application Support/VideoScan/family-tree/pulls/<run-uuid>/
```

The directory contains the generated command, staged GEDCOM, nonsecret status
sentinel, and manifest. A later run must never make an earlier watcher appear
successful.

### 4. Cancellation semantics

Stopping VideoScan's watcher does not stop the command already running in
Terminal. Until actual process control exists, label the action **Stop
watching** and explain that the Terminal job continues until the user presses
Control-C there.

VideoScan must not claim that it cancelled a download it does not own.

### 5. Enrichment cost

Sparse parent traversal is cheap compared with retrieving notes, sources, and
memories for every discovered person. The sheet should eventually offer:

- **Full family tree** — relationships, facts, spouses, sources, notes, and
  memory links; and
- **Trace deep lines** — relationships and basic facts first, with enrichment
  of selected people in a later run.

The initial correction can retain today's full behavior. Instrument person,
family, source, note, HTTP-request, and elapsed-time counts before deciding
whether a fast mode is necessary.

## Hardened external-tool protocol

### Request

The request contains only nonsecret values:

- username;
- optional starting FamilySearch person ID;
- ancestor-step ceiling;
- descendant-step ceiling;
- spouse/marriage choice;
- enrichment choices;
- bounded rate and concurrency settings; and
- unique staging output URL.

It must never contain a password, authorization code, access token, refresh
token, client secret, or third-party client ID override.

### Execution

1. VideoScan locates the independently installed executable.
2. VideoScan creates a unique run directory.
3. VideoScan writes and previews the exact command.
4. Terminal shows the command and waits for Return.
5. `getmyancestors` prompts for the password on its own TTY.
6. The generated command records the external exit status.
7. Only exit zero produces the success sentinel.
8. VideoScan validates and summarizes the output.
9. The user explicitly installs the new GEDCOM.

### Manifest

After successful validation, VideoScan writes a sidecar manifest containing:

- schema version;
- run UUID;
- retrieval timestamp and host;
- requested starting person ID;
- requested and actual ancestor depth;
- requested options;
- external tool name and version;
- person, family, source, note, and memory-link counts;
- GEDCOM byte count and SHA-256;
- validation results;
- previous installed GEDCOM identity/hash; and
- installed destination, if installation occurs.

Do not put the username, password, tokens, command environment, or raw Terminal
transcript in the manifest.

### Installation

Installation remains additive and explicit:

- use a dated, collision-resistant filename;
- never overwrite or delete the previous GEDCOM automatically;
- copy through a private staging file;
- parse and hash the final copy;
- atomically publish it into `40_Family_Tree/GEDCOM/`; and
- reload Hallie's graph only after the installed copy passes validation.

## Future native Swift implementation

This section becomes actionable only after FamilySearch grants VideoScan a
Production app key and approves the intended read behavior.

### Components

```text
FamilySearchAuthorizationClient
    system-browser OAuth authorization code + PKCE
    redirect validation
    Keychain token storage and disconnect

FamilySearchAPIClient
    versioned GEDCOM X requests
    redirects and merged-person handling
    ETags, Retry-After, bounded retries

FamilySearchTraversalActor
    sparse frontier walk
    FamilySearch-ID deduplication
    depth/person/request ceilings
    checkpoints, cancellation, and resume

FamilySearchGEDCOMExporter
    deterministic local IDs
    GEDCOM facts and relationships
    _FSFTID preservation
    source and memory-link mapping

FamilySearchPullInstaller
    validation, manifest, comparison, and atomic installation
```

### Native traversal

The native traversal should preserve the sparse-frontier behavior, regardless
of which documented FamilySearch read endpoints are used:

1. Read and confirm the starting person.
2. Maintain `frontier`, `seen`, and canonical merged-ID maps.
3. Fetch only IDs not already seen.
4. Add returned parent relationships.
5. Stop on empty frontier, requested depth, explicit person/request budget,
   cancellation, or unrecoverable authorization failure.
6. Checkpoint after each completed generation.
7. Fetch optional enrichment separately from relationship discovery.
8. Export a deterministic GEDCOM and manifest.

If the documented ancestry endpoint is used, its maximum of eight generations
applies to each request, not necessarily to the whole user-initiated traversal.
The actor can continue from returned frontier IDs, subject to approval,
throttling, and the run budgets.

## Reliability rules for either implementation

- Honor `429` and `503` `Retry-After` responses.
- Bound concurrency and every retry.
- Follow documented redirects for merged people and retain former IDs in the
  audit trail.
- Never silently replace local GEDCOM facts with remote values.
- Treat the local GEDCOM as authoritative until explicit installation.
- Minimize living-person data and never use it in tests or telemetry.
- Use synthetic API/GEDCOM fixtures only.
- Preserve `_FSFTID` so Hallie can cite the remote identity behind a claim.
- Distinguish a complete sparse traversal from a truncated or failed run.

## Test plan

### Current external-tool path

- `-a 20` and `-a 40` survive command construction without clamping.
- Empty branches report a shallower actual depth without being called errors.
- Repeated FamilySearch IDs do not inflate actual depth or person counts.
- No emitted command contains `-p`, `--password`, `--save-settings`,
  `--show-password`, client IDs, redirect URIs, or tokens.
- A trailer without an exit-zero sentinel is rejected.
- Exit zero without a parseable trailer is rejected.
- A wrong starting `_FSFTID` is rejected.
- Concurrent or consecutive runs cannot observe each other's artifacts.
- **Stop watching** never claims to terminate Terminal.
- Installation never overwrites the prior GEDCOM.
- Manifest and logs contain no username or secrets.

### Future native path

- OAuth state and PKCE validation failures fail closed.
- Tokens are Keychain-only and redacted from every log/error.
- Sparse, collapsed, cyclic, and merged-ID pedigrees terminate correctly.
- `301`, `304`, `410`, `429`, and `503` behavior is pinned.
- Cancellation checkpoints at a generation boundary and can resume safely.
- GEDCOM output is deterministic for the same canonical response set.
- Living-person fixtures are synthetic and remain private to the test.

## Rollout order

1. Correct the existing external-tool generation limit and documentation.
2. Add exit-zero sentinel and per-run staging.
3. Add the provenance manifest and stronger preflight.
4. Clarify watcher/cancellation behavior.
5. Measure deep sparse pulls and decide whether a relationships-first mode is
   worthwhile.
6. Keep the current FamilySearch Production-access blocker visible.
7. Only after approved access, design and implement the native Swift client.

## Non-goals

- No FamilySearch write-back.
- No scraping of FamilySearch web pages or historical-record images.
- No borrowed client ID embedded in VideoScan.
- No password field in VideoScan.
- No vendored or translated `getmyancestors` source.
- No assumption that a deep shared-tree lineage is verified history.
- No automatic deletion or replacement of prior GEDCOM snapshots.
