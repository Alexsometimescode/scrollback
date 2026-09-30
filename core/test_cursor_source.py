"""Synthetic SQLite checks: python3 core/test_cursor_source.py."""
import hashlib
import json
import sqlite3
from datetime import datetime, timezone, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from cursor_source import sessions


def check():
    with TemporaryDirectory() as temp:
        root = Path(temp)
        db = root / 'state.vscdb'
        class Conf(dict):
            workdir = root / 'work'
            tz = timezone(timedelta(hours=2))
            def __getitem__(self, key):
                return self.get(key, '')
        conf = Conf(CURSOR_DB=str(db))
        assert sessions(conf, '2026-09-30') == []
        conn = sqlite3.connect(db)
        conn.execute('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY,value TEXT)')
        def put(key, value):
            conn.execute('INSERT OR REPLACE INTO cursorDiskKV VALUES (?,?)',(key,json.dumps(value)))
        def chat(sid, uris, **extra):
            put('composerData:'+sid,dict(composerId=sid,name='Test',fullConversationHeadersOnly=[dict(bubbleId='u'),dict(bubbleId='a'),dict(bubbleId='t'),dict(bubbleId='t2'),dict(bubbleId='t')],**extra))
            put('bubbleId:'+sid+':u',dict(type=1,bubbleId='u',createdAt='2026-09-29T23:30:00Z',text='Request',workspaceUris=uris))
            put('bubbleId:'+sid+':a',dict(type=2,bubbleId='a',createdAt='2026-09-30T01:00:00Z',text='Reply',workspaceUris=uris))
            put('bubbleId:'+sid+':t',dict(type=2,bubbleId='t',createdAt='2026-09-30T01:01:00Z',startedAtMs=1790730060000,endedAtMs=1790730062000,toolFormerData=dict(toolCallId='one',name='read_file',status='completed')))
            put('bubbleId:'+sid+':t2',dict(type=2,bubbleId='t2',createdAt='2026-09-30T01:02:00Z',toolFormerData=dict(toolCallId='two',name='shell',status='error')))
        chat('parent',[(conf.workdir/'project').as_uri()],subagentComposerIds=['child'])
        chat('child',[(conf.workdir/'project').as_uri()])
        chat('subagent',[(conf.workdir/'project').as_uri()],subagentInfo=dict(parentComposerId='parent'))
        chat('draft',[(conf.workdir/'project').as_uri()],isDraft=True)
        chat('outside',[(root/'work-other').as_uri()])
        chat('unscoped',[],workspaceIdentifier=dict(id='empty-window'))
        conn.commit()
        conn.close()
        before=hashlib.sha256(db.read_bytes()).hexdigest()
        rows=sessions(conf,'2026-09-30')
        assert len(rows)==1 and rows[0]['sid']=='cursor:parent'
        row=rows[0]
        assert row['users']==['Request'] and row['answers']==['Reply'] and row['project']=='project'
        assert row['tools']==2 and [a['status'] for a in row['actions']]==['completed','error']
        assert 'completed_at' in row['actions'][0] and 'completed_at' not in row['actions'][1]
        assert row['stamps']==['2026-09-29T23:30:00.000000Z']
        assert row['latest_activity']=='2026-09-30T01:02:00.000000Z'
        conn=sqlite3.connect(db)
        value=json.loads(conn.execute('SELECT value FROM cursorDiskKV WHERE key=?',('bubbleId:parent:a',)).fetchone()[0])
        value['createdAt']='2026-09-30T04:00:00Z'
        conn.execute('UPDATE cursorDiskKV SET value=? WHERE key=?',(json.dumps(value),'bubbleId:parent:a'))
        conn.commit();conn.close()
        assert sessions(conf,'2026-09-30')[0]['latest_activity']=='2026-09-30T04:00:00.000000Z'
        conn=sqlite3.connect(db)
        value=json.loads(conn.execute('SELECT value FROM cursorDiskKV WHERE key=?',('bubbleId:parent:t',)).fetchone()[0])
        value['endedAtMs']=datetime(2026,9,30,5,tzinfo=timezone.utc).timestamp()*1000
        conn.execute('UPDATE cursorDiskKV SET value=? WHERE key=?',(json.dumps(value),'bubbleId:parent:t'))
        conn.commit();conn.close()
        assert sessions(conf,'2026-09-30')[0]['latest_activity']=='2026-09-30T05:00:00.000000Z'
        before=hashlib.sha256(db.read_bytes()).hexdigest()
        assert sessions(conf,'2026-09-29')==[]
        assert sessions(conf,'2026-10-01')==[]
        conf['CURSOR_INCLUDE_UNSCOPED']='true'
        rows=sessions(conf,'2026-09-30')
        assert len(rows)==2 and next(r for r in rows if r['sid']=='cursor:unscoped')['project']=='Cursor (no workspace)'
        assert hashlib.sha256(db.read_bytes()).hexdigest()==before
        conn=sqlite3.connect(db)
        value=json.loads(conn.execute('SELECT value FROM cursorDiskKV WHERE key=?',('bubbleId:parent:a',)).fetchone()[0])
        value['createdAt']='2026-10-01T04:00:00Z'
        conn.execute('UPDATE cursorDiskKV SET value=? WHERE key=?',(json.dumps(value),'bubbleId:parent:a'))
        value=json.loads(conn.execute('SELECT value FROM cursorDiskKV WHERE key=?',('bubbleId:parent:t',)).fetchone()[0])
        value['endedAtMs']=datetime(2026,10,1,5,tzinfo=timezone.utc).timestamp()*1000
        conn.execute('UPDATE cursorDiskKV SET value=? WHERE key=?',(json.dumps(value),'bubbleId:parent:t'))
        conn.commit();conn.close()
        assert sessions(conf,'2026-10-01')==[]
        continued=sessions(conf,'2026-10-01',require_user=False)
        assert len(continued)==1 and continued[0]['users']==[] and continued[0]['answers']==['Reply']
        assert continued[0]['tools']==1 and continued[0]['latest_activity']=='2026-10-01T05:00:00.000000Z'
        assert continued[0]['actions'][0]['started_at'].startswith('2026-09-30')
        assert continued[0]['stamps'][0]=='2026-10-01T04:00:00.000000Z'
        conn=sqlite3.connect(db)
        conn.execute('DELETE FROM cursorDiskKV WHERE key=?',('bubbleId:parent:u',))
        conn.commit();conn.close()
        assert sessions(conf,'2026-10-01',require_user=False)==[]
        bad=root/'bad.db';bad.write_bytes(b'not a sqlite database');conf['CURSOR_DB']=str(bad)
        try:
            sessions(conf,'2026-09-30')
        except sqlite3.DatabaseError:
            pass
        else:
            raise AssertionError('Corruption was hidden')
    print('Cursor source checks passed')

if __name__ == '__main__':
    check()
