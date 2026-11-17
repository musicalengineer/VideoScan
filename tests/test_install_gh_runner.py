"""scripts/install_gh_runner.sh, scripts/gh_runner_release.py, scripts/testbed_wait.sh —
the GitHub Actions self-hosted runner on the M4 (Rick, 2026-11-17: "set up the self-hosted
runner on the m4").

Pinned without a host: argument parsing, what --dry-run says it will do for each host (ssh
for the M4, none locally; the token never printed), the LaunchAgent (GUI session, kept
alive, Homebrew on PATH), the host side's refusal to register twice, the release resolver
on the three places GitHub prints a checksum, and the wait for an idle testbed (held lock,
the 14:00 window, the budget). Nothing here runs ssh, curl, config.sh or launchctl.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'scripts/install_gh_runner.sh'
WAIT = REPO / 'scripts/testbed_wait.sh'
RESOLVER = REPO / 'scripts/gh_runner_release.py'
LOCK_HELPER = REPO / 'scripts/testbed_lock.py'
sys.path.insert(0, str(RESOLVER.parent))
import gh_runner_release as rel  # noqa: E402

TGZ = 'actions-runner-osx-arm64-2.338.2.tar.gz'
URL = 'https://github.com/actions/runner/releases/download/v2.338.2/' + TGZ
SHA = '25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388'


def release(body, tag='v2.338.2', assets=(TGZ,)):
    return {'tag_name': tag, 'body': body,
            'assets': [{'name': a, 'browser_download_url': URL.replace(TGZ, a)} for a in assets]}


def run(*args, env=None, stdin=None):
    return subprocess.run(['/bin/bash', str(SCRIPT), *args], capture_output=True, text=True,
                          env=env, input=stdin, timeout=60)


class ReleaseResolverTests(unittest.TestCase):

    def test_marker_comment(self):
        body = 'notes\n<!-- BEGIN SHA osx-arm64 -->%s<!-- END SHA osx-arm64 -->\n' % SHA.upper()
        self.assertEqual(rel.resolve(release(body)), ('2.338.2', URL, SHA))

    def test_shasum_line(self):
        body = 'echo "%s  %s" | shasum -a 256 -c\n' % (SHA, TGZ)
        self.assertEqual(rel.resolve(release(body))[2], SHA)

    def test_checksum_list(self):
        body = '## SHA-256 Checksums\n\n* actions-runner-osx-x64-2.338.2.tar.gz %s\n* %s %s\n' % ('a' * 64, TGZ, SHA)
        self.assertEqual(rel.resolve(release(body))[2], SHA)

    def test_no_digest_is_a_dash_not_a_guess(self):
        body = '* actions-runner-osx-x64-2.338.2.tar.gz %s\n' % ('b' * 64)
        self.assertEqual(rel.resolve(release(body))[2], '-')

    def test_missing_asset_and_bad_tag_are_errors(self):
        with self.assertRaises(ValueError):
            rel.resolve(release('', assets=('actions-runner-osx-x64-2.338.2.tar.gz',)))
        with self.assertRaises(ValueError):
            rel.resolve(release('', tag='nightly'))
        with self.assertRaises(ValueError):
            rel.resolve([])

    def test_cli_prints_one_line_and_fails_loudly(self):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d, 'r.json')
            f.write_text(json.dumps(release('* %s %s\n' % (TGZ, SHA))))
            p = subprocess.run([sys.executable, '-I', str(RESOLVER), str(f)], capture_output=True, text=True)
            self.assertEqual((p.returncode, p.stdout.strip()), (0, '2.338.2 %s %s' % (URL, SHA)))
            bad = subprocess.run([sys.executable, '-I', str(RESOLVER), '-'], input='{"tag_name":"v9"}',
                                 capture_output=True, text=True)
            self.assertEqual(bad.returncode, 1)
            self.assertIn('gh_runner_release:', bad.stderr)

    def test_no_apostrophes_the_installer_ships_it_in_a_heredoc(self):
        self.assertNotIn("'", RESOLVER.read_text(encoding='utf-8'))


class ArgumentTests(unittest.TestCase):

    def test_usage_and_unknowns_exit_2(self):
        self.assertEqual(run().returncode, 2)
        self.assertEqual(run('frobnicate').returncode, 2)
        self.assertEqual(run('install', '--host', 'ultra').returncode, 2)
        self.assertEqual(run('install', '--dry-run', '--version', 'two').returncode, 2)
        self.assertEqual(run('install', '--dry-run', '--labels', 'a b').returncode, 2)
        self.assertEqual(run('install', '--dry-run', '--sha256', 'abc').returncode, 2)
        self.assertEqual(run('install', '--dry-run', 'extra').returncode, 2)


class DryRunTests(unittest.TestCase):

    def test_m4_install_plan(self):
        p = run('install', '--dry-run', '--token', 'ghs_SECRET_TOKEN_VALUE')
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout
        self.assertIn("runner 'RicksM4' (labels m4,videoscan, release latest) on M4", out)
        self.assertIn('ssh ricksm4.local bash -s', out)
        self.assertIn('install_gh_runner.sh -> ricksm4.local:', out)
        self.assertIn('gh_runner_release.py -> ricksm4.local:', out)
        self.assertIn("__host install --host 'm4' --name 'RicksM4' --labels 'm4,videoscan' --version 'latest'", out)
        self.assertNotIn('ghs_SECRET_TOKEN_VALUE', out, 'the token is never printed')
        self.assertIn("GH_RUNNER_TOKEN='<redacted>'", out)
        self.assertNotIn('gh api', out, 'a given --token is not minted again')

    def test_token_is_minted_on_the_caller_when_not_given(self):
        out = run('install', '--dry-run').stdout
        self.assertIn('gh api -X POST repos/musicalengineer/VideoScan/actions/runners/registration-token', out)
        self.assertIn('(on this machine)', out)

    def test_local_install_has_no_ssh_and_takes_overrides(self):
        p = run('install', '--dry-run', '--host', 'local', '--labels', 'lab,x', '--name', 'Box',
                '--version', '2.338.2', '--sha256', SHA)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('ssh ', p.stdout)
        self.assertIn("--name 'Box' --labels 'lab,x' --version '2.338.2' --sha256 '%s'" % SHA, p.stdout)

    def test_the_launch_agent_runs_in_the_desktop_session_and_stays_up(self):
        out = run('install', '--dry-run', '--token', 't').stdout
        self.assertIn('<key>Label</key><string>com.videoscan.gh-runner</string>', out)
        self.assertIn('<key>LimitLoadToSessionType</key><string>Aqua</string>', out)
        self.assertIn('<key>KeepAlive</key><true/>', out)
        self.assertIn('<key>RunAtLoad</key><true/>', out)
        self.assertIn('<key>ProcessType</key><string>Standard</string>', out)
        self.assertIn('/opt/homebrew/bin:', out)
        self.assertIn('actions-runner/run.sh</string>', out)
        self.assertNotIn('SessionCreate', out)

    def test_remove_mints_a_removal_token_and_status_reads_the_host(self):
        out = run('remove', '--dry-run').stdout
        self.assertIn('actions/runners/remove-token', out)
        self.assertIn("__host remove --host 'm4'", out)
        st = run('status', '--dry-run').stdout
        self.assertIn('ssh ricksm4.local', st)
        self.assertIn('launchctl print', st)
        self.assertIn('.runner', st)


class HostSideTests(unittest.TestCase):

    def _env(self, home):
        env = dict(os.environ, HOME=home)
        env['PATH'] = '/usr/bin:/bin:/usr/local/bin'
        return env

    def test_refuses_to_register_twice(self):
        with tempfile.TemporaryDirectory() as home:
            root = pathlib.Path(home, 'actions-runner')
            root.mkdir()
            (root / '.runner').write_text(json.dumps({'agentName': 'RicksM4'}))
            env = self._env(home)
            env['GH_RUNNER_TOKEN'] = 'x'
            p = run('__host', 'install', '--host', 'm4', env=env)
            self.assertEqual(p.returncode, 3, p.stderr)
            self.assertIn("already configured", p.stdout)
            self.assertIn("as 'RicksM4'", p.stdout)
            self.assertIn('remove --host m4 first', p.stdout)

    def test_refuses_without_a_token_before_touching_the_network(self):
        with tempfile.TemporaryDirectory() as home:
            env = self._env(home)
            env.pop('GH_RUNNER_TOKEN', None)
            env['GH_RUNNER_RELEASES_API'] = 'http://127.0.0.1:9/never'
            p = run('__host', 'install', '--host', 'm4', env=env)
            self.assertEqual(p.returncode, 1)
            self.assertIn('no registration token', p.stderr)
            self.assertFalse(pathlib.Path(home, 'actions-runner', 'release.json').exists())

    def test_remove_without_a_runner_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as home:
            env = self._env(home)
            # launchctl stand-in: not on a Mac here, and never the real one in a test.
            fake = pathlib.Path(home, 'bin')
            fake.mkdir()
            (fake / 'launchctl').write_text('#!/bin/sh\nexit 1\n')
            (fake / 'launchctl').chmod(0o755)
            env['PATH'] = str(fake) + ':' + env['PATH']
            p = run('__host', 'remove', '--host', 'm4', env=env)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('no runner configured', p.stdout)


class TestbedWaitTests(unittest.TestCase):

    def _wait(self, lock, *args, now=None):
        env = dict(os.environ)
        if now is not None:
            env['VIDEOSCAN_TESTBED_WAIT_NOW'] = now
        else:
            env.pop('VIDEOSCAN_TESTBED_WAIT_NOW', None)
        return subprocess.run(['/bin/bash', str(WAIT), '--lock', str(lock), '--interval', '1', *args],
                              capture_output=True, text=True, env=env, timeout=60)

    def _holder(self, lock):
        # A process that holds the testbed lock the way the real scripts do: fd 9, flocked by the helper.
        code = ('import os, subprocess, sys, time\n'
                'fd = os.open(sys.argv[1] + "/flock", os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)\n'
                'os.dup2(fd, 9)\n'
                'print(subprocess.run([sys.executable, sys.argv[2], "hold", "9", sys.argv[1], "deep sha=abc"], '
                'capture_output=True, text=True, pass_fds=(9,)).stdout.strip(), flush=True)\n'
                'time.sleep(60)\n')
        p = subprocess.Popen([sys.executable, '-c', code, str(lock), str(LOCK_HELPER)],
                             stdout=subprocess.PIPE, text=True)
        self.assertEqual(p.stdout.readline().strip(), 'HELD')
        return p

    def test_free_lock_returns_at_once(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._wait(pathlib.Path(d, 'lock'), now='1000')
            self.assertEqual((p.returncode, p.stdout), (0, ''))

    def test_held_lock_waits_then_gives_up_at_the_budget(self):
        with tempfile.TemporaryDirectory() as d:
            lock = pathlib.Path(d, 'lock')
            lock.mkdir()
            holder = self._holder(lock)
            try:
                p = self._wait(lock, '--budget', '2', now='1000')
            finally:
                holder.kill()
                holder.wait()
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn('waiting — deep sha=abc', p.stdout)
            self.assertIn('still waiting after 2s', p.stderr)

    def test_held_lock_released_lets_the_job_go(self):
        with tempfile.TemporaryDirectory() as d:
            lock = pathlib.Path(d, 'lock')
            lock.mkdir()
            holder = self._holder(lock)
            proc = subprocess.Popen(['/bin/bash', str(WAIT), '--lock', str(lock), '--interval', '1', '--budget', '30'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    env=dict(os.environ, VIDEOSCAN_TESTBED_WAIT_NOW='1000'))
            first = proc.stdout.readline()          # the waiter has seen the held lock
            self.assertIn('waiting — deep sha=abc', first)
            holder.kill()
            holder.wait()
            out, err = proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0, first + out + err)
            self.assertIn('idle after', out)

    def test_the_nightlys_window_is_sat_out_even_when_free(self):
        with tempfile.TemporaryDirectory() as d:
            lock = pathlib.Path(d, 'lock')
            p = self._wait(lock, '--budget', '1', now='1355')
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn("14:00 nightly's window (1355)", p.stdout)
            for t in ('1349', '1405', '0200'):
                self.assertEqual(self._wait(lock, '--budget', '1', now=t).returncode, 0, t)

    def test_usage(self):
        self.assertEqual(subprocess.run(['/bin/bash', str(WAIT), '--bogus'], capture_output=True).returncode, 2)
        self.assertEqual(subprocess.run(['/bin/bash', str(WAIT), '--interval', '0'], capture_output=True).returncode, 2)


if __name__ == '__main__':
    unittest.main()
