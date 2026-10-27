"""Shell scripts must not write `$name` directly before a non-ASCII character.

Regression (2026-10-27, first install on the M5 Ultra): macOS ships bash 3.2 as
/bin/bash, and in a UTF-8 locale it takes the bytes of `…` as part of the
variable name. `note "installing $label into $name…"` under `set -u` died with
"name?: unbound variable" and stopped install_dev_tools.sh before any venv
package was installed. It never showed on the M4 because its venvs already
existed, so pip_into never ran. Write `${name}…` instead.

RED before the fix (40_python.sh:37, 50_models.sh:47); GREEN after.
"""
import os
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOTS = [REPO / "scripts", REPO / "install_videoscan_dev_dependencies"]
# An unbraced $NAME immediately followed by a byte outside ASCII.
UNBRACED = re.compile(rb"\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]")


class UnbracedBeforeNonASCII(unittest.TestCase):
    def test_bash32_really_fails_on_the_pattern(self):
        # Pins the cause, so the scan below is not cargo cult. Skips where
        # bash is not the macOS 3.2 build that has the bug.
        if not Path("/bin/bash").exists():
            self.skipTest("no /bin/bash")
        version = subprocess.run(["/bin/bash", "-c", "echo $BASH_VERSION"],
                                 capture_output=True, text=True).stdout
        if not version.startswith("3."):
            self.skipTest(f"/bin/bash is {version.strip()}, not 3.x")
        env = dict(os.environ, LC_ALL="en_US.UTF-8")
        bad = subprocess.run(["/bin/bash", "-c", 'set -u; name=x; echo "$name…"'],
                             capture_output=True, text=True, errors="replace", env=env)
        good = subprocess.run(["/bin/bash", "-c", 'set -u; name=x; echo "${name}…"'],
                              capture_output=True, text=True, errors="replace", env=env)
        self.assertNotEqual(bad.returncode, 0, bad.stdout)
        self.assertIn("unbound variable", bad.stderr)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout, "x…\n")

    def test_no_shell_script_writes_an_unbraced_variable_before_non_ascii(self):
        hits = []
        for root in ROOTS:
            for path in sorted(root.rglob("*.sh")):
                for n, line in enumerate(path.read_bytes().splitlines(), 1):
                    if line.lstrip().startswith(b"#"):
                        continue
                    if UNBRACED.search(line):
                        hits.append(f"{path.relative_to(REPO)}:{n}: {line.decode('utf-8', 'replace').strip()}")
        self.assertEqual(hits, [], "write ${name}… not $name… (bash 3.2 reads the bytes as the name):\n"
                         + "\n".join(hits))


if __name__ == "__main__":
    unittest.main()
