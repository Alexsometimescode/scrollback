#!/usr/bin/env python3
"""Check shell/Python source integration in an isolated fixture, no real logs."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'core').mkdir()
    shutil.copy(HERE / 'scroll.py', root / 'core/scroll.py')
    for name in ('paths.sh', 'chats_list.sh', 'digest.sh'):
        shutil.copy(HERE.parent / name, root / name)
    (root / 'core/sources.py').write_text('''
def sessions(conf, day):
    return [dict(sid='codex:fixture', project='demo', title='Fixture title',
                 stamps=[day+'T10:00:00.000Z'], users=['Build fixture'],
                 answers=['Built fixture'], tools=2, files=['example.py'],
                 path='/fixture/session.jsonl')]
''')
    (root / 'paths.conf').write_text("\n".join(
        "%s='%s'" % (k, v) for k, v in {
            'WORKDIR':root/'work', 'PROJECTS':root/'empty',
            'LOGDIR':root/'logs', 'EXTRA_SOURCES':'true',
            'DAILY_COMMAND':'', 'TZ_NAME':'Europe/Prague'}.items()))
    env = dict(os.environ, BEAT_HOME=str(root), BEAT_CONF=str(root/'paths.conf'),
               BEAT_ALL='1')
    def run(args, five):
        result = subprocess.run(args, env=dict(env, FIVE=str(root/five)),
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()
    shell = run(['zsh', str(root/'chats_list.sh')], 'shell')
    py = run([sys.executable, str(root/'core/scroll.py'), 'chats'], 'python')
    assert shell == py and 'codex:fixture|demo|Fixture title|' in py
    for args, five in ((['zsh', str(root/'digest.sh')], 'shell'),
                       ([sys.executable, str(root/'core/scroll.py'), 'digest'], 'python')):
        assert run(args, five).endswith('SESSIONS|1')
    def body(five):
        text = next((root/five).glob('week_*/*-context.md')).read_text()
        return '\n'.join(line for line in text.splitlines()
                         if not line.startswith('Generated '))
    assert body('shell') == body('python')
    # Exclusion applies to both digest paths and marks all-chat rows disabled.
    with (root/'paths.conf').open('a') as f:
        f.write("\nEXCLUDED_CHATS='codex:fixture'\n")
    for cache in (root/'logs').glob('.chats-*.cache'):
        cache.unlink()
    assert run(['zsh', str(root/'chats_list.sh')], 'shell').endswith('|0')
    assert run([sys.executable, str(root/'core/scroll.py'), 'digest'], 'python').endswith('SESSIONS|0')
    # Explicit parser errors cannot publish a successful digest.
    (root/'core/sources.py').write_text('def sessions(conf, day):\n    raise ValueError("fixture parse failure")\n')
    for cache in (root/'logs').glob('.chats-*.cache'):
        cache.unlink()
    for args in (['zsh', str(root/'chats_list.sh')], ['zsh', str(root/'digest.sh')],
                 [sys.executable, str(root/'core/scroll.py'), 'digest']):
        result = subprocess.run(args, env=dict(env, FIVE=str(root/'python')),
                                text=True, capture_output=True)
        assert result.returncode != 0 and 'SESSIONS|' not in result.stdout
print('Source integration: chat parity, digest parity, exclusion, parser failure passed')

# Real provider parsers share the same public CLI contracts.
import json
import sqlite3
from datetime import date, datetime, timezone
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    shutil.copytree(HERE, root/'core', ignore=shutil.ignore_patterns('__pycache__'))
    for name in ('paths.sh', 'chats_list.sh', 'digest.sh'):
        shutil.copy(HERE.parent/name, root/name)
    work = root/'work'
    project = work/'demo'
    project.mkdir(parents=True)
    codex = root/'codex'
    codex.mkdir()
    claude = root/'claude'
    encoded = str(project).replace('/', '-')
    (claude/encoded).mkdir(parents=True)
    day = date.today().isoformat()
    stamp = day+'T10:00:00.000Z'
    def jsonl(path, rows):
        path.write_text('\n'.join(json.dumps(row, separators=(',', ':')) for row in rows)+'\n')
    jsonl(claude/encoded/'claude-fixture.jsonl', [
        dict(type='user', timestamp=stamp, promptSource='typed', message=dict(content='Claude fixture')),
        dict(type='assistant', timestamp=stamp, message=dict(content=[dict(type='text', text='Claude answer')]))])
    jsonl(codex/'fixture.jsonl', [
        dict(type='session_meta', payload=dict(id='fixture', cwd=str(project))),
        dict(type='event_msg', timestamp=stamp, payload=dict(type='user_message', message='Codex fixture')),
        dict(type='event_msg', timestamp=stamp, payload=dict(type='agent_message', message='Codex answer'))])
    db = root/'cursor.vscdb'
    with sqlite3.connect(db) as connection:
        connection.execute('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)')
        records = {
            'composerData:fixture': dict(name='Cursor fixture', workspaceIdentifier=dict(folderUri=project.as_uri()), fullConversationHeadersOnly=[dict(bubbleId='user'), dict(bubbleId='tool')]),
            'bubbleId:fixture:user': dict(type=1, text='Cursor fixture', createdAt=stamp),
            'bubbleId:fixture:tool': dict(type=2, text='Cursor answer', createdAt=stamp, endedAtMs=int(datetime.fromisoformat(day+'T11:00:00+00:00').timestamp()*1000), toolFormerData=dict(toolCallId='tool-1', name='read_file', status='completed'))}
        connection.executemany('INSERT INTO cursorDiskKV VALUES (?,?)', [(k,json.dumps(v)) for k,v in records.items()])
    (root/'paths.conf').write_text('\n'.join("%s='%s'" % (k,v) for k,v in {
        'WORKDIR':work,'PROJECTS':claude,'CODEX_SESSIONS':codex,'CURSOR_PROJECTS':root/'empty-cursor',
        'CURSOR_DB':db,'LOGDIR':root/'logs','EXTRA_SOURCES':'true','DAILY_COMMAND':'','TZ_NAME':'UTC'}.items()))
    env = dict(os.environ, BEAT_HOME=str(root), BEAT_CONF=str(root/'paths.conf'), BEAT_ALL='1', PYTHONDONTWRITEBYTECODE='1')
    def actual(args, five='five'):
        result = subprocess.run(args, env=dict(env,FIVE=str(root/five)), capture_output=True,text=True)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()
    shell = actual(['zsh',str(root/'chats_list.sh'),'--all'])
    python = actual([sys.executable,str(root/'core/scroll.py'),'chats','--all'])
    assert sorted(shell.splitlines()) == sorted(python.splitlines()), (shell,python)
    assert len(shell.splitlines()) == 3, shell
    for args,five in ((['zsh',str(root/'digest.sh')],'shell'),([sys.executable,str(root/'core/scroll.py'),'digest'],'python')):
        assert actual(args,five).endswith('SESSIONS|3')
        text = next((root/five).glob('week_*/*-context.md')).read_text()
        assert 'read_file | completed' in text and 'completed '+day+'T11:00:00' in text
    cutoff = datetime.fromisoformat(day+'T10:30:00+00:00').timestamp()
    assert actual([sys.executable,str(root/'core/scroll.py'),'extra-changed',str(cutoff)]) == '1'
print('Actual Claude, Codex, Cursor fixtures: chats parity, digest count, action completion and changed-since passed')
