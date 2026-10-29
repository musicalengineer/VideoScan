"""scripts/disk_check.py: container selection and verdicts (no disks touched)."""

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import disk_check  # noqa: E402

APFS = {"Containers": [
    {"ContainerReference": "disk3", "PhysicalStores": [{"DeviceIdentifier": "disk0s2"}],
     "Volumes": [{"Name": "UltraDrive", "DeviceIdentifier": "disk3s1"}, {"Name": "Data", "DeviceIdentifier": "disk3s5"}]},
    {"ContainerReference": "disk13", "PhysicalStores": [{"DeviceIdentifier": "disk12s2"}],
     "Volumes": [{"Name": "FamilyArchive", "DeviceIdentifier": "disk13s1"}, {"Name": "Projects", "DeviceIdentifier": "disk13s2"}]},
    {"ContainerReference": "disk11", "PhysicalStores": [{"DeviceIdentifier": "disk10s2"}],
     "Volumes": [{"Name": "CrucialX10", "DeviceIdentifier": "disk11s1"}]},
    {"ContainerReference": "disk15", "PhysicalStores": [{"DeviceIdentifier": "disk14s1"}],
     "Volumes": [{"Name": "MetalToolchainCryptex", "DeviceIdentifier": "disk15s1"}]},
]}
INFO = {
    "disk0s2": {"Internal": True, "BusProtocol": "Apple Fabric"},
    "disk12s2": {"Internal": False, "BusProtocol": "SAS"},
    "disk10s2": {"Internal": False, "BusProtocol": "USB"},
    "disk14s1": {"Internal": False, "BusProtocol": "Disk Image"},
}


def containers():
    return disk_check.parse_containers(APFS, INFO)


def refs(cs):
    return [c.ref for c in cs]


class Selection(unittest.TestCase):
    def test_live_checks_internal_and_external_skips_disk_image(self):
        picked, skipped = disk_check.select(containers(), "live", None)
        self.assertEqual(refs(picked), ["disk3", "disk13", "disk11"])
        self.assertEqual(len(skipped), 1)
        self.assertIn("disk image", skipped[0])

    def test_offline_never_touches_the_internal_disk(self):
        picked, skipped = disk_check.select(containers(), "offline", None)
        self.assertEqual(refs(picked), ["disk13", "disk11"])
        self.assertTrue(any("internal" in s for s in skipped))

    def test_repair_matches_by_volume_name_or_ref(self):
        self.assertEqual(refs(disk_check.select(containers(), "repair", "FamilyArchive")[0]), ["disk13"])
        self.assertEqual(refs(disk_check.select(containers(), "repair", "Projects")[0]), ["disk13"])
        self.assertEqual(refs(disk_check.select(containers(), "repair", "disk11")[0]), ["disk11"])

    def test_repair_refuses_boot_disk_and_unknown_names(self):
        self.assertEqual(disk_check.select(containers(), "repair", "Data")[0], [])
        self.assertEqual(disk_check.select(containers(), "repair", "UltraDrive")[0], [])
        self.assertEqual(disk_check.select(containers(), "repair", "Nope")[0], [])

    def test_unknown_store_info_is_not_treated_as_internal_or_image(self):
        cs = disk_check.parse_containers(APFS, {})
        self.assertFalse(any(c.internal or c.disk_image for c in cs))


class Verdict(unittest.TestCase):
    def proc(self, code, out):
        return subprocess.CompletedProcess([], code, out, "")

    def test_ok_needs_exit_zero_and_ok_text(self):
        self.assertTrue(disk_check.verdict(self.proc(0, "The container /dev/rdisk11 appears to be OK\n")))

    def test_exit_zero_without_ok_text_is_a_failure(self):
        self.assertFalse(disk_check.verdict(self.proc(0, "Storage system check exit code is 0\n")))

    def test_nonzero_exit_is_a_failure_even_with_ok_text(self):
        self.assertFalse(disk_check.verdict(self.proc(1, "volume appears to be OK\ncontainer is corrupt\n")))


if __name__ == "__main__":
    unittest.main()
