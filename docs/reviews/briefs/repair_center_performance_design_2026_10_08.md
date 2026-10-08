# Design sounding board: VideoScan "Repair center" — fastest good-quality repair paths

Credits note: this is a DESIGN consult, not a code review. Answer in under ~1,500 words.
First line of your answer: `Credits spent: <amount> | Finding count: <N>` (N = number of
numbered recommendations). Include a line `Verdict: <go | rethink> — <one clause>`.

## Context (facts, verified 2026-10-08)
- macOS SwiftUI app cataloging ~8 TB of family home video (VHS/DV/Hi8 captures, Avid MXF
  halves, camcorder MP4/MOV/MTS, DNxHD, ProRes, FFV1). It shells out to Homebrew ffmpeg/ffprobe
  via a ProcessRunner (streams stdout/stderr, cancel, stall watchdog).
- ffmpeg 9.0.2, configured with videotoolbox, audiotoolbox, x264, x265, svtav1, libvmaf, neon.
  NOT built with libvidstab, libplacebo, or vulkan. Hardware: hwaccel videotoolbox; filters
  scale_vt, transpose_vt, yadif_videotoolbox (Metal); encoders h264/hevc/prores_videotoolbox.
  CPU filters available: mpdecimate, decimate, dejudder, bwdif, nlmeans, deshake, afftdn,
  arnndn, loudnorm, aresample, atempo.
- Machines: M4 Max (16 cores, 64 GB) today; M5 Ultra (96 GB, ~2× SSD) arriving. Media lives on
  RAID / HDD / SSD over Thunderbolt (TB5 measured 65 Gbit/s). One Verify full pass measured
  ~65 MB/s on a 41.5 GB DNxHD file (ffmpeg decode-bound).
- Hard rules: the original is NEVER modified/moved/deleted; output is one `<stem>_repaired.<ext>`
  written as a reserved `.partial` and published by an atomic no-clobber rename on the same
  volume; protected (archive) volumes are never written — a save panel picks another place.

## What is being built
One "Repair center": every A/V repair lives behind one Repair… door in the Catalog. Verify
diagnoses; Repair Now runs every applicable fix in order as ONE job producing ONE output.
Phase 2 (in progress, ships this weekend) has: lossless remux (fixes bad interleave, e.g. all
audio at the END of a 41 GB DNxHD MOV), rebuild sound (re-encode damaged audio to PCM),
balance sound (channel imbalance), remove repeated frames (a 36 s clip where each frame is
repeated ~2000× in a 43 GB file → mpdecimate + re-time). Later candidates: deinterlace,
denoise, stabilize, levels/colour-range fix (range flagged pc but data 11–241), A/V sync
offset, telecine removal, timecode/gap repair, MXF half mux (exists elsewhere as Combine).

## Questions (be concrete: ffmpeg flags, Apple APIs, numbers where you can)
1. For each fix above, what is the bottleneck (I/O, demux, decode, filter, encode) and the
   fastest path that keeps quality? Where does videotoolbox decode/encode, Metal (CoreImage /
   custom kernels / yadif_videotoolbox), the ANE (e.g. Core ML denoise/super-res), or plain
   multi-core CPU win — and where is hardware a trap (quality, 10-bit/4:2:2, interlace flags,
   colour tags, VT encoder rate control)?
2. Single-pass vs chained: when several fixes apply, one ffmpeg filtergraph vs separate passes?
   When must a lossless remux be kept as its own stream-copy pass?
3. Parallelism: segment-parallel encode (split at keyframes / GOPs, encode N segments, concat)
   vs one ffmpeg with threads; how many concurrent repairs on 16 vs 24+ P-cores; RAM-backed
   staging (64→96 GB) — worth it or not, given the publish must be a same-volume rename?
4. The repeated-frame case: fastest way to find the unique frames in a 43 GB file without
   decoding everything at full resolution (e.g. hash at reduced res, packet-size/hash
   heuristics, `-skip_frame`, analysing a low-res proxy first, then a cut list)?
5. Verifying the output fast enough (parity: duration, frame count, audio sample count,
   optional VMAF/SSIM spot checks) without a second full decode.
6. What ffmpeg build features (libplacebo, vidstab, vulkan via MoltenVK, etc.) or native
   frameworks (AVFoundation/VideoToolbox/Core Image directly from Swift) would you add, ranked
   by payoff for a family-archive repair tool? Which would you avoid?
7. Anything in this design you would change.

Do not read or explore the repository; answer from the facts above. Be direct; say when
something is not worth it.
