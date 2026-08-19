 The app should and can assist the user in promoting the best quality files to the archive.

 For example, there are many copies of Clip 01.dv and it is not well-named and there are numerous different codecs, etc. the promote-helper is a right-click in catalog which helps the user archive the best quality version of that file. If the file needs to be transcoded, the app suggestions and even can do it for te user. the goal is for right-click->Promote Recommended Version...  Spawns a dialog which produces a window showing duplicates, codecs, and other info, then shows check marks for something like: master, backup, archive, edit. The app then recommends "Archive this file, it appears to be the original or master. I will transcode one (if one doesn't exist) to upgraded codec/wrapper, etc. Then we'll promote for you. The app lists the files that will be promoted to the archive. It generates/transcodes/verifies audio as needed. This could be a bit complicated but we think the following should help organize this feature. 

 The Goal of this feature is to assist the user in promoting the best files to the archive as well as helping the user see the versions for editing and storage can also be copied, then finally, after the promotion, the user may optionally select delete X copies after promotion to archive to cleanup other drives.


  ## Your Clip 01.dv

  The catalog shows this memory as:

  - 60:04 duration
  - DV, 720×480, 29.97 fps, about 28.8 Mb/s
  - PCM 16-bit stereo, 48 kHz
  - 12.96 GB

  Its copy family currently contains 12 live records:

  - 8 DV/PCM copies
  - 3 HEVC/AAC access copies
  - 1 ProRes/PCM editing derivative

  There is also a plausible 37.1 GB FFV1/FLAC version outside that group, but its provenance is missing. We cannot assume it came directly from the
  DV; it might even have been generated from an HEVC copy.

  The app currently elects this DV as Keep:

  /Volumes/Projects/_staging_from_MediaExpansion/.../CapeCod_2000-something.dv

  That file and your named Clip 01.dv share size, duration, codec metadata and segmented content signature. Pair Compare can prove whether they are
  byte-identical with its full SHA-256 pass.

  For this memory, the correct archival roles are:

   Representation                                       Proper role
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Native DV + PCM                                      Original source master—promote this first
  ───────────────────────────────────────────────────  ───────────────────────────────────────────
   FFV1 + lossless audio, generated directly from DV    Optional preservation companion
  ───────────────────────────────────────────────────  ───────────────────────────────────────────
   HEVC + AAC                                           Compact access/viewing copy
  ───────────────────────────────────────────────────  ───────────────────────────────────────────
   ProRes + PCM                                         Editing derivative

  Re-encoding DV into ProRes, HEVC or FFV1 cannot recover information already lost during the original DV recording. FFV1 can prevent another
  generation of loss and improve format resilience, but it supplements the original DV—it does not improve or replace it.

  ## What is wrong today

  Keep currently answers “which physical copy should survive duplicate cleanup?” It prioritizes volume reliability, human metadata and then a crude
  technical score. That technical score rewards file size and resolution, so an upscale or bloated transcode can win under some conditions. See
  VideoScan/VideoScan/DuplicateKeeperPolicy.swift:22 and VideoScan/VideoScan/DuplicateDetector.swift:559.

  There are other important gaps:

  - A HEVC file can be marked High / Extra copy because it matches another HEVC twin, while the displayed keeper is DV. It is not byte-identical to
    that DV.

  - Perceptual Compare proves matching pictures, not equivalent audio. Missing, clipped, shifted or replaced audio could go undetected. VideoScan/
    VideoScan/MediaPairComparator.swift:542

  - Archive Readiness currently mixes format accessibility with fidelity: HEVC is called archival-safe while DV is at-risk. That is reasonable
    longevity advice, but it must never imply HEVC is a better source master. VideoScan/VideoScan/ArchiveReadiness.swift:71

  - The current ProRes/HEVC transcoder always tags BT.709. That is questionable for SD DV, normally BT.601/SMPTE-170M, and can shift colors. Automatic
    SD derivative creation should wait until that is corrected. VideoScan/VideoScan/TranscodeJob+Args.swift:33

  - The group says 15 copies although only 12 live rows remain—stale bookkeeping worth fixing separately.

  ## Recommended MFO feature

  Add a Catalog/MFO verb:

  Assess Copies for Archive…

  Selecting any family member would produce one asynchronous MFO job:

  > 12 locations → 4 distinct representations

  The expanded result would separate:

  - Recommended original source
  - Byte-identical equivalents
  - Preservation derivatives
  - Editing/access derivatives
  - Unconfirmed or partial variants

  For this case, it should report something like:

  > Recommended original: native DV with PCM audio. Multiple equivalent DV locations found. HEVC copies are access derivatives; ProRes is an editing
  > derivative and contains no evidence of additional source detail.

  Actions:

  - Promote Recommended Original
  - Choose Another Equivalent Copy…
  - Create + Promote Lossless Companion
  - Promote Original + Companion
  - Create Access Copy

  Existing Promote should remain unchanged as the safe executor: copy bytes, SHA-256 verify the destination, publish and manifest. The new feature
  chooses what Promote should receive.

  The decision should be lexicographic, not an opaque “87/100 quality score”:

  1. Confirm the same complete recording, including audio.
  2. Prefer known original generation over derivatives.
  3. Reject damaged, truncated or incompletely decoded candidates.
  4. Preserve native geometry, cadence, interlacing, color and audio structure.
  5. Consider format sustainability.
  6. Use drive reliability and human metadata only to choose among byte-identical instances.

  Higher bitrate, resolution, bit depth or file size must never win alone.

  Performance-wise, it should collapse physical duplicates first and analyze one representative per encoding—not compare ten files pairwise. Cached
  fingerprints and health results belong in the re-derivable SQLite cache, keeping all media work off-main.

  ## What you can do now

  With today’s app:

  1. Select your Clip 01.dv and the elected Projects DV.
  2. Run Compare These Two Files….
  3. If it reports Exact duplicates, either is quality-equivalent; promote the mounted, reliable DV instance.
  4. Run Verify Audio before promotion.
  5. Optionally create a new verified FFV1 preservation derivative directly from that verified DV and promote it separately.
  6. Do not use HEVC as the sole master.

  That approach matches current archival guidance: NARA identifies the born-digital original as the preservation product, while the Library of
  Congress distinguishes original-resolution masters and FFV1/Matroska from viewing proxies. National Archives
  (https://www.archives.gov/preservation/products/reformatting/video), Library of Congress
  (https://www.loc.gov/preservation/resources/rfs/moving.html)

  No code was changed. I recommend this as the next archive feature, following the closed copy/duplicate work in GH #33. The later asset-role/manifest
  phase would require your approval because it adds catalog and manifest fields.
