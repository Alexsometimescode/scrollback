"""No network or installed summarizers: python3 -m unittest core.test_writeups."""
import base64
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from core import scroll, summary, writeups


class WriteupTest(unittest.TestCase):
    def test_digest_only_custom_prompt_redaction_and_atomic_destination(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / 'week_40'
            folder.mkdir()
            (folder / '2026-10-01-context.md').write_text('Evidence ghp_' + 'x' * 40)
            note = folder / '2026-10-01.md'
            note.write_text('User note, never evidence')
            prompt = base64.b64encode('My daily prompt'.encode()).decode()
            settings = {'WRITEUPS_ENABLED': 'true', 'DAILY_PROMPT_B64': prompt, 'SUMMARY_PROVIDER': 'codex'}
            conf = SimpleNamespace(five=Path(root), tz=None, v=settings, get=settings.get)
            with patch.object(summary, 'draft', return_value={'summary': 'Outcome', 'categories': 'Details'}) as draft:
                output = writeups.run(conf, 'daily', '2026-10-01')
            args = draft.call_args.args
            self.assertIn('[redacted]', args[0])
            self.assertNotIn('User note', args[0])
            self.assertEqual(summary.prompt_override(args[3], 'SUMMARY_PROMPT_B64', ''), 'My daily prompt')
            self.assertEqual(output.name, '2026-10-01-scrollback-daily.md')
            self.assertEqual(note.read_text(), 'User note, never evidence')
            with patch.object(summary, 'draft', side_effect=ValueError('provider failed')):
                with self.assertRaises(ValueError):
                    writeups.run(conf, 'daily', '2026-10-01')
            self.assertIn('Outcome', output.read_text())
            with patch.object(summary, 'draft', return_value={'summary': 'Week', 'categories': 'Details'}) as draft:
                writeups.run(conf, 'weekly', '2026-10-01')
            self.assertEqual(draft.call_args.args[1:3], ('2026-09-28', '2026-10-01'))
            settings['WRITEUPS_ENABLED'] = 'false'
            with patch.object(summary, 'draft') as draft:
                self.assertIsNone(writeups.run(conf, 'daily', '2026-10-01'))
                draft.assert_not_called()

    def test_unset_writeups_disabled(self):
        conf = SimpleNamespace(get={}.get)
        with patch.object(summary, 'draft') as draft:
            self.assertIsNone(writeups.run(conf, 'daily'))
            draft.assert_not_called()
        self.assertEqual(scroll.DEFAULTS['WRITEUPS_ENABLED'], 'false')

    def test_invalid_prompt_rejected(self):
        with self.assertRaises(ValueError):
            summary.prompt_override({'X': 'bad!'}, 'X', '')

class OllamaTest(unittest.TestCase):
    def test_reject_remote_metadata(self):
        import io
        with patch.object(summary, 'build_opener') as opener:
            opener.return_value.open.return_value = io.BytesIO(b'{"remote_model":"remote","model_info":{"a":1}}')
            with self.assertRaises(ValueError):
                summary._verify_local_model('http://127.0.0.1:11434', 'alias')
            opener.return_value.open.return_value = io.BytesIO(b'{"model_info":{"a":1}}')
            summary._verify_local_model('http://127.0.0.1:11434', 'small')

    def test_local_installed_model_only(self):
        import subprocess
        with patch.object(summary, 'resolve_cli', return_value=('/bin/ollama', 'Ollama')), patch.dict('os.environ', {'OLLAMA_HOST': '127.0.0.1:11434'}), patch.object(summary, '_verify_local_model'), patch.object(summary.subprocess, 'run') as run:
            run.side_effect = [subprocess.CompletedProcess([], 0, 'NAME ID SIZE\nsmall:latest 123 1GB\n'), subprocess.CompletedProcess([], 0, '{"summary":"Local outcome","categories":"Decisions"}')]
            self.assertEqual(summary.draft('Evidence', '2026-10-01', '2026-10-01', {'SUMMARY_MODEL': 'small:latest'})['summary'], 'Local outcome')
            self.assertEqual(run.call_args_list[1].args[0], ['/bin/ollama', 'run', 'small:latest', '--format', 'json'])
            run.reset_mock()
            run.side_effect = None
            run.return_value = subprocess.CompletedProcess([], 0, 'NAME ID SIZE\n')
            with self.assertRaises(ValueError):
                summary.draft('Evidence', '2026-10-01', '2026-10-01', {'SUMMARY_MODEL': 'missing'})
            self.assertEqual(run.call_count, 1)
        with patch.object(summary, 'resolve_cli', return_value=('/bin/ollama', 'Ollama')), patch.dict('os.environ', {'OLLAMA_HOST': 'https://remote.example'}), patch.object(summary.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                summary.draft('Evidence', '2026-10-01', '2026-10-01', {'SUMMARY_MODEL': 'small:latest'})
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
