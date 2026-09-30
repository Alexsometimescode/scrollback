"""Run with python3 core/test_summary.py; no provider calls or real chat data."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
from types import SimpleNamespace
from summary import draft

with TemporaryDirectory() as tmp:
    root = Path(tmp)
    skill = root/'SKILL.md'; skill.write_text('Completed, Decisions Made, Pending, Context & Notes')
    cli = root/'claude'; cli.touch()
    conf = {'SUMMARY_SKILL': str(skill), 'SUMMARY_CLI': str(cli)}
    response = dict(summary='A concise overview', categories='## Completed\n- Verified work')
    def provider(args, **kwargs):
        assert '--safe-mode' in args and '--no-session-persistence' in args
        assert args[args.index('--tools')+1] == ''
        assert kwargs['timeout'] == 180
        assert 'Selected period: 2026-01-01 to 2026-01-03' in kwargs['input']
        assert 'Evidence' in kwargs['input']
        assert not list(Path(kwargs['cwd']).iterdir())
        return SimpleNamespace(returncode=0,stdout=json.dumps(dict(structured_output=response)))
    with patch('summary.subprocess.run', side_effect=provider):
        assert draft('Evidence','2026-01-01','2026-01-03',conf)==response
    with patch('summary.subprocess.run', side_effect=provider) as run:
        assert draft('Evidence','2026-01-01','2026-01-03',dict(conf, SUMMARY_MODEL='test-model')) == response
        args = run.call_args.args[0]
        assert args[args.index('--model') + 1] == 'test-model'
    for bad in ['not JSON',json.dumps({'structured_output': {'summary': '', 'categories': 'x'}}),json.dumps({'is_error':True})]:
        with patch('summary.subprocess.run', return_value=SimpleNamespace(returncode=0,stdout=bad)):
            try: draft('Evidence','2026-01-01','2026-01-03',conf)
            except ValueError: pass
            else: raise AssertionError('Invalid provider output accepted')
    with patch('summary.subprocess.run') as run:
        try: draft('x'*350001,'2026-01-01','2026-01-03',conf)
        except ValueError: pass
        else: raise AssertionError('Oversized context accepted')
        run.assert_not_called()
print('Summary checks passed: skill reference, no tools, structured output, error and size handling')

# Preview routes only selected chats and never creates a note or collection file.
import history_collect
with TemporaryDirectory() as tmp:
    output = Path(tmp)/'not-created'
    row = dict(sid='codex:one',title='Named chat',project='Project',title_source='app',
               users=['Evidence'],answers=['Verified result'],stamps=['2026-01-02T12:00:00Z'],actions=[],files=[])
    other = dict(row,sid='codex:two',users=['Unselected private content'])
    class Conf(dict):
        five = output
        def __getitem__(self, key): return self.get(key, '')
    conf = Conf(SUMMARY_ENABLED='true')
    with patch('history_collect.load_sessions',return_value={'codex:one':row,'codex:two':other}), patch('summary.draft',return_value=response) as generate:
        result=history_collect.execute(dict(operation='preview',start='2026-01-01',end='2026-01-03',agents=['codex'],selected=['codex:one']),conf)
        assert result['summary']==response['summary'] and len(result['chats'])==1
        assert 'Unselected private content' not in generate.call_args.args[0]
        assert not output.exists()
    print('Preview selection and no-save checks passed')

    query = dict(operation='preview',start='2026-01-01',end='2026-01-03',agents=['codex'],selected=['codex:one'])
    with patch('history_collect.load_sessions',return_value={'codex:one':dict(row,project_display='No project')}), patch('summary.draft',side_effect=ValueError('Not signed in')):
        recovered=history_collect.execute(query,conf)
        assert recovered['handoff'] and recovered['notice'] and recovered['summary']
        assert 'No project' not in recovered['handoff'] and recovered['chats'][0]['project']==''
        assert not output.exists()
    with patch('history_collect.load_sessions',return_value={}), patch('summary.draft') as provider:
        assert history_collect.execute(query,conf)==dict(chats=[],empty=True)
        assert history_collect.execute(dict(query,selected=[]),conf)==dict(chats=[],empty=True)
        provider.assert_not_called()
    conf['SUMMARY_ENABLED']='false'
    with patch('history_collect.load_sessions',return_value={'codex:one':row}), patch('summary.draft') as provider:
        assert history_collect.execute(query,conf)['handoff']
        provider.assert_not_called()
print('Unavailable provider, local-only handoff, unassigned project, and empty selection checks passed')

# Real configuration protocol and browser-context attributes must work.
import scroll
conf = object.__new__(scroll.Conf)
conf.v = {'SUMMARY_SKILL': ''}
assert conf.get('SUMMARY_SKILL') == ''
assert conf.get('missing', 'default') == 'default'
assert history_collect._clean_message('<in-app-browser-context source="ambient">hidden</in-app-browser-context>Build a ledger') == 'Build a ledger'
print('Configuration and clean chat descriptions passed')

with patch('history_collect.render', return_value='x' * 100000):
    bounded = history_collect.summary_context([{}] * 35, '2026-09-16', '2026-09-30')
    assert len(bounded) < 210000 and bounded.count('Evidence shortened') == 35
print('Large selection evidence budget passed')
