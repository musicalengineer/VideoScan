Credits spent: unavailable (no billing telemetry) | Finding count: 8

Verdict: go — make Repair Now execute an explicit repair plan with operation-specific validation.

1. **Choose the cheapest path per stream.**

These are expected bottlenecks; measure representative clips before setting defaults.

| Fix | Bottleneck | Fast, quality-preserving path |
|---|---|---|
| Bad interleave/remux | I/O, demux seeks | Stream-copy everything compatible with the destination container. |
| Rebuild damaged audio | Audio decode; often video-copy I/O dominates | `-c:v copy -c:a pcm_s24le`; preserve sample rate/layout. PCM preserves decoded results; it cannot reconstruct missing sound. Record concealed/missing intervals. |
| Channel balance | Measurement; copying video | Measure channel levels, then fixed gains using `pan`, with clipping headroom. Stereo imbalance may be intentional. |
| Repeated frames | Usually decode | Packet-level investigation first; recommendation 5. |
| Deinterlace | Decode/filter/encode | CPU `bwdif=mode=send_field:parity=bff` for confirmed bottom-field-first material; use `tff` when appropriate. Preserve 59.94/50-field motion as 59.94/50p. Benchmark Metal `yadif_videotoolbox` against it. |
| Video denoise | Filter | CPU `nlmeans` is expensive. Use conservative, previewed settings; evaluate native temporal denoising later. |
| Audio denoise | Audio filter | `afftdn` for steady hiss; `arnndn` requires a suitable model and careful music testing. Keep video copied. |
| Stabilize | Motion analysis/filter/encode | Existing `deshake` for modest correction; vidstab for a more deliberate analysis/transform workflow. |
| Levels/range | Decode/encode if pixels change | Correct tags without recompression when only tags are wrong; otherwise explicitly transform pixels. |
| A/V offset | I/O if timestamps suffice | Separate input mappings with `-itsoffset` on the affected input; copy streams. Sample trimming/padding requires audio processing. |
| Telecine | Decode/filter/encode | Confirm cadence, then `fieldmatch,decimate` for standard hard 3:2 material. Do not apply it indiscriminately to camera interlace. |
| Timecode/gaps | Metadata/I/O or decode | Separate timecode labels from media timestamps. Filling missing pictures/sound is synthesis, not metadata repair. |
| MXF halves | I/O | Explicitly map video/audio from their respective inputs and `-c copy`, preserving intended alignment. |

Filter behavior and options: [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html).

**Range 11–241 does not prove incorrect tagging.** Limited-range captures can contain excursions; full-range footage need not reach 0/255. Require capture provenance and a visual check before stretching or clipping.

2. **Use hardware selectively; preserve the source’s representation.**

Try input `-hwaccel videotoolbox -hwaccel_output_format videotoolbox` for supported H.264, HEVC and ProRes profiles. DNxHD, DV and FFV1 remain CPU paths here. Confirm actual hardware use: FFmpeg’s ProRes/HEVC VT setup can permit software fallback. [Decoder implementation](https://ffmpeg.org/doxygen/9.0/videotoolbox_8c_source.html)

A VT-decode → Metal-deinterlace → VT-encode chain is attractive. CPU filters introduce transfers and format conversions; unified memory does not eliminate their cost.

For changed pictures, offer:

- **Lossless:** FFV1, e.g. `-c:v ffv1 -level 3 -slicecrc 1`, retaining pixel format.
- **Fast high-quality:** `prores_videotoolbox`, an appropriate profile, and verified bit depth/chroma preservation.
- **Compact derivative:** H.264/HEVC VT after representative quality checks.

ProRes is lossy. Main10 HEVC is 10-bit **4:2:0**; do not silently reduce 4:2:2 sources. FFmpeg exposes `main42210`, but actual support needs testing. VT `-q:v` is not x264 CRF; `-b:v` targets average bitrate, and CBR offers no archival advantage. [Encoder implementation](https://www.ffmpeg.org/doxygen/9.0/videotoolboxenc_8c_source.html)

Preserve matrix, transfer, primaries, range, aspect ratio and field order explicitly. Never interpret “encoder accepted it” as preservation.

3. **One job should allow analysis stages plus one final encode.**

Combine compatible picture operations into one graph and encode once. A reasonable dependency order is timestamp/cadence repair → inverse telecine **or** deinterlace → stabilization/denoise → colour transformation → encode. Stabilization may benefit from a separate lightly denoised analysis branch.

Rebuild/balance/denoise audio in one audio chain while copying unaffected video. Precise loudness normalization and stabilization can require analysis passes; those need not create intermediate video encodes.

**Bad interleave alone does not require a preliminary remux.** The final mux can interleave copied or encoded streams. Keep a separate stream-copy stage only when another component requires normalized input, or repeated access to pathological HDD layout makes an SSD intermediate measurably worthwhile.

For a compatible MOV remux, the core is:

```text
-i input.mov -map 0 -c copy -map_metadata 0 -map_chapters 0
-f mov destination.partial
```

Validate stream compatibility first. `+faststart` relocates the MOV index; it does not itself repair interleave and adds a relocation pass. Avoid it by default for local archives. [Muxer documentation](https://ffmpeg.org/ffmpeg-formats.html)

4. **Parallelize files before segments; skip RAM disks.**

The 16-core M4 Max has **12 performance plus four efficiency cores**. [Apple specifications](https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/)

Suggested starting policies, not measured limits:

| Resource | M4 Max | Machine with 24+ P-cores |
|---|---:|---:|
| CPU-heavy repairs, SSD-backed | 2 jobs | 3–4 jobs |
| VT-heavy repairs | Start at 2 | Benchmark 2, then 4 |
| Jobs sharing one HDD pool | 1 | 1 |

Benchmark aggregate throughput and responsiveness; decoder, encoder and filter thread pools need separate attention.

Segment encoding is poor first-weekend value. Keyframe boundaries alone do not resolve open-GOP dependencies, temporal-filter history, stabilization smoothing, cadence, AAC priming or rate-control discontinuities. Later, use closed boundaries, overlap/discard margins, identical encoding parameters and continuous audio.

RAM staging cannot accelerate the measured decode bottleneck: 41.5 GB at 65 MB/s is roughly **10.6 minutes**. Let macOS cache naturally. An SSD intermediate can help pathological seeks, but the final `.partial` still belongs on the destination volume.

5. **Treat the 2,000× duplication case as a forensic fast path.**

First inspect packet sizes, timestamps and hashes:

```text
ffprobe -select_streams v:0 -show_packets -show_data_hash sha256
-show_entries packet=pts,dts,duration,size,flags,data_hash -of compact INPUT
```

This reads payload bytes but avoids image decoding. Stream the results. [ffprobe documentation](https://ffmpeg.org/ffprobe.html)

For independently decodable, self-contained frames with unchanged codec configuration, identical packet hashes can establish repeated encoded pictures. A specialized packet selector could retain representatives and rewrite timestamps without re-encoding. **Ordinary `select`/`mpdecimate` filters cannot stream-copy their output.**

Packet size alone proves nothing. Interframe packets depend on decoder state; identical bytes need not mean identical pictures.

Downscaled hashes reduce comparison cost, usually **not decode cost**. Decoder `-lowres` helps only where supported. `-skip_frame nokey` loses unique pictures in long-GOP media and saves nothing on all-keyframe material. [Decoder options](https://ffmpeg.org/ffmpeg-codecs.html)

A proxy/cut list helps only if final extraction can seek efficiently to independent frames/GOPs.

Most importantly, distinguish storage duplication from legitimate still holds. Prefer a validated repeat cadence over generic similarity removal. `mpdecimate,setpts=N/(F*TB)` requires a justified output rate `F`; never infer it blindly from corrupted timestamps.

6. **Make fast verification explicitly partial.**

Collect actual emitted frame counts, timestamps and audio sample totals during processing using `-stats_enc_pre`, `-stats_enc_post` and `-stats_mux_pre`; audio statistics expose `{sn}` and `{samp}`. These avoid another decode but do not prove the written file is intact. [FFmpeg statistics](https://ffmpeg.org/ffmpeg.html)

After closing the output:

- Probe streams, tags, layout, dimensions, duration and index readability.
- Decode beginning/end, repair boundaries and several distributed windows.
- Compare against **planned** counts/duration: deinterlacing, cadence repair and gap insertion intentionally change them.
- For PCM, derive sample count from audio payload bytes and block alignment.

`-count_frames` generally requires decoding. Exact validation of lossy encoded output also requires decoding it.

Optional SSIM/VMAF windows should compare the encoded result against the intended filtered reference with aligned timing. Comparing denoised footage directly against noisy originals does not establish restoration quality. Report “structural checks + sampled decode,” reserving “full verification” for a complete pass.

7. **Rank additions by payoff.**

First: capability probes, representative benchmarks and preservation checks around existing FFmpeg paths.

Second: **libvidstab**, when stabilization demand warrants its two-stage workflow. [Project documentation](https://github.com/georgmartius/vid.stab)

Third: prototype Apple **`VTFrameProcessor` temporal noise filtering**. Query `isSupported`, dimensions and supported pixel formats; gate by OS availability. This is more promising than immediately maintaining a custom neural denoiser. [Apple API](https://developer.apple.com/documentation/videotoolbox/vttemporalnoisefilterconfiguration)

Fourth: Core Image/Metal for interactive previews or a demonstrated filter bottleneck. Avoid replacing the entire FFmpeg pipeline with AVFoundation.

Defer libplacebo/MoltenVK, custom ANE models and super-resolution. Their integration and validation costs exceed this weekend’s benefit. Core ML compute-unit settings permit ANE use; they do not promise ANE execution or acceleration. [Core ML](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine)

8. **Change “every applicable fix” to “every selected, justified fix.”**

Keep one Repair door and one published output. Show the planned operations, copied/re-encoded streams, expected timing changes and verification level before execution.

Automatic structural repairs make sense. Balance, denoise, stabilization, range interpretation and retiming need previewable decisions. Preserve your original-protection and atomic-publication rules; attach repair provenance to the catalog record.