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

    def test_unknown_store_info_is_never_unmounted_or_repaired(self):
        # Codex 2026-10-29 P1-1: missing `diskutil info` must not mean "external".
        cs = disk_check.parse_containers(APFS, {})
        self.assertEqual(disk_check.select(cs, "repair", "Data")[0], [])
        self.assertEqual(disk_check.select(cs, "offline", None)[0], [])
        self.assertEqual(refs(disk_check.select(cs, "live", None)[0]), ["disk3", "disk13", "disk11", "disk15"])

    def test_target_naming_a_protected_container_never_selects_another(self):
        # Codex 2026-10-29 P1-2: an external volume named "disk3" vs internal container disk3.
        apfs = {"Containers": APFS["Containers"] + [
            {"ContainerReference": "disk21", "PhysicalStores": [{"DeviceIdentifier": "disk20s2"}],
             "Volumes": [{"Name": "disk3", "DeviceIdentifier": "disk21s1"}]}]}
        cs = disk_check.parse_containers(apfs, {**INFO, "disk20s2": {"Internal": False, "BusProtocol": "USB"}})
        picked, skipped = disk_check.select(cs, "repair", "disk3")
        self.assertEqual(picked, [])
        self.assertTrue(any("ambiguous" in s for s in skipped))

    def test_duplicate_volume_names_across_containers_select_nothing(self):
        apfs = {"Containers": APFS["Containers"] + [
            {"ContainerReference": "disk21", "PhysicalStores": [{"DeviceIdentifier": "disk20s2"}],
             "Volumes": [{"Name": "FamilyArchive", "DeviceIdentifier": "disk21s1"}]}]}
        cs = disk_check.parse_containers(apfs, {**INFO, "disk20s2": {"Internal": False, "BusProtocol": "USB"}})
        self.assertEqual(disk_check.select(cs, "repair", "FamilyArchive")[0], [])


class Verdict(unittest.TestCase):
    def proc(self, code, out):
        return subprocess.CompletedProcess([], code, out, "")

    def test_ok_needs_exit_zero_and_ok_text(self):
        self.assertTrue(disk_check.verdict(self.proc(0, "The container /dev/rdisk11 appears to be OK\n")))

    def test_exit_zero_without_ok_text_is_a_failure(self):
        self.assertFalse(disk_check.verdict(self.proc(0, "Storage system check exit code is 0\n")))

    def test_nonzero_exit_is_a_failure_even_with_ok_text(self):
        self.assertFalse(disk_check.verdict(self.proc(1, "volume appears to be OK\ncontainer is corrupt\n")))


OK_OUT = "The container /dev/rdisk13 appears to be OK\n"
BAD_OUT = "error: btn: invalid key\nThe container /dev/rdisk13 could not be verified completely\n"


class FakeDiskutil:
    """Scripted `diskutil` answers by verb; records every call in order."""

    def __init__(self, **codes):
        self.codes = codes          # verb -> (returncode, stdout)
        self.calls = []

    def __call__(self, cmd):
        verb = cmd[1]
        self.calls.append(verb)
        answer = self.codes.get(verb, (0, OK_OUT if verb.endswith("Volume") else ""))
        if isinstance(answer, BaseException):
            raise answer
        code, out = answer
        return subprocess.CompletedProcess(cmd, code, out, "")


class Outcomes(unittest.TestCase):
    def setUp(self):
        self.real_run, self.real_log = disk_check.run, disk_check.log
        disk_check.log = lambda line: None
        self.archive = containers()[1]

    def tearDown(self):
        disk_check.run, disk_check.log = self.real_run, self.real_log

    def check(self, mode, **codes):
        fake = FakeDiskutil(**codes)
        disk_check.run = fake
        outcome, _ = disk_check.check_one(self.archive, mode)
        return outcome, fake.calls

    def test_live_ok_and_problems_never_unmount(self):
        self.assertEqual(self.check("live"), ("ok", ["verifyVolume"]))
        self.assertEqual(self.check("live", verifyVolume=(1, BAD_OUT)), ("problemsFound", ["verifyVolume"]))

    def test_partial_unmount_failure_still_remounts_and_is_not_checked(self):
        outcome, calls = self.check("offline", unmountDisk=(1, "at least one volume could not be unmounted"))
        self.assertEqual(outcome, "notChecked")
        self.assertEqual(calls, ["unmountDisk", "mountDisk"])

    def test_remount_failure_after_clean_verify_is_never_ok(self):
        outcome, calls = self.check("offline", mountDisk=(1, "mount failed"))
        self.assertEqual(outcome, "leftUnmounted")
        self.assertEqual(calls, ["unmountDisk", "verifyVolume", "mountDisk"])

    def test_remount_failure_after_unmount_failure_is_left_unmounted(self):
        outcome, _ = self.check("offline", unmountDisk=(1, "busy"), mountDisk=(1, "mount failed"))
        self.assertEqual(outcome, "leftUnmounted")

    def test_repair_on_a_clean_disk_writes_nothing(self):
        outcome, calls = self.check("repair")
        self.assertEqual(outcome, "ok")
        self.assertNotIn("repairVolume", calls)
        self.assertEqual(calls, ["unmountDisk", "verifyVolume", "mountDisk"])

    def test_repair_runs_only_after_a_failed_verify(self):
        outcome, calls = self.check("repair", verifyVolume=(1, BAD_OUT))
        self.assertEqual(outcome, "repaired")
        self.assertEqual(calls, ["unmountDisk", "verifyVolume", "repairVolume", "mountDisk"])

    def test_repair_that_fails_is_problems_found_not_repaired(self):
        outcome, _ = self.check("repair", verifyVolume=(1, BAD_OUT), repairVolume=(1, BAD_OUT))
        self.assertEqual(outcome, "problemsFound")

    def test_exception_during_verify_still_remounts(self):
        # Codex 2026-10-29 P1-3.
        outcome, calls = self.check("offline", verifyVolume=OSError("diskutil vanished"))
        self.assertEqual(outcome, "notChecked")
        self.assertEqual(calls, ["unmountDisk", "verifyVolume", "mountDisk"])

    def test_ctrl_c_during_repair_still_remounts_then_propagates(self):
        fake = FakeDiskutil(verifyVolume=(1, BAD_OUT), repairVolume=KeyboardInterrupt())
        disk_check.run = fake
        with self.assertRaises(KeyboardInterrupt):
            disk_check.check_one(self.archive, "repair")
        self.assertEqual(fake.calls[-1], "mountDisk")

    def test_exception_from_remount_is_left_unmounted(self):
        outcome, _ = self.check("offline", mountDisk=OSError("boom"))
        self.assertEqual(outcome, "leftUnmounted")

    def test_busy_disk_is_never_repaired(self):
        outcome, calls = self.check("repair", unmountDisk=(1, "busy"))
        self.assertEqual(outcome, "notChecked")
        self.assertNotIn("repairVolume", calls)


class MainGuards(unittest.TestCase):
    """Codex closing pass 2026-10-29: fail closed around main()."""

    def setUp(self):
        self.saved = {n: getattr(disk_check, n) for n in ("run", "log", "notify", "discover", "check_one")}
        disk_check.log = lambda line: None
        self.notes, self.checked = [], []
        disk_check.notify = self.notes.append
        disk_check.check_one = lambda c, mode: (self.checked.append(c.ref), ("ok", ""))[1]
        disk_check.discover = containers

    def tearDown(self):
        for n, f in self.saved.items():
            setattr(disk_check, n, f)

    def test_pgrep_error_refuses_offline(self):
        disk_check.run = lambda cmd: subprocess.CompletedProcess(cmd, 2, "", "pgrep: bad")
        self.assertNotEqual(disk_check.main(["--offline", "--quiet"]), 0)
        self.assertEqual(self.checked, [])

    def test_pgrep_not_found_allows_offline(self):
        disk_check.run = lambda cmd: subprocess.CompletedProcess(cmd, 1, "", "")
        self.assertEqual(disk_check.main(["--offline", "--quiet"]), 0)
        self.assertEqual(self.checked, ["disk13", "disk11"])

    def test_zero_containers_checked_is_a_failure(self):
        disk_check.discover = lambda: []
        self.assertEqual(disk_check.main(["--quiet"]), 1)
        self.assertEqual(len(self.notes), 1)


class Notify(unittest.TestCase):
    def test_message_is_passed_as_an_argument_never_spliced_into_applescript(self):
        saved, calls = disk_check.run, []
        disk_check.run = lambda cmd: calls.append(cmd) or subprocess.CompletedProcess(cmd, 0, "", "")
        try:
            disk_check.notify('disk13 (Rick "Archive"): problemsFound')
        finally:
            disk_check.run = saved
        cmd = calls[0]
        self.assertEqual(cmd[-1], 'disk13 (Rick "Archive"): problemsFound')
        self.assertFalse(any("Archive" in part for part in cmd[:-1]))


if __name__ == "__main__":
    unittest.main()
