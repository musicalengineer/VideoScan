# External Media Fixtures

This directory is for local-only media files that should not be committed to
git. Use it for large files, old formats, damaged media, or real-world cases
that have caused VideoScan regressions.

Suggested layout:

```text
VideoScan/VideoScanTests/Fixtures/External/
  manifest.json
  avchd/
    kitty.MTS
  mxf/
  legacy_mov/
  phone_hevc/
  damaged/
```

`manifest.json` is intentionally ignored by git. Start from
`manifest.example.json`, then edit the relative paths and expectations for
your local files.

Run the external fixture tests with:

```bash
VideoScan/scripts/run_external_media_regressions.sh
```

or point at another local corpus:

```bash
VideoScan/scripts/run_external_media_regressions.sh --media-root /path/to/VideoScanTestMedia
```

The tests assert semantic media contracts such as stream type, codecs,
resolution, duration range, and playable classification. They are not just
"does ffprobe return something" checks.
