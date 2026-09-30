"""Synthetic CLI checks for historical selection, no real user logs."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
with TemporaryDirectory() as tmp:
    root = Path(tmp)
    work = root/'work'
    project = work/'demo'
    project.mkdir(parents=True)
    claude = root/'claude'/str(project).replace('/', '-')
    claude.mkdir(parents=True)
    codex = root/'codex'
    codex.mkdir()
    def write(path, rows):
        path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
    user = lambda stamp,text: dict(type='user',timestamp=stamp,promptSource='typed',message=dict(content=text))
    write(claude/'one.jsonl', [user('2026-01-01T21:59:00Z','outside start'), user('2026-01-01T22:00:00Z','included first boundary'), user('2026-01-03T21:59:59Z','included last boundary'),user('2026-01-03T22:00:00Z','outside end')])
    # Fixed UTC+2 via Etc/GMT-2 tests local midnight boundaries.
    write(codex/'one.jsonl', [dict(type='session_meta',payload=dict(id='one',cwd=str(project)))] + [dict(type='event_msg',timestamp=t,payload=dict(type='user_message',message=text)) for t,text in [('2026-01-02T10:00:00Z','Codex day one'),('2026-01-03T10:00:00Z','Codex day two'),('2026-01-04T10:00:00Z','Codex outside')]])
    db = root/'cursor.vscdb'
    with sqlite3.connect(db) as con:
        con.execute('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY,value TEXT)')
        data = {'composerData:one':dict(name='Cursor fixture',workspaceIdentifier=dict(folderUri=project.as_uri()),fullConversationHeadersOnly=[dict(bubbleId='one')]), 'bubbleId:one:one':dict(type=1,text='Cursor inside',createdAt='2026-01-03T10:00:00Z')}
        con.executemany('INSERT INTO cursorDiskKV VALUES (?,?)',[(k,json.dumps(v)) for k,v in data.items()])
    conf = root/'paths.conf'
    conf.write_text('\n'.join("%s='%s'" % (k,v) for k,v in dict(WORKDIR=work,PROJECTS=claude.parent,CODEX_SESSIONS=codex,CURSOR_DB=db,CURSOR_PROJECTS=root/'none',LOGDIR=root/'logs',FIVE=root/'five',TZ_NAME='Etc/GMT-2',EXCLUDED='demo',EXCLUDED_CHATS='codex:one').items()))
    env = dict(os.environ,BEAT_HOME=str(root),BEAT_CONF=str(conf),PYTHONDONTWRITEBYTECODE='1')
    query = dict(operation='list',start='2026-01-02',end='2026-01-03',agents=['claude','codex','cursor'])
    def call(value, success=True):
        p = subprocess.run([sys.executable,str(HERE/'history_collect.py')],input=json.dumps(value),env=env,capture_output=True,text=True)
        assert (p.returncode==0)==success,(p.stdout,p.stderr)
        if not success:
            assert not p.stdout and 'Historical collection failed:' in p.stderr
            return
        return json.loads(p.stdout)
    listed = call(query)['chats']
    assert len(listed)==3 and {r['id'] for r in listed}=={'claude:one','codex:one','cursor:one'}
    assert next(r for r in listed if r['agent']=='claude')['first']=='2026-01-01T22:00:00.000000Z'
    assert next(r for r in listed if r['agent']=='cursor')['title_source']=='app'
    assert next(r for r in listed if r['agent']=='codex')['preview']=='Codex day one · Codex day two'
    assert all('outside' not in r['preview'] for r in listed)
    collected = call(dict(query,operation='collect',selected=['claude:one','codex:one']))
    text = Path(collected['path']).read_text()
    assert collected['count']==2 and 'included first boundary' in text and 'included last boundary' in text
    assert 'outside' not in text and 'Cursor inside' not in text and text.count('## Codex day one')==1
    again = call(dict(query,operation='collect',selected=['claude:one','codex:one']))
    assert again['path']!=collected['path'] and Path(collected['path']).read_text()==text
    assert not list((root/'five').glob('week_*'))
    call(dict(query,operation='collect',selected=[]),False)
    call(dict(query,operation='collect',selected=['missing']),False)
    call(dict(query,start='2026-01-04'),False)
    call(dict(query,start='2024-01-01'),False)
    call(dict(query,start='2026-02-30'),False)
    # A continuation day needs no fresh user prompt, but requires a human session.
    continuation = [user('2026-01-01T10:00:00Z','earlier prompt'),
        dict(type='assistant',timestamp='2026-01-03T09:00:00Z',message=dict(content=[dict(type='tool_use',id='call',name='Read')])),
        dict(type='user',timestamp='2026-01-03T09:01:00Z',message=dict(content=[dict(type='tool_result',tool_use_id='call',is_error=True)])),
        dict(type='assistant',timestamp='2026-01-03T09:02:00Z',message=dict(content=[dict(type='text',text='continued answer')]))]
    write(claude/'continued.jsonl',continuation)
    write(claude/'automated.jsonl',continuation[1:])
    continuation_query = dict(query,start='2026-01-03',end='2026-01-03',agents=['claude'])
    assert {r['id'] for r in call(continuation_query)['chats']}=={'claude:one','claude:continued'}
    continuation_file=call(dict(continuation_query,operation='collect',selected=['claude:continued']))
    continuation_text=Path(continuation_file['path']).read_text()
    assert 'continued answer' in continuation_text and 'earlier prompt' not in continuation_text
    assert 'Read | error | started 2026-01-03T09:00:00.000000Z | completed 2026-01-03T09:01:00.000000Z' in continuation_text
    with (codex/'one.jsonl').open('a') as f:
        f.write(json.dumps(dict(type='event_msg',timestamp='2026-01-05T10:00:00Z',payload=dict(type='agent_message',message='Codex continuation')))+'\n')
    with sqlite3.connect(db) as con:
        composer=json.loads(con.execute("SELECT value FROM cursorDiskKV WHERE key='composerData:one'").fetchone()[0])
        composer['fullConversationHeadersOnly'].append(dict(bubbleId='continued'))
        con.execute("UPDATE cursorDiskKV SET value=? WHERE key='composerData:one'",(json.dumps(composer),))
        con.execute('INSERT INTO cursorDiskKV VALUES (?,?)',('bubbleId:one:continued',json.dumps(dict(type=2,text='Cursor continuation',createdAt='2026-01-05T10:00:00Z'))))
    only_continuations=dict(query,start='2026-01-05',end='2026-01-05',agents=['codex','cursor'])
    assert {r['id'] for r in call(only_continuations)['chats']}=={'codex:one','cursor:one'}
    # Unselected providers cannot interfere: corrupt Cursor, then list Claude only.
    db.write_text('not SQLite')
    assert len(call(dict(query,agents=['claude']))['chats'])==2
    call(dict(query,agents=['cursor']),False)
    with (claude/'one.jsonl').open('a') as f:
        f.write('{broken}\n')
    call(dict(query,agents=['claude']),False)
print('Historical CLI: all three sources, date boundaries, filters, unique selection, no overwrite, validation and malformed input passed')
