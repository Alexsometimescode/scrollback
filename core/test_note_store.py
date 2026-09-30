"""Run python3 core/test_note_store.py. No files outside temporary directories."""
from pathlib import Path
from tempfile import TemporaryDirectory
from note_store import save_note
from unittest.mock import patch
import json
import subprocess
import sys


def check():
    with TemporaryDirectory() as temp:
        root = Path(temp).resolve()
        path=root/'note.md'
        assert save_note(path,'First draft')['saved']
        before=path.read_bytes()
        try:
            save_note(path,'Replacement')
        except FileExistsError:
            pass
        else:
            raise AssertionError('Existing note overwritten')
        assert path.read_bytes()==before
        assert save_note(path,'Second draft',append=True)['saved']
        after=path.read_bytes()
        assert after.startswith(before) and b'Second draft' in after
        assert not save_note(path,'Second draft',append=True)['saved']
        assert path.read_bytes()==after
        assert save_note(root/'new.md','Create on append',append=True)['saved']
        for invalid,text in [(root/'bad.txt','x'),(root/'empty.md','  '),(root,'x')]:
            try:
                save_note(invalid,text,append=True)
            except (ValueError,OSError):
                pass
            else:
                raise AssertionError('Invalid note accepted')
        link=root/'link.md';link.symlink_to(path)
        try:
            save_note(link,'Bad',append=True)
        except ValueError:
            pass
        else:
            raise AssertionError('Symlink accepted')
        assert path.read_bytes()==after
        with patch('note_store.os.fsync',side_effect=[OSError('synthetic flush failure'),None]):
            try:
                save_note(path,'Failed append',append=True)
            except OSError:
                pass
            else:
                raise AssertionError('Write failure hidden')
        assert path.read_bytes()==after
        request=dict(operation='append',path=str(path),text='From CLI')
        process=subprocess.run([sys.executable,str(Path(__file__).with_name('note_store.py'))],input=json.dumps(request),capture_output=True,text=True)
        assert process.returncode==0 and json.loads(process.stdout)['saved']
    print('Note store checks passed')

if __name__=='__main__':
    check()
