"""Save an explicitly approved Markdown draft without replacing existing notes."""
import hashlib
import json
import os
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import fcntl
except ImportError:
    fcntl = None


def save_note(path, text, append=False):
    if not isinstance(text, str) or not text.strip():
        raise ValueError('Draft is empty')
    if not isinstance(path, (str, Path)) or not str(path).strip():
        raise ValueError('Choose a Markdown file')
    path = Path(path).expanduser().absolute()
    if path.suffix.lower() != '.md':
        raise ValueError('Choose a .md file')
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError('Symbolic links are not supported')
    if fcntl is None:
        raise OSError('Safe note locking is unavailable on this platform')
    draft = text.strip()
    marker = '<!-- scrollback-draft:' + hashlib.sha256(draft.encode('utf-8')).hexdigest() + ' -->'
    flags = os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
    created = False
    try:
        fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
    except FileExistsError:
        if not append:
            raise FileExistsError('File already exists; choose Append or another filename') from None
        fd = os.open(path, flags)
    try:
        with os.fdopen(fd, 'r+b', buffering=0) as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('Choose a regular Markdown file')
            original = stream.read()
            if marker.encode('utf-8') in original:
                return dict(path=str(path), saved=False)
            stamp = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
            separator = ('\n\n---\n\n' if original else '')
            block = separator + '<!-- Saved by Scrollback ' + stamp + ' -->\n' + marker + '\n\n' + draft + '\n'
            try:
                stream.seek(0, os.SEEK_END)
                remaining = memoryview(block.encode('utf-8'))
                while remaining:
                    written = stream.write(remaining)
                    if not written:
                        raise OSError('Note write did not complete')
                    remaining = remaining[written:]
                stream.flush()
                os.fsync(stream.fileno())
            except BaseException:
                # Roll back only this append while holding the same file lock.
                stream.seek(len(original))
                stream.truncate()
                stream.flush()
                os.fsync(stream.fileno())
                raise
    except BaseException:
        if created:
            path.unlink(missing_ok=True)
        raise
    return dict(path=str(path), saved=True)


def main():
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict) or request.get('operation') not in ('save', 'append'):
            raise ValueError('Operation must be save or append')
        print(json.dumps(save_note(request.get('path'), request.get('text'), request['operation'] == 'append')))
        return 0
    except (OSError, ValueError, TypeError) as error:
        print('Note save failed: ' + str(error).splitlines()[0][:240], file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
