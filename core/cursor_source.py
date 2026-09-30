"""Read timestamped Cursor chats using a read-only SQLite snapshot."""
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse


def _time(value):
    try:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return datetime.fromtimestamp(value / 1000, timezone.utc)
        if isinstance(value, str):
            stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
            return stamp if stamp.tzinfo else None
    except (ValueError, OverflowError, OSError):
        pass
    return None


def _iso(stamp):
    return stamp.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')


def _path(value):
    if isinstance(value, dict):
        if value.get('scheme') not in (None, 'file'):
            return None
        value = value.get('fsPath') or value.get('path')
    if not isinstance(value, str) or not value:
        return None
    if value.startswith('file:'):
        uri = urlparse(value)
        if uri.netloc not in ('', 'localhost'):
            return None
        value = unquote(uri.path)
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else None


def _workspace(composer, bubbles, db, work):
    identity = composer.get('workspaceIdentifier') or {}
    candidates = []
    if isinstance(identity, dict):
        candidates.append(identity.get('folderUri'))
        ident = identity.get('id')
        if isinstance(ident, str) and ident and Path(ident).name == ident:
            mapping = db.parent.parent / 'workspaceStorage' / ident / 'workspace.json'
            if mapping.exists():
                data = json.loads(mapping.read_text(encoding='utf-8'))
                candidates.append(data.get('folder'))
    for bubble in bubbles:
        uris = bubble.get('workspaceUris') or []
        if isinstance(uris, list):
            candidates.extend(uris)
    scoped = set()
    for value in candidates:
        path = _path(value)
        if path is None:
            continue
        try:
            path.relative_to(work)
        except ValueError:
            return False  # Mixed workspaces must not leak outside the configured root.
        scoped.add(path)
    # No trustworthy cwd means no daily inclusion, even if tool arguments name files.
    return next(iter(scoped)) if len(scoped) == 1 else (False if scoped else None)


def sessions(conf, day, *, require_user=True, include_unscoped=None):
    db = Path(conf['CURSOR_DB'] or Path.home() / 'Library/Application Support/Cursor/User/globalStorage/state.vscdb').expanduser()
    if not db.exists():
        return []
    work = Path(conf.workdir).expanduser().resolve()
    allow_unscoped = (str(conf['CURSOR_INCLUDE_UNSCOPED']).lower() == 'true'
                      if include_unscoped is None else include_unscoped)
    output = []
    connection = sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True)
    try:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('BEGIN')
        composers = []
        for key, value in connection.execute("SELECT key,value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"):
            item = json.loads(value)
            if not isinstance(item, dict):
                raise ValueError('Cursor composer must be an object')
            composers.append((key.split(':', 1)[1], item))
        descendants = {child for _, item in composers for field in ('subagentComposerIds', 'subComposerIds')
                       for child in (item.get(field) or []) if isinstance(child, str)}
        for sid, composer in composers:
            if sid in descendants or composer.get('isDraft') or composer.get('subagentInfo') or composer.get('parentComposerId') or composer.get('isBestOfNSubcomposer'):
                continue
            bubbles, seen = [], set()
            headers = composer.get('fullConversationHeadersOnly') or []
            for header in headers:
                if not isinstance(header, dict) or not isinstance(header.get('bubbleId'), str):
                    continue
                bid = header['bubbleId']
                if bid in seen:
                    continue
                seen.add(bid)
                record = connection.execute('SELECT value FROM cursorDiskKV WHERE key=?', ('bubbleId:' + sid + ':' + bid,)).fetchone()
                if record is None:
                    continue
                bubble = json.loads(record[0])
                if not isinstance(bubble, dict):
                    raise ValueError('Cursor bubble must be an object')
                bubble = dict(bubble)
                bubble.setdefault('createdAt', header.get('createdAt'))
                bubbles.append(bubble)
            if not any(b.get("type") == 1 and isinstance(b.get("text"), str) and b["text"].strip() for b in bubbles):
                continue
            workspace = _workspace(composer, bubbles, db, work)
            if workspace is False or (workspace is None and not allow_unscoped):
                continue
            users, answers, stamps, actions, calls = [], [], [], [], set()
            activity = []
            for bubble in bubbles:
                stamp = _time(bubble.get('createdAt')) or _time(bubble.get('startedAtMs'))
                on_day = stamp is not None and stamp.astimezone(conf.tz).date().isoformat() == day
                text = bubble.get('text')
                if on_day and isinstance(text, str) and text.strip() and bubble.get('type') in (1, 2):
                    activity.append(_iso(stamp))
                    if bubble['type'] == 1:
                        users.append(text.strip())
                        stamps.append(_iso(stamp))
                    else:
                        answers.append(text.strip())
                tool = bubble.get('toolFormerData')
                completion = _time(bubble.get('completedAtMs')) or _time(bubble.get('endedAtMs'))
                completed_today = completion is not None and completion.astimezone(conf.tz).date().isoformat() == day
                if (on_day or completed_today) and isinstance(tool, dict) and isinstance(tool.get('toolCallId'), str) and tool['toolCallId'] not in calls:
                    calls.add(tool['toolCallId'])
                    started = _time(bubble.get('startedAtMs')) or stamp
                    action = dict(name=tool.get('name') or 'unknown', status=tool.get('status') or 'unknown',
                                  started_at=_iso(started) if started else '')
                    if on_day:
                        activity.append(_iso(stamp))
                    if completion:
                        action['completed_at'] = _iso(completion)
                    if completed_today:
                        activity.append(_iso(completion))
                    actions.append(action)
            if activity and (users or not require_user):
                relative = workspace.relative_to(work) if workspace is not None else None
                output.append(dict(sid='cursor:' + sid, project=('Cursor (no workspace)' if relative is None else str(relative) if relative.parts else work.name),
                                   title=composer.get('name') or (users[0][:100] if users else 'Cursor chat'),
                                   title_source='app' if composer.get('name') else 'message', stamps=sorted(stamps or activity), users=users,
                                   answers=answers, tools=len(calls), actions=actions, files=[], path=str(db),
                                   latest_activity=max(activity or stamps)))
    finally:
        connection.close()
    return output
