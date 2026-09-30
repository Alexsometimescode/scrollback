"""Run python3 core/test_chat_metadata.py. Synthetic metadata only."""
import hashlib
import json
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory
from chat_metadata import codex_metadata


def check():
    with TemporaryDirectory() as temp:
        home=Path(temp);root=home/'sessions';root.mkdir()
        assert codex_metadata(root)=={}
        (home/'session_index.jsonl').write_text('\n'.join([json.dumps(dict(id='one',thread_name='Index old')),json.dumps(dict(id='one',thread_name='Index latest')),'malformed',json.dumps(dict(id='index',thread_name='Index only'))]))
        assert codex_metadata(root)['one']['title']=='Index latest'
        db=home/'state_5.sqlite';c=sqlite3.connect(db)
        c.execute('CREATE TABLE threads (id TEXT,name TEXT,title TEXT,project_id TEXT)')
        c.execute('CREATE TABLE projects (id TEXT,name TEXT)')
        c.execute('INSERT INTO projects VALUES (?,?)',('p','Saved project'))
        c.executemany('INSERT INTO threads VALUES (?,?,?,?)',[('one','App name','Initial prompt','p'),('two',None,'Old title',None),('three',None,None,'p')])
        c.commit();c.close();before=hashlib.sha256(db.read_bytes()).hexdigest()
        (home/'.codex-global-state.json').write_text(json.dumps({'local-projects':{'legacy':{'name':'Assigned project'}},'thread-project-assignments':{'two':{'projectId':'legacy'}},'projectless-thread-ids':['one']}))
        result=codex_metadata(root)
        assert result['one']==dict(title='App name',project='No project')
        assert result['two']==dict(title='Old title',project='Assigned project')
        assert result['three']['project']=='Saved project'
        assert result['index']['title']=='Index only'
        assert hashlib.sha256(db.read_bytes()).hexdigest()==before
        (home/'state_12.sqlite').write_bytes(b'corrupt optional database')
        assert codex_metadata(root)['one']['title']=='Index latest'
        (home/'.codex-global-state.json').write_text('broken')
        assert codex_metadata(root)['one']==dict(title='Index latest')
    print('Codex metadata checks passed')

if __name__=='__main__':
    check()
