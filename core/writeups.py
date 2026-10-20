"""Built-in write-ups from collected digest evidence, saved by the app only."""
import base64
from datetime import date, datetime, timedelta
import os
from pathlib import Path
import tempfile

try:
    from . import summary, scroll
except ImportError:
    import summary
    import scroll

DAILY_PROMPT = 'Summarize the selected day: completed work, decisions, blockers, and next actions. Use concise bullets grouped by project. Distinguish verified results from requests and unfinished work. Do not invent facts.'
WEEKLY_PROMPT = 'Summarize the selected week: key outcomes, biggest supported achievement, decisions, unresolved blockers, and next priorities. Group concise bullets by project and avoid repeating daily entries. Do not invent facts.'


def run(conf, kind, day=''):
    if conf.get('WRITEUPS_ENABLED', '').lower() != 'true':
        return None
    if kind not in ('daily', 'weekly'):
        raise ValueError('Choose a daily or weekly write-up.')
    end = date.fromisoformat(day) if day else datetime.now(conf.tz).date()
    start = end if kind == 'daily' else end - timedelta(days=end.weekday())
    evidence = []
    current = start
    while current <= end:
        path = conf.five / scroll.week_of(current.isoformat()) / (current.isoformat() + '-context.md')
        if path.is_file() and not path.is_symlink():
            evidence.append(path.read_text(encoding='utf-8'))
        current += timedelta(days=1)
    if not evidence:
        raise ValueError('No collected digest evidence exists for this period. Collect chats first.')
    guidance = summary.prompt_override(conf, kind.upper() + '_PROMPT_B64', DAILY_PROMPT if kind == 'daily' else WEEKLY_PROMPT)
    settings = dict(conf.v)
    settings['SUMMARY_PROMPT_B64'] = base64.b64encode(guidance.encode('utf-8')).decode('ascii')
    result = summary.draft(scroll.redact('\n\n'.join(evidence)), start.isoformat(), end.isoformat(), settings)
    content = '# Scrollback %s write-up\n\n%s to %s\n\n%s\n\n%s\n' % (kind, start, end, result['summary'], result['categories'])
    folder = conf.five / scroll.week_of(end.isoformat())
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / ('%s-scrollback-%s.md' % (start, kind))
    # A stable app-owned filename never replaces the user's daily note.
    fd, temporary = tempfile.mkstemp(prefix='.scrollback-writeup-', dir=folder)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return target
