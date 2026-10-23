# Mylio Photos: technical profile and comparison with VideoScan

Research date: **October 16, 2026**. Prepared for Rick Breen.

**Assessment:** Mylio is a substantial photo-management and device-synchronization system with useful family-history features. VideoScan addresses a different, partly overlapping problem: recovering, understanding, and preserving legacy video/audio and relating it to family history. Mylio is a plausible companion for the photo collection; the documented product does not replace VideoScan's specialized media workflows.

## 1. Scope and evidence

This is a public-documentation technical profile, not a reverse-engineered implementation specification. Mylio was not installed or benchmarked, and no family media was imported or changed. Sources are Mylio's own support articles, engineering explanations, product pages, and release notes. Source links accompany claims. Search results from third-party reviews were not used as technical evidence.

Evidence labels used below:

- **Documented:** vendor describes the behavior. This is not independent verification.
- **Historical technical disclosure:** an older engineering explanation; useful, but not a guarantee about the current binary.
- **Inference:** engineering interpretation of documented behavior.
- **Unknown:** insufficient public evidence; not proof that a feature is absent.
- **Source-present:** VideoScan code implements the capability; it was not exercised during this research.

The VideoScan baseline is source at Git HEAD `5f5e49e7488420d4e69676bf0fbdee6db1c57c35`, with an already-dirty working tree. The comparison is a read-only inspection of relevant current sources, not certification of that commit or pending changes. The old two-file architecture description is obsolete.

Mylio's detailed manual at `manual.mylio.com` returned a Cloudflare access block. Accessible official support pages cover much of the same ground, but I could not verify the complete format/codec matrix, every export setting, or all advanced networking options. Those gaps remain explicit.

## 2. Product and release baseline

The current production release page lists **Mylio Photos 24.8**, with macOS/iOS build **7904**, and Windows/Android build **7905**. The latest entry is dated October 8, 2026. Its heading says Windows-only even though the build table also lists Android 7905; use the actual platform download/build when testing. The October 6 release includes an S3 NAS large-transfer fix. [Current release notes](https://support.mylio.com/change-log-and-release-notes)

A separate **Mylio Preview** is prerelease software, with a separate library, Windows/macOS support, and single-device operation. The vendor anticipates next-generation releases in late fall 2026 and into early 2027; pricing is not finalized. Preview capabilities must not be credited to production. Its documentation says to copy test media rather than link production-library folders. [Preview scope and limitations](https://support.mylio.com/mylio-preview-0)

The free Mylio Photos app provides library use; Photos+ adds synchronization and protection services. Current marketing also uses Personal, Duo, Family, Pro, and Team plan names. Entitlements should be checked for the exact plan, rather than inferred from older “Mylio Create” or “Premium” material. [Product definition](https://support.mylio.com/what-is-mylio-photos), [Current plan overview](https://support.mylio.com/how-much-does-mylio-photos-cost)

## 3. Platforms and deployment

| Platform | Documented minimum |
|---|---|
| Mac | macOS 11 or later |
| Windows | Windows 10 21H2 or later, 64-bit; Windows 11 |
| Windows ARM | Surface X Pro is explicitly listed |
| Android | Android 11 or later, 64-bit |
| iPhone/iPad | iOS/iPadOS 16 or later |
| Linux/server/Docker app | No supported Mylio client established in the reviewed requirements |

[Minimum system requirements](https://support.mylio.com/minimum-system-requirements)

The storage-planning article describes **64 GB for desktop application/working storage**, separate from the media library. This should not be interpreted as the executable's download size. Exact current RAM/GPU recommendations could not be checked in the blocked detailed manual. [Storage requirements](https://support.mylio.com/how-much-storage-do-i-need-for-mylio-photos)

Desktop clients can start at login and continue processing after their window closes. Background operations include watching folders, face analysis, SmartTags, and synchronization. The support documentation explicitly says mobile background synchronization is unavailable; mobile clients must remain in the foreground for sync. [Background operation](https://support.mylio.com/background-synchronization)

For Rick's machines, the Mac/iPhone/iPad clients are relevant; an old Intel Mac's actual OS version matters more than its age alone. NAS compatibility needs its own assessment, below.

## 4. Logical architecture

**Inference from documented components:** Mylio is a distributed media catalog with configurable local representations and replication policies. The original file, its metadata, its display proxy, and its physical copies are distinct concerns.

```text
Local folders / camera roll / Apple Photos / imported files
                          |
                     ingestion
                          |
        logical media item + catalog organization
            |             |                |
         original      XMP metadata    thumbnail / optimized image
            |             |                |
       per-device storage and synchronization policies
            |             |                |
        computers       mobiles        external-drive Vaults
                          |
              optional cloud / S3 storage
```

This is a conceptual diagram, not a disclosed class diagram or wire protocol. The Storage Panel explicitly exposes associated files, local/attached sync policies, original-copy locations, and import source/date. A photo can have an original, XMP sidecar, optimized representation, and thumbnail. [Storage Panel](https://support.mylio.com/understanding-the-storage-panel)

The system synchronizes media, edits, metadata, and organization through a private peer connection. Offline organization/editing is supported, with synchronization when connectivity returns. An accessible peer must possess a requested representation for it to be fetched. “Available offline” consequently depends on what that device has already stored. [Product architecture](https://mylio.com/details/)

### Disclosed implementation clues

Mylio's own careers material asks for C++14-or-later experience across Windows, Android, macOS, and iOS, specifically covering the UI, core engine, replication system, architecture, and performance. It also mentions Lua and relational-database experience for testing, and Python/C++ with PyTorch or TensorFlow experience for ML work. **Inference:** substantial shared C++ implementation is likely. The hiring page is not a current software bill of materials; it does not establish the UI toolkit, production inference runtime, or database engine. [Mylio engineering job descriptions](https://www.mylio.com/de/careers/)

Support identifies a catalog file named `Mylo.mylodb` and automatic `Mylo.mylodbbackup` copies. It documents replacement of a corrupt catalog with a backup. The extension does **not** establish SQLite, a relational schema, transaction isolation, or a public file-format contract. [Catalog recovery](https://support.mylio.com/troubleshooting-advanced-catalog-repair)

## 5. Ingestion, folders, and storage ownership

Mylio supports linking existing folders and bringing media into its library through import workflows. The distinction between linking a path and registering an external drive is operationally important.

If folders are linked before their external drive is registered, Mylio can associate them with the computer. Registering the drive later can create another copy in a `Mylio_...` folder. Correcting this by unlinking/relinking can preserve sidecar metadata while losing album membership, Events, and Categories. Register removable storage deliberately before building extensive organization. [Linked folders and external drives](https://support.mylio.com/linked-folders-and-external-drives-what-to-do-if-you-linked-first)

The external-drive replacement procedure describes identity as the combination of the drive's OS name and its Mylio system-folder name. Both must match to recognize a replacement as the same device. This is a documented recovery procedure, not proof that these are the only internal identifiers. [External-drive identity and replacement](https://support.mylio.com/advanced-replacing-or-rebuilding-an-external-drive-vault-by-copying-data-at-the-os-level)

Apple Photos/iCloud access is through a permitted Mylio client on macOS/iOS. The integration detects newly added images. This does not establish full round-trip equivalence of Apple albums, edits, people, and deletions. [Apple Photos/iCloud compatibility](https://support.mylio.com/is-mylio-photos-compatible-with-icloud-photo-library)

Import diagnostics can distinguish suspected duplicates, unsupported formats, corrupt files, and permission failures. That is valuable for migration accounting, although it is not a media-repair capability. [Skipped-import diagnostics](https://support.mylio.com/test/troubleshooting-files-skipped-during-import)

## 6. Image representations and capacity

**Documented:** SpaceSaver provides compact optimized images retaining metadata and editing capability. One support page describes roughly 10% of original storage; another claims up to 15 times more photos per device. These are workload-dependent vendor claims, not a capacity guarantee. [SpaceSaver](https://support.mylio.com/more-images-in-less-space-with-spacesaver), [Library limits](https://support.mylio.com/how-many-photos-videos-can-i-store-in-mylio-photos)

Historical release notes say optimized representations can retain RAW data using DNG technology. This is more capable than a JPEG contact-sheet thumbnail, but it does not imply identical spatial resolution or universal recovery of every property of the source RAW. [Optimized-image implementation history](https://support.mylio.com/version-22-release-notes)

Only a thumbnail is insufficient for image editing: the device needs an optimized image or original. [Editing representation requirements](https://support.mylio.com/error-message-editing-is-not-possible-without-an-optimized-image-or-original)

**Engineering capacity model:** budget separately for originals, sidecars/catalog, thumbnails, optimized photos, and temporary/cache space. A full Vault needs the complete originals, plus supporting state. For a collection with 2 TB of photographs and 8 TB of video, a hypothetical 10% photo-proxy ratio yields about 200 GB for photo proxies; it says nothing about reducing the 8 TB required to keep all original videos locally. This is an illustrative calculation, not a measured Mylio result.

No licensing item-count limit is documented, but storage, catalog size, initial indexing time, and device memory still impose practical limits. No reproducible million-item benchmark on Rick's hardware was located.

## 7. Synchronization and device policy

SyncCollections select what a device keeps using ratings, labels, flags, keywords, folders, dates, file types/extensions, sizes, and categories. Original and optimized-image rules are separately configurable. Presets can be reused. This amounts to declarative placement policy over the catalog, not simply mirroring one directory. [SyncCollections](https://support.mylio.com/create-a-custom-device-sync-policy-with-synccollections)

Documented operational prerequisites include signed-in devices, compatible updated versions, running clients, and connectivity over a local network or the internet. The troubleshooting guide includes an IPv6 toggle and firewall considerations. It does not publish a complete port/protocol specification. [Sync troubleshooting](https://support.mylio.com/troubleshooting-unable-to-sync-photos-between-devices)

A physically carried external drive can also move library data between computers. The intermediary's stored quality caps what the destination can receive. Thus a phone with thumbnails cannot serve as a substitute original-file transport. [Intermediary-device synchronization](https://support.mylio.com/black-or-gray-squares-in-mylio)

Low storage can pause synchronization across devices. Mylio maintains minimum-free-space thresholds and offers cache clearing and reduced-quality policies. This is an important test case for a library spanning small mobile devices and large desktop volumes. [Disk-full behavior](https://support.mylio.com/error-notification-disk-storage-full)

Release notes mention a temporary Sync Conflicts folder for significant device conflicts. Exact conflict ordering, merge granularity, delete tombstones, crash recovery, and whether any state uses CRDTs or version vectors are not disclosed in the reviewed material. [Conflict handling release notes](https://support.mylio.com/version-24-release-notes)

## 8. Vaults, backup semantics, and integrity

A **Vault** holds the entire library: full-resolution originals, XMP metadata, and catalog organization. The Dashboard distinguishes files still needing protection. With multiple target devices, an item can remain unprotected until all requesting destinations receive it. [Vault definition](https://support.mylio.com/what-is-a-vault-in-mylio-photos), [Protection accounting](https://support.mylio.com/troubleshooting-unprotected-images)

**Critical semantic distinction:** deleting a folder inside Mylio removes it and its contents from the library, filesystem, and synchronized devices, including Vaults. A Vault is therefore not inherently an immutable historical backup. [Deletion propagation](https://support.mylio.com/en/articles/9397456-deleting-a-folder-and-its-contents)

External filesystem deletion has configurable handling: restore from another original copy, remove only the local original, or propagate removal everywhere. Vault choices are more restricted. These policies apply to external changes, not in-app deletion. [External File Changes Policy](https://support.mylio.com/external-file-changes)

The product can identify Lost Originals when no original copy can be located. That records loss; it cannot reconstruct the missing original from catalog metadata. [Lost Originals](https://support.mylio.com/handling-lost-originals)

Mylio documents verifying files written to Drive+/SecureCloud. I did not find sufficient public detail to establish a full archive-fixity contract: digest algorithm, periodic readback schedule, immutable digest manifests, scrubbing/repair policy, or append-only provenance. These remain questions, rather than claims that Mylio performs no integrity checking. [Drive+ release description](https://support.mylio.com/version-24-release-notes)

**Assessment for FamilyArchive:** synchronized redundancy protects against device failure, but historical recovery needs a separate versioned/offline backup strategy. Mylio's own Mac NAS guidance suggests Time Machine or similar iterative backup for that purpose. [Mac NAS backup guidance](https://support.mylio.com/nas-devices-on-macos)

## 9. NAS and cloud storage

Mylio distinguishes three deployments that are easy to confuse:

| Deployment | Documented behavior / limitation |
|---|---|
| Ordinary NAS device registration | Standard configuration is documented as Windows-only |
| NAS folder linked from macOS | Possible, but disconnection marks the folder missing; better suited to a stationary Mac |
| S3-capable NAS | Can be presented as an S3 service; documentation gives Docker/MinIO as an example |

Other documented Mac alternatives include a Windows sync host, directly attached storage, or an independent NAS backup destination. Do not interpret the general “NAS supported” label as identical platform behavior. [macOS NAS limitations](https://support.mylio.com/nas-devices-on-macos)

For S3-compatible destinations, large files are fragmented and interrupted transfers can retry a failed fragment. Adjustable fragment size trades request overhead against retry cost and provider fragment-count limits. The support article names Backblaze B2, Wasabi, Amazon S3-compatible storage, and S3 NAS devices. It explicitly excludes Drive+/SecureCloud from this particular setting. No numeric default or full wire protocol is supplied. [S3 fragmentation](https://support.mylio.com/fragment-upload-size-for-cloud-storage-s3)

**Mylio Drive** provides encrypted optimized-image storage with Photos+. **Drive+**, with a SecureCloud add-on, supports originals and broader media types. They must not be treated as the same backup tier. [Drive versus Drive+](https://support.mylio.com/what-is-the-difference-between-mylio-drive-and-mylio-drive)

## 10. Media formats and video capability

The accessible official format summary confirms JPEG, TIFF, PNG, PSD, HEIC, and RAW support from many camera manufacturers. Exact RAW support depends on camera and release. The complete matrix was inaccessible during this research. [Format summary](https://support.mylio.com/what-types-of-photo-and-video-files-does-mylio-photos-support)

Mylio's January 2026 video guide confirms MP4, MOV, AVI, and WMV. It states that videos are not optimized/resized, need a locally available original for playback, and do not support automatic facial recognition. People can be tagged manually. Video annotations are kept in XMP sidecars. [Official video guide](https://inspire.mylio.com/how-to-organize-family-videos-with-mylio-photos/)

**Unverified for Rick's archive:** MXF, Avid OP-Atom pair handling, DV-in-AVI variations, ProRes variants, FFV1/PCM in MKV, multiple audio streams, damaged indexes, unusual time bases, subtitle streams, and timecode interpretation. Container admission is not equivalent to successful decoding, metadata extraction, or cross-platform playback.

No documented counterpart was found for orphaned Avid track correlation, UMID-based substitution, lossless A/V recombination, timestamped person-result segments, damaged-media rescue, or provenance-aware derivative publishing. These are unknown/undocumented counterparts, except the explicit video-face limitation above.

Mylio can export a photograph slideshow as a video. That is a distinct operation from searching a source movie and extracting matching temporal clips. [Slideshow video export](https://support.mylio.com/export-a-slideshow-as-a-video)

## 11. Photo face recognition: the most useful technical disclosure

**Historical technical disclosure:** engineer Tim Turner describes face detection, a **512-number descriptor**, and clustering in a multidimensional space. A person may own multiple clusters representing changes of age, pose, or appearance. Individual labeling names a face; batch labeling names the selected cluster's faces. New faces are proposed using similarity to labeled clusters. The article also describes dividing detection work among devices and rescanning lower-quality results on more capable computers. [Engineering explanation](https://news.mylio.com/how-face-recognition-technology-works/)

This supports a descriptor-and-clustering interpretation. It does **not** identify ArcFace, AdaFace, FaceNet, a particular network backbone, distance metric, ANN index, quantization format, or training dataset. A 512-dimensional descriptor alone cannot identify the model. The article's explanation of “learning” also does not establish per-user neural-network retraining.

Controls include per-device enablement, battery restrictions, a proposals-versus-accuracy slider, merging small batches, minimum batch size, and ignoring unwanted faces. The documented default proposal setting is about 80. Treat this as an application threshold, not a calibrated 80% probability of correct identity. [Recognition controls](https://news.mylio.com/customize-face-recognition-mylio/)

Auto-tagging can be disabled to require human confirmation. Support suggests lowering the proposal threshold to expose more candidates and reviewing the resulting matches. [Batch-tagging refinement](https://support.mylio.com/refining-batch-tagging-results)

No current reproducible accuracy benchmark on old family imagery, age gaps, relatives, twins, occlusion, low-resolution transfers, or Rick's Donna holdouts was found. It would be wrong to rank Mylio against VideoScan's engines from the word “advanced” or from descriptor dimensions.

## 12. SmartTags, OCR, and search

SmartTags automatically classify objects and visual properties such as exposure, focus, color, animals, buildings, and vehicles. They are generated by computer vision. [SmartTags](https://support.mylio.com/what-are-smarttags)

Users can promote a machine tag into a keyword, remove an incorrect SmartTag, and regenerate tags. **Design implication:** this provides a useful distinction between machine suggestions and deliberate catalog annotations. [Promoting and correcting tags](https://support.mylio.com/promote-smarttags-to-keywords-mylio-photos-help-center)

Search covers people, keywords, ratings, map locations, recent imports, pinned queries, and QuickFilters. Historical releases describe QuickCollections as saved combinations of metadata and recognition criteria that update as the library changes. [Search](https://support.mylio.com/how-can-i-search-for-photos-videos-and-documents-in-mylio-photos), [QuickCollections history](https://support.mylio.com/version-22-release-notes)

OCR makes visible text searchable; the engineering article documents an `ocr:` search prefix. [OCR control and query syntax](https://news.mylio.com/customize-face-recognition-mylio/)

No public implementation detail located establishes CLIP embeddings, an LLM, a vector database, conversational reasoning, speech transcription, speaker identification, or semantic video segmentation. Dynamic Search should not automatically be equated with Hallie's typed queries and grounded answers. Language-based retrieval over labels and metadata can produce useful search without any of those mechanisms.

## 13. Organization and family-history features

The documented UI includes All Photos, folders, albums, People, LifeCalendar, Map, ratings, labels, flags, categories, and metadata editing. Folders organize files; albums provide collections. [Product overview](https://support.mylio.com/what-is-mylio-photos), [Metadata tools](https://support.mylio.com/organizing-with-metadata)

Fuzzy dates support ranges and partial/uncertain time descriptions, including month/year, season/year, and undated material. This is especially relevant for scanned prints whose scan timestamp is unrelated to when the scene occurred. The support page's formatting merges “YearDecade”; the exact UI distinction should be checked directly. [Fuzzy dates](https://support.mylio.com/add-a-nonspecific-or-fuzzy-date)

Family History fields cover date shown, title, description, people, location shown, address components, GPS, and event name. Historical place lookup can use FamilySearch with location and date. Its event-name metadata field is separate from a LifeCalendar Event. [Family History metadata](https://support.mylio.com/adding-family-history-metadata)

Person profiles can hold relationships, notes, contacts, birthdays/anniversaries, and additional name forms. Mylio also publishes photos as FamilySearch Memories. These are useful genealogy-adjacent capabilities; the reviewed material does not establish a GEDCOM graph, kinship-path computation, source-evidence management, or family-tree reasoning equivalent to VideoScan's. [Person profiles](https://support.mylio.com/adding-relationship-and-contact-information-for-people), [FamilySearch publishing](https://support.mylio.com/post-memories-to-familysearch)

Spaces provide scoped views and controls, including passcodes, device assignment, and restrictions on modification/sharing. The documentation establishes application permissions, not independently encrypted per-person storage or OS-level access isolation. [Spaces](https://support.mylio.com/using-workflows-categories-spaces), [Space permissions](https://support.mylio.com/restrict-ability-to-add-modify-delete-edit-or-share-in-a-specific-space-mylio-photos-help-center)

Workflows simplify the interface by hiding tools for particular tasks: Basic, Organizing, Photo Sharing, File Management, or Device Setup. They are UI presets, not evidence of a programmable workflow engine. [Workflows](https://support.mylio.com/using-workflows-in-mylio-photos-mylio-photos-help-center)

## 14. Duplicate management

Photo DeDupe scans the library for repeated media, presents candidates, and offers reviewed move/delete actions. Auto-Check can propose files to retain and remove. The published procedure does not disclose its identity algorithm or prove whole-file byte equality. [Photo DeDupe](https://support.mylio.com/find-duplicate-photos-photo-dedupe)

Photo DeClutter handles similar photographs, particularly bursts, with review before moving/deleting selections. Similarity is a different relationship from byte identity. [Photo DeClutter](https://support.mylio.com/find-similar-photos-photo-declutter)

Questions for archival use: Are metadata-only variants duplicates? Does matching use original bytes, decoded pixels, previews, or partial hashes? Are RAW+JPEG pairs protected? Can distinct audio tracks on visually identical videos be differentiated? How are annotations merged? Does a keeper exist and verify before deleting other copies? None of these should be inferred from the name DeDupe.

## 15. Editing, metadata portability, and export

Mylio provides tone, white balance, color, detail controls, automatic enhancement, and connections to external editors such as Photoshop and Affinity Photo. This is a photo-editing workflow; no comparable nonlinear video-editing toolset was established. [Editing tools](https://support.mylio.com/can-i-edit-photos-in-mylio-photos)

Metadata changes and editing instructions are stored in XMP sidecars and the catalog, preserving original images in the usual nondestructive workflow. An explicit Save Metadata to File option can write metadata back into supported non-RAW originals. “Nondestructive” therefore describes the normal editing model, not a blanket promise that no operation ever changes a source file. [XMP behavior](https://support.mylio.com/what-are-xmp-files), [Metadata storage](https://support.mylio.com/how-does-mylio-photos-handle-metadata-mylio-photos-help-center)

XMP is a useful interchange container, but not all XMP namespaces or edit recipes are universally understood. Image-edit rendering, face-region coordinates, uncertainty dates, person relationships, album membership, and automatic tags require field-by-field round-trip testing. The documented unlink/relink loss of some organization demonstrates that sidecars are not the entire application state.

Custom export presets are supported. Sharing options include folder export, clipboard/mobile sharing, watermarks, printing, Flickr, Frame.io, and FamilySearch entry points. Exact format/bit-depth/color-profile combinations were not verified from the blocked manual. [Export presets](https://support.mylio.com/creating-a-custom-export-preset), [Export/share tools](https://support.mylio.com/sharing-exporting)

SafeShare can remove personal information before publication. Shareable Links publish selected photographs to non-indexed web galleries. Non-indexing is not an authentication guarantee; publishing a gallery is a different data path from keeping media solely on local devices. [SafeShare](https://support.mylio.com/what-is-the-safeshare-feature-in-mylio-photos), [Shareable Links](https://support.mylio.com/create-a-shareable-link)

No supported public REST/GraphQL API, CLI, SDK, webhook contract, database schema, or general plugin-development interface was established in this survey. Practical interoperability currently rests on files, sidecars, export, and documented integrations. This is an evidence limit, not a claim that no private/internal API exists.

## 16. Security, privacy, and vendor dependence

Mylio documents local analysis and optional cloud storage, with AES-256 encryption available for cloud copies. That is useful evidence of product intent, but the reviewed pages do not supply cipher mode, authenticated-encryption construction, key derivation, key escrow/recovery, key rotation, relay trust, or an independent cryptographic audit. [Privacy and encryption description](https://mylio.com/details/)

The accessible privacy policy is dated **May 14, 2018**. It covers account/billing information, usage/analytics, support diagnostics, and metadata associated with content uploaded/shared through its services. That is not evidence that Mylio routinely uploads an entire locally stored photo library. It does mean “local processing” should not be interpreted as “no account or service telemetry.” A current policy clarification would be appropriate before a privacy-sensitive deployment. [Published privacy policy](https://mylio.com/privacy/)

Cancellation leaves locally stored originals accessible through the OS and permits continued free browsing, while sync/protection cease without a subscription. Sidecars remain alongside media. [Cancellation behavior](https://support.mylio.com/what-happens-to-my-files-if-i-decide-to-cancel-my-mylio-photos-subscription)

**Assessment:** original-file ownership is relatively portable; catalog semantics, collaboration, cloud decryption/recovery workflows, and device synchronization still depend on the application. No complete vendor-disappearance or indefinitely air-gapped licensing contract was found. Test recoverability using plain files and exported metadata, not just an authenticated running client.

## 17. Pricing snapshot

Advertised US-dollar prices retrieved October 16, 2026; promotions, tax, and checkout terms may differ.

| Personal plan | Users | Monthly billing | Annual billing |
|---|---:|---:|---:|
| Individual | 1 | $25/month | $240/year |
| Duo | 2 | $40/month total | $384/year total |
| Family | 5 | $50/month total | $480/year total |

[Personal pricing](https://mylio.com/signup-personal/)

Business Pro starts at $40/month or $480/year for one user. The support overview advertises a seven-day trial and 30-day satisfaction guarantee. [Plan overview](https://support.mylio.com/how-much-does-mylio-photos-cost)

SecureCloud is additional: the retrieved page advertises 2 TB at $11.98/month and 5 TB at $29.95/month, with Photos+ required. Original storage is not included merely because optimized-image cloud storage is included. [SecureCloud pricing](https://mylio.com/secure-cloud/)

Old pages still advertise $9.99/month and older OS requirements. Those were not used as the current purchasing baseline. The two-year pricing page also contains flattened promotional/strikethrough values that are ambiguous in text extraction, so no two-year quote is asserted here.

## 18. Comparison with current VideoScan

The VideoScan column below is **source-present**, not a fresh runtime test. Mylio evidence is in the preceding sections; “not established” means no sufficiently documented counterpart was found.

| Capability | Mylio Photos | VideoScan current source |
|---|---|---|
| Primary library | Photographs, supported videos and documents | Video/audio catalog; photos serve reference/family-asset roles |
| Native clients | Mac, Windows, iOS/iPadOS, Android | macOS app and supporting CLI/web components |
| Core catalog | Mylio catalog plus sidecars; engine unknown | Versioned JSON, atomic snapshots, recovery generation |
| Device distribution | Peer library sync with placement policies | One-way master-to-read-only-Mac-viewer synchronization |
| Photo RAW editing | Documented | No equivalent general RAW-photo editor established |
| Still-photo recognition | Descriptor/clustering workflow | Reference photos support multiple face engines and person profiles |
| Automatic person discovery in movies | Explicitly unavailable in documented production video workflow | Sampled-frame jobs, temporal results, per-job person selection |
| Legacy container inspection | Complete matrix unverified | ffprobe/media parsers and broad video/audio admission |
| Avid/MXF reconstruction | No documented counterpart found | MXF/AVB parsing, correlation, substitution, combining |
| Speech and visual dossiers | No comparable workflow established | Caption orchestration and persistent Whisper transcription |
| Duplicate review | DeDupe and DeClutter | Dedicated signatures, footage grouping, review/delete workflows |
| Archival fixity | Copy verification described; archival contract unspecified | Full-file SHA-256, destination readback, durable publishing |
| Provenance | Catalog organization and metadata | Append-only media ledger and archive index |
| Genealogy | Person relationships, historical metadata, FamilySearch publishing | GEDCOM family graph, kinship, research notes, family assets |
| Conversational access | No Hallie-equivalent established | Typed media/tree queries and grounded composition |
| Interchange | XMP and conventional media exports | JSON catalogs/bundles, JSONL ledger, GEDCOM inputs, lineage exports |
| Main product advantage | Everyday photo organization and distribution across devices | Specialized audiovisual recovery, analysis, and preservation |

### VideoScan source evidence and qualifications

- **Library boundary:** the query model explicitly distinguishes photo assets from the video/audio catalog. [ArchivistQueryAST.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Hallie/ArchivistQueryAST.swift:38). The admission lists include MXF, MKV, DV/DIF, MTS/M2TS, BRAW/R3D and opt-in audio types; admission does not guarantee decoder support. [VideoScanModel.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Model/VideoScanModel.swift:728)
- **Catalog:** JSON persistence, debounced background serialization, atomic replacement, recovery generation, and generation stamping. It would be incorrect to call the core catalog SQLite. [CatalogStore.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogStore.swift:1)
- **Sync:** rsync over SSH into staging, SHA-256 manifest verification, and installation on read-only viewers. The design explicitly excludes bidirectional writeback and conflict resolution. [CatalogSync.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogSync.swift:10)
- **Recovery:** optional extensionless probing and unknown-extension magic-byte gating support discovery beyond ordinary photo import. [ScanOptions.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Volumes/ScanOptions.swift:40)
- **MXF:** separate-stream combination supports stream copy as well as re-encoding modes, with verification before publication. [CombineEngine.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/MediaOps/CombineEngine.swift:4), [Combine pipeline](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/MediaOps/VideoScanModel+Combine.swift:275)
- **Recognition:** current registered engines are Vision, ArcFace, AdaFace, and Hybrid Vision/AdaFace fallback. The old dlib-centric summary is stale. ArcFace and AdaFace reference embeddings are distinct. [PersonFinderTypes.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/People/PersonFinderTypes.swift:80), [Engine dispatch](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/People/PersonFinderEngineDispatch.swift:5)
- **Video clips:** sampled person searches and compilation exist, but the inspected clip extraction uses AVFoundation HighestQuality export. Do not generalize MXF stream-copy behavior to every clip operation. [PersonFinderModel.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/People/PersonFinderModel.swift:1), [PersonFinderCompilation.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/People/PersonFinderCompilation.swift:31)
- **Analysis:** timestamped visual-caption steps and persistent Python Whisper worker transport are implemented. [Dossier steps](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Media/CaptionOrchestrator+DossierSteps.swift:30), [WhisperWorkerTranscriber.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Media/WhisperWorkerTranscriber.swift:5)
- **Fixity:** archive promotion hashes the source while copying, independently rereads the destination, checks digests, and uses durable publication safeguards. Segmented candidate signatures are separate from full-file fixity. [ArchiveFixity.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift:2), [ArchivePromoteEngine.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Archive/ArchivePromoteEngine.swift:452)
- **Provenance:** append-only JSONL ledger and archive mirror are present. Backup-attestation types exist, but the inspected implementation notes an unwired UI call surface; they are not presented here as a completed end-user workflow. [MediaLedger.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Archive/MediaLedger.swift:6), [Backup attestations](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Archive/VideoScanModel+BackupAttestations.swift:12)
- **Genealogy:** a live GEDCOM graph and family notes exist. FamilySearch retrieval is a terminal handoff to `getmyancestors`, not a polished first-party OAuth synchronization service. [FamilyTreeLiveModel.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:2), [FamilySearchPull.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/FamilySearchPull.swift:1)
- **Hallie:** typed queries and grounded composition exist; configurable model endpoints include remote/cloud URLs. VideoScan is local-capable, not guaranteed local-only under every configuration. [HallieGroundedComposer.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Hallie/LLM/HallieGroundedComposer.swift:1), [OllamaEndpoints.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Hallie/LLM/OllamaEndpoints.swift:50)
- **Exports:** JSON catalogs and `.videoscanbundle` transfer are implemented. General XMP/IPTC round-trip support was not established by this inspection. [Catalog import/export](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+CatalogImportExport.swift:39), [BundleExportImport.swift](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/App/BundleExportImport.swift:14)

## 19. Unanswered engineering questions for Mylio

These questions would materially affect integration or purchase; they are not allegations of defects.

1. **Catalog contract:** database engine, crash-consistency guarantees, backup frequency/retention, migration rollback, and supported recovery without account service access?
2. **Replication:** authoritative conflict rules for concurrent metadata edits, rename/delete races, disconnected devices, and replay after restoring an old catalog?
3. **File identity:** whole-file hashes, stable media IDs, sidecar association rules, RAW+JPEG/Live Photo handling, and behavior when files are renamed externally?
4. **Fixity:** algorithm, verification coverage, periodic scrubbing, corruption repair, and exportable digest manifests?
5. **Video matrix:** exact supported containers/codecs/stream configurations on each OS; maximum tested file size/duration; corrupt-file failure behavior?
6. **ML:** current models/runtime, embedding stability across upgrades, cluster migration, quality gates, acceleration, and published precision/recall evaluation?
7. **Metadata:** exact XMP namespaces for people, face rectangles, uncertain dates, events, categories, and relationships; bidirectional external-edit support?
8. **Automation:** supported CLI/API/plugin hooks, unattended ingestion, export manifests, or structured diagnostics?
9. **Security:** transport/encryption specifications, key recovery, account compromise handling, device revocation, and relay/service dependency?
10. **Scale:** catalog RAM/disk growth per item, first-import throughput, incremental rescan cost, search latency, and bounded recovery time at 100k/1M items?
11. **Permissions:** whether family Spaces constrain only UI operations or also prevent unauthorized local-file access; separate account and guest-device behavior?
12. **Exit:** what organization is lost when exporting to originals plus XMP, and how encrypted remote backups can be recovered without a functioning Mylio service?

## 20. Suggested evaluation against Rick's archive

This is a proposed test plan, not work performed. Use an isolated copied corpus, with original hashes and an independent backup. It should answer concrete workflow questions rather than produce a superficial feature score.

| Test | Input / operation | Evidence to collect |
|---|---|---|
| Import accounting | Mixed supported, unusual, corrupt, unreadable, and extensionless files | Imported/skipped counts and explicit reasons; unchanged source hashes |
| Media matrix | H.264 MP4; ProRes MOV; FFV1+PCM MKV; MXF OP-Atom pair; DV AVI; WAV/AIFF | Separate admission, metadata, thumbnail, playback, and export outcomes per OS |
| Photos | JPEG, HEIC, RAW+JPEG, scans, Live Photos, orientation/color-profile variants | Pairing, dates, rendering, and source preservation |
| Recognition | Labeled family-photo holdout with age gaps and similar relatives | Precision, recall, false identities, review time, and processing cost |
| Video search | A clip where Donna appears only midway through | Distinguish whole-file manual tagging from timestamped discovery |
| Interchange | Names, face regions, keywords, dates, location, captions | Inspect sidecars with ExifTool; import/export/reimport; field-loss report |
| Offline drive | Disconnect/reconnect a registered drive; then a linked NAS path | Catalog availability, missing-state semantics, and correct relinking |
| Concurrent editing | Two devices offline; conflicting annotations and renames | Deterministic resolution, retained information, visible conflicts |
| Deletion | In-app deletion versus OS deletion on disposable fixtures | Propagation to each Vault and genuine restore path |
| Capacity | Fill a test destination near its free-space threshold | Pause behavior, resumability, error clarity, effects on other devices |
| Scale | 10k then 100k representative items; larger only if justified | Peak RAM, catalog/cache size, indexing duration, warm/cold query latency |
| Exit/recovery | Restore from exported originals/sidecars and from a Vault copy | Byte equality plus recovery of people, albums, events, and annotations |

For recognition, separate training/reference images from holdouts. Measure time spent correcting false matches, not just how many faces the software proposes. For scale, capture hardware, build, media mix, network, cache state, and analysis settings so results can be reproduced. No UI tests or app launches were performed on the M4 for this report.

## 21. Implications for VideoScan

**Product assessment:** Mylio's strongest comparison value is its representation/storage model and the everyday experience of finding and sharing photographs across devices. VideoScan's strongest value is its detailed understanding of legacy audiovisual material, preservation evidence, and family context. Neither product should receive credit for the other's specialty merely because both say “media library.”

Design ideas worth studying:

- A single item inspector that answers where every original/preview copy lives and why it is retained.
- Rule-based device placement, with visible distinction between catalog visibility and local media availability.
- Explicit uncertain-date entry rather than forcing a fabricated precise timestamp.
- A clear transition from machine-suggested tags to human-confirmed archival facts.
- Simplified browsing/sharing workspaces for family members, with modification restrictions.
- Protection status tied to outstanding destinations, while keeping fixity and historical backup separate.

These are research observations, not authorization to change VideoScan's architecture. A peer-to-peer replication layer or general photo DAM would be a major scope expansion.

A plausible coexistence design is to use VideoScan for recovery, analysis, and preservation, then publish selected conventional media derivatives and intentional metadata to a separately managed family photo library. The unresolved integration problem is mapping VideoScan's person/time/provenance semantics into Mylio's whole-file metadata without losing meaning. Linking the writable master archive directly into another application's managed deletion domain would require deliberate policy and testing.

**Decision criterion:** evaluate Mylio on the photo-management and family-device access work it could remove from your workload. Retain separate acceptance criteria for audiovisual reconstruction, timestamped discovery, and independently verifiable archival preservation.
