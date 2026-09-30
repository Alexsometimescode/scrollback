"""Run with python3 core/test_sources.py. All data is synthetic and local."""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from sources import sessions, read_cursor, codex_sessions


def check():
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        class Conf(dict):
            workdir = root / 'work'
            tz = timezone(timedelta(hours=2))
            def __getitem__(self, key):
                return self.get(key, '')
        conf = Conf(CODEX_SESSIONS=str(root / 'codex'), CURSOR_PROJECTS=str(root / 'cursor'))
        Path(conf['CODEX_SESSIONS']).mkdir()
        today = datetime.now(conf.tz).date().isoformat()
        def write(name, sid, cwd, parent=None):
            rows = [dict(type='session_meta', payload=dict(id=sid, cwd=str(cwd), parent_thread_id=parent)),
                    dict(type='response_item', timestamp=today+'T10:00:00Z', payload=dict(type='message', role='user', content=[dict(type='input_text',text='Injected instructions')])),
                    dict(type='event_msg', timestamp='2020-01-01T23:30:00Z', payload=dict(type='user_message', message='Historical prompt')),
                    dict(type='event_msg', timestamp=today+'T10:00:00Z', payload=dict(type='user_message', message='Actual prompt')),
                    dict(type='event_msg', timestamp=today+'T10:01:00Z', payload=dict(type='agent_message', message='Answer')),
                    dict(type='event_msg', timestamp='invalid', payload=dict(type='user_message', message='Bad timestamp')),
                    dict(type='event_msg', payload=None)]
            rows.append(rows[3])
            (Path(conf['CODEX_SESSIONS']) / name).write_text('\n'.join(json.dumps(r) for r in rows)+'\n{broken')
        write('a.jsonl','one',conf.workdir/'project')
        write('duplicate.jsonl','one',conf.workdir/'project')
        write('outside.jsonl','two',root/'work-other')
        write('child.jsonl','three',conf.workdir/'project','parent')
        (root/'session_index.jsonl').write_text(json.dumps(dict(id='one',thread_name='App chat name'))+'\n')
        (root/'.codex-global-state.json').write_text(json.dumps({'projectless-thread-ids':['one']}))
        rows = sessions(conf,today)
        assert len(rows)==1 and rows[0]['sid']=='codex:one'
        assert rows[0]['users']==['Actual prompt'] and rows[0]['answers']==['Answer']
        assert rows[0]['project']=='project' and len(rows[0]['stamps'])==1
        assert rows[0]['project_display']=='No project' and rows[0]['title']=='App chat name'
        assert datetime.strptime(rows[0]['stamps'][0], '%Y-%m-%dT%H:%M:%S.%fZ')
        desktop = Path(conf['CODEX_SESSIONS']) / 'desktop.jsonl'
        meta = dict(type='session_meta', payload=dict(id='desktop',cwd=str(conf.workdir/'project')))
        def message(text, kinds, inherited=False):
            return dict(type='response_item',timestamp=today+'T10:00:00Z',
                        metadata=dict(inherited_user_message=inherited),
                        payload=dict(type='message',role='user',content=[dict(type='input_text',text=text)],
                                     internal_chat_message_metadata_passthrough=dict(content_item_kinds=kinds)))
        desktop.write_text('\n'.join(json.dumps(x) for x in [meta,
                           message('Injected',['agents_md.instructions']),
                           message('Environment',['environments.environment_context']),
                           message('Inherited',['user.text'],True),
                           message('Desktop prompt',['user.text'])]))
        desktop_rows=[r for r in sessions(conf,today) if r['sid']=='codex:desktop']
        assert len(desktop_rows)==1 and desktop_rows[0]['users']==['Desktop prompt']
        with desktop.open('a') as stream:
            stream.write('\n'+json.dumps(dict(type='event_msg',timestamp='2020-01-01T10:00:00Z',payload=dict(type='user_message',message='Old CLI prompt'))))
        assert [r for r in sessions(conf,today) if r['sid']=='codex:desktop'][0]['users']==['Desktop prompt']
        child=Path(conf['CODEX_SESSIONS'])/'nested.jsonl'
        child.write_text(json.dumps(dict(type='session_meta',payload=dict(id='child',parent_thread_id='desktop')))+'\n'+desktop.read_text())
        assert len(sessions(conf,today))==2
        os.utime(desktop,(1,1))
        assert len(sessions(conf,today))==1
        try:
            read_cursor(root/'missing.txt')
        except FileNotFoundError:
            pass
        else:
            raise AssertionError('read failure was swallowed')
        assert sessions(conf,'2020-01-01')==[]
        assert sessions(conf,'2020-01-02')[0]['users']==['Historical prompt']
        broken = Path(conf['CODEX_SESSIONS']) / 'bad.jsonl'
        broken.write_text('{broken\n')
        try:
            sessions(conf,today)
        except ValueError:
            pass
        else:
            raise AssertionError('complete corrupt record was swallowed')
        broken.unlink()
        transcript=root/'chat.txt'
        transcript.write_text('user:\n<user_query>Hello</user_query>\n\nassistant:\nHi\n[Tool call] tool\nprivate output\n')
        assert read_cursor(transcript)==(['Hello'],['Hi'])
        transcript=root/'chat.jsonl'
        transcript.write_text(json.dumps(dict(role='user',message=dict(content=[dict(type='text',text='Hello'),dict(type='tool_use',name='tool')]))))
        assert read_cursor(transcript)==(['Hello'],[])
        preview=subprocess.run([sys.executable,str(Path(__file__).with_name('sources.py')),'cursor',str(transcript)],capture_output=True,text=True,check=True)
        assert preview.stdout.startswith('Undated Cursor transcript, excluded from daily counts') and 'Hello' in preview.stdout
        continuation = Path(conf['CODEX_SESSIONS']) / 'continuation.jsonl'
        continuation.write_text('\n'.join(json.dumps(r) for r in [
            dict(type='session_meta',payload=dict(id='continuation',cwd=str(conf.workdir/'project'))),
            dict(type='event_msg',timestamp='2020-01-01T10:00:00Z',payload=dict(type='user_message',message='Old private prompt')),
            dict(type='response_item',timestamp='2020-01-01T21:59:00Z',payload=dict(type='function_call',call_id='tool1',name='shell')),
            dict(type='response_item',timestamp='2020-01-02T08:00:00Z',payload=dict(type='function_call_output',call_id='tool1',output='Tool result')),
            dict(type='event_msg',timestamp='2020-01-02T09:00:00Z',payload=dict(type='agent_message',message='Continuation answer')),
            dict(type='event_msg',timestamp='2020-01-03T09:00:00Z',payload=dict(type='token_count'))]))
        assert not any(r['sid']=='codex:continuation' for r in codex_sessions(conf,'2020-01-02'))
        continued=next(r for r in codex_sessions(conf,'2020-01-02',require_user=False) if r['sid']=='codex:continuation')
        assert continued['users']==[] and continued['answers']==['Continuation answer']
        assert continued['title']=='Codex chat' and continued['tools']==1
        assert continued['actions'][0]['started_at']=='2020-01-01T21:59:00.000000Z'
        assert continued['actions'][0]['completed_at']=='2020-01-02T08:00:00.000000Z'
        assert continued['stamps'][0]=='2020-01-02T08:00:00.000000Z'
        assert not any(r['sid']=='codex:continuation' for r in codex_sessions(conf,'2020-01-03',require_user=False))
        automated = Path(conf['CODEX_SESSIONS']) / 'automated.jsonl'
        data=[json.loads(line) for line in continuation.read_text().splitlines()]
        data[0]['payload']['id']='automated'
        data=[r for r in data if r.get('payload',{}).get('type')!='user_message']
        automated.write_text('\n'.join(json.dumps(r) for r in data))
        assert not any(r['sid']=='codex:automated' for r in codex_sessions(conf,'2020-01-02',require_user=False))
    print('sources checks passed')

if __name__ == '__main__':
    check()
