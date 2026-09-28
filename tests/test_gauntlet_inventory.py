"""Sensor for the gauntlet's suite discovery (scripts/gauntlet/inventory.swift).

2026-09-28 baseline: 35 unit + 6 Hallie declarations never ran because their
suites were invisible to discovery — `@Suite struct X` on one line, a second
suite in the file, a suite name without "Tests". A selector is only as good
as this list.
"""
import json
import sys
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
INVENTORY = REPO / 'scripts/gauntlet/inventory.swift'

SOURCE = '''import Testing

struct FirstTests {
    @Test func a() {}
}

@Suite struct OneLineSuite {
    @Test func b() {}
}

@Suite(.serialized) struct SerializedPerfTests {
    struct Boom: Error {}
    @Test func c() {}
}

@Suite("Bench", .serialized)
struct Bench {
    @Test func d() {}
}

struct RegressionSensors {
    enum Fixture { static let x = 1 }
    @Test("a display name with struct Fake in it") func e() {}
}
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swift and Xcode; the Python CI runner is Linux")
class SuiteDiscoveryTests(unittest.TestCase):
    def test_every_suite_that_holds_a_test_is_discovered_and_helpers_are_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'VideoScan/VideoScanTests/SampleTests.swift'
            path.parent.mkdir(parents=True)
            path.write_text(SOURCE)
            out = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(pathlib.Path(tmp) / 'cache'),
                                  str(INVENTORY), '--discover', tmp],
                                 capture_output=True, text=True, check=True).stdout
        entry = next(e for e in json.loads(out) if e['path'].endswith('SampleTests.swift'))
        self.assertEqual(sorted(entry['tests']), ['a', 'b', 'c', 'd', 'e'])
        self.assertEqual(sorted(entry['suites']),
                         ['Bench', 'FirstTests', 'OneLineSuite', 'RegressionSensors', 'SerializedPerfTests'])


if __name__ == '__main__':
    unittest.main()
