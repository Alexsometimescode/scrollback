"""Updater CLI regressions using fake external commands and isolated config."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / 'checkout'
        self.checkout.mkdir()
        for name in ('update.sh', 'paths.sh'):
            shutil.copy2(ROOT / name, self.checkout / name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.progress = self.root / 'progress'
        self.config = self.root / 'paths.conf'
        self.config.write_text("LOGDIR='%s'\nHIST='%s'\nPROG='%s'\n" %
                               (self.root / 'logs', self.root / 'history/log', self.progress))
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                        BEAT_HOME=str(self.checkout), SCROLLBACK_HOME=str(self.checkout),
                        BEAT_CONF=str(self.config), AUDIT_CALLS=str(self.calls),
                        GH_HOST='retired.example', LOCAL_ONLY='', BEATBAR_LOCAL_ONLY='')
        self.command('defaults', 'echo 1.0.0')
        for name in ('git', 'gh', 'open', 'pkill', 'ditto'):
            self.command(name, 'exit 1')
        (self.checkout / 'Scrollback/Scrollback.app/Contents').mkdir(parents=True)

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $* GH_HOST=$GH_HOST" >> "$AUDIT_CALLS"\n' + body + '\n')
        path.chmod(0o755)

    def run_update(self, *args):
        return subprocess.run(['zsh', str(self.checkout / 'update.sh'), *args],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def test_local_only_exits_before_sourcing_configuration(self):
        marker = self.root / 'configuration-executed'
        self.config.write_text("touch '%s'\n" % marker)
        self.env['LOCAL_ONLY'] = 'true'
        result = self.run_update('--check')
        self.assertEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertFalse(self.calls.exists())

    def test_release_check_uses_public_host_despite_ambient_host(self):
        self.command('gh', 'echo v1.1.0')
        result = self.run_update('--check')
        self.assertEqual(result.returncode, 0)
        self.assertIn('LATEST|1.1.0', result.stdout)
        calls = self.calls.read_text()
        self.assertIn('GH_HOST=github.com', calls)
        self.assertIn('--repo https://github.com/Alexsometimescode/scrollback', calls)
        self.assertNotIn('GH_HOST=retired.example', calls)

    def test_untrusted_checkout_is_rejected_without_network_or_release_fallback(self):
        (self.checkout / '.git').mkdir()
        for remote in ('https://enterprise.example/me/scrollback.git',
                       'https://github.com/other/scrollback.git'):
            self.command('git', 'case "$*" in *"remote get-url origin"*) echo "%s";; *) exit 99;; esac' % remote)
            for args in (('--check',), ()):
                with self.subTest(remote=remote, args=args):
                    self.calls.unlink(missing_ok=True)
                    result = self.run_update(*args)
                    self.assertNotEqual(result.returncode, 0)
                    calls = self.calls.read_text()
                    self.assertNotIn(' fetch ', calls)
                    self.assertNotIn(' pull ', calls)
                    self.assertNotIn('/gh ', calls)

    def checkout_git(self):
        (self.checkout / '.git').mkdir(exist_ok=True)
        self.command('git', '''case "$*" in
*"remote get-url origin"*) echo https://github.com/Alexsometimescode/scrollback.git;;
*"fetch "*) exit "${FETCH_RESULT:-0}";;
*"rev-parse HEAD"*) echo local;;
*"rev-parse"*) echo remote;;
*"merge-base --is-ancestor"*) exit "${ANCESTOR_RESULT:-1}";;
*"show "*) printf '%s' "${REMOTE_VERSION:-1.1.0}";;
*) exit 99;;
esac''')

    def test_local_ahead_or_diverged_does_not_offer_update(self):
        self.checkout_git()
        result = self.run_update('--check')
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('LATEST|', result.stdout)

    def test_checkout_update_requires_explicit_build_and_never_claims_binary_updated(self):
        self.checkout_git()
        result = self.run_update()
        self.assertEqual(result.returncode, 2)
        self.assertIn('Source build required', self.progress.read_text())
        calls = self.calls.read_text()
        for operation in (' pull ', '/open ', '/pkill ', '/ditto ', '/gh '):
            self.assertNotIn(operation, calls)

    def test_release_check_never_offers_older_or_invalid_release(self):
        for tag in ('v0.9.0', 'v1.0.0', '', 'not-a-version'):
            with self.subTest(tag=tag):
                self.command('gh', "printf '%s' '%s'" % ('%s', tag))
                result = self.run_update('--check')
                self.assertNotIn('LATEST|', result.stdout)

    def test_remote_ahead_offers_nonempty_version_and_failed_fetch_does_not(self):
        self.checkout_git()
        self.env['ANCESTOR_RESULT'] = '0'
        result = self.run_update('--check')
        self.assertIn('LATEST|1.1.0', result.stdout)
        self.assertIn('fetch -q https://github.com/Alexsometimescode/scrollback.git main', self.calls.read_text())
        self.env['REMOTE_VERSION'] = ' '
        self.assertNotIn('LATEST|', self.run_update('--check').stdout)
        self.env['FETCH_RESULT'] = '1'
        result = self.run_update('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('LATEST|', result.stdout)

    def test_missing_release_cannot_claim_success_or_restart(self):
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Update unavailable', self.progress.read_text())
        calls = self.calls.read_text()
        self.assertNotIn('/open ', calls)
        self.assertNotIn('/pkill ', calls)

    def test_failed_release_copy_preserves_installed_app_and_never_restarts(self):
        installed = self.checkout / 'Scrollback/Scrollback.app/existing.txt'
        installed.write_text('old app')
        self.command('gh', 'case "$*" in *"release view"*) echo v1.1.0;; *"release download"*) exit 0;; *) exit 99;; esac')
        self.command('ditto', 'mkdir -p "$4/Scrollback.app/Contents"')
        self.command('cp', 'exit 1')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(installed.read_text(), 'old app')
        self.assertIn('Update failed', self.progress.read_text())
        calls = self.calls.read_text()
        self.assertNotIn('/open ', calls)
        self.assertNotIn('/pkill ', calls)

    def test_failed_release_lookup_cannot_offer_or_download_its_stdout_tag(self):
        self.command('gh', 'case "$*" in *"release view"*) echo v1.1.0; exit 1;; *) exit 99;; esac')
        for args in (('--check',), ()):
            with self.subTest(args=args):
                self.calls.unlink(missing_ok=True)
                result = self.run_update(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('LATEST|', result.stdout)
                self.assertNotIn('release download', self.calls.read_text())

    def test_packaged_install_pins_tag_replaces_bundle_and_reopens_that_app(self):
        app = self.checkout / 'Scrollback/Scrollback.app'
        (app / 'old.txt').write_text('previous app')
        self.command('gh', 'case "$*" in *"release view"*) echo v1.1.0;; *"release download v1.1.0 "*) exit 0;; *) exit 99;; esac')
        self.command('ditto', 'mkdir -p "$4/Scrollback.app/Contents"\nprintf "1.1.0" > "$4/Scrollback.app/new.txt"')
        self.command('sleep', 'exit 0')
        self.command('pkill', 'exit 0')
        self.command('open', 'exit 0')
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((app / 'old.txt').exists())
        self.assertEqual((app / 'new.txt').read_text(), '1.1.0')
        self.assertIn('Restarting|now on v1.1.0', self.progress.read_text())
        deadline = time.monotonic() + 2
        while '/open ' not in self.calls.read_text() and time.monotonic() < deadline:
            time.sleep(0.01)
        calls = self.calls.read_text()
        self.assertIn('release download v1.1.0 --repo https://github.com/Alexsometimescode/scrollback ', calls)
        self.assertIn('/pkill -x Scrollback ', calls)
        self.assertIn('/open %s GH_HOST=github.com' % app, calls)
        self.assertNotIn('/Applications/', calls)


if __name__ == '__main__':
    unittest.main()
