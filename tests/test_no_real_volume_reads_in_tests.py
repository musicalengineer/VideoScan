"""No automated test opens a file on a real archive volume.

2026-10-28 02:00 nightly on the M5 Ultra: both hangs were macOS privacy
prompts. A launchd job that touches /Volumes/FamilyArchive (the Pegasus)
makes sandboxd ask TCC, UserNotificationCenter shows "would like to access
files on a removable volume", and the test waits for a click that never comes
at 5 a.m. (05:03:58 Core GedcomCompiledTreeTests.testFullHashCostOnRealPulls;
05:54:05 the app's m3_clearMasterArchive…). Run from Terminal the same tests
pass, because Terminal already holds that permission.

Rule: a test source may build a URL on a real volume only through the
opt-in gate (Core: RealFamilyData.swift, VIDEOSCAN_REAL_DATA=1), or in a
file named below with the reason it is safe.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOTS = [REPO / "VideoScan" / "VideoScanCore" / "Tests", REPO / "VideoScan" / "VideoScanTests"]
REAL_VOLUMES = ("FamilyArchive", "Projects", "LaCieWorkspace", "MediaExpansion",
                "SanDiskWorkspace", "CrucialX9", "CrucialX10")
URL_ON_REAL_VOLUME = re.compile(
    r'URL\(\s*fileURLWithPath:\s*"/Volumes/(%s)/' % "|".join(REAL_VOLUMES))

ALLOWED = {
    # The gate itself: the only place Core names a real file.
    "RealFamilyData.swift",
    # App: every read sits behind requireRealArtifactPerformanceLane()
    # (Release + VIDEOSCAN_GEDCOM_PERF=1 + coverage off), checked first.
    "GedcomScaleSensorTests.swift",
    # Path arithmetic only (CatalogSync.externalSources); nothing is opened.
    "RemoteViewerSyncScopeTests.swift",
    # Path arithmetic only (RelocateSheet.derivedDestination is lexical).
    "RelocateSheetBrowseTests.swift",
}


class NoRealVolumeReadsInTests(unittest.TestCase):
    def test_real_volume_urls_only_behind_the_opt_in(self):
        offenders = []
        for root in ROOTS:
            for f in sorted(root.rglob("*.swift")):
                if f.name in ALLOWED:
                    continue
                text = f.read_text(errors="ignore")
                for m in URL_ON_REAL_VOLUME.finditer(text):
                    line = text.count("\n", 0, m.start()) + 1
                    offenders.append("%s:%d" % (f.relative_to(REPO), line))
        self.assertEqual(offenders, [], "real-volume file URLs outside the opt-in gate:\n  " + "\n  ".join(offenders))

    def test_the_pattern_catches_the_2026_10_28_shape(self):
        sample = 'static let bigTree = URL(fileURLWithPath:\n        "/Volumes/FamilyArchive/Breen_Family_Archive/x.ged")'
        self.assertTrue(URL_ON_REAL_VOLUME.search(sample))
        self.assertFalse(URL_ON_REAL_VOLUME.search('URL(fileURLWithPath: "/Volumes/Tapes/1998/a.mkv")'))


if __name__ == "__main__":
    unittest.main()
