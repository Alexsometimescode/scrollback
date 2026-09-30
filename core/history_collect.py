#!/usr/bin/env python3
"""List dated conversations or collect an explicit selection into a new file."""
import json
import re
import sqlite3
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import scroll

AGENTS = {'claude', 'codex', 'cursor', 'grok'}
_BROWSER = re.compile(r'<in-app-browser-context\b[^>]*>[\s\S]*?</in-app-browser-context>', re.I)
_USER_QUERY = re.compile(r'<user_query>([\s\S]*?)</user_query>', re.I)


def _clean_message(text):
    if not isinstance(text, str):
        return ''
    cleaned = _BROWSER.sub('', text)
    queries = _USER_QUERY.findall(cleaned)
    if queries:
        cleaned = '\n'.join(part.strip() for part in queries if part.strip())
    return scroll.WS.sub(' ', cleaned).strip()


def _looks_like_path(text):
    text = text.strip()
    return text.startswith(('/', '~')) or (len(text) > 48 and '/' in text)


def _short_label(value):
    if not isinstance(value, str) or not value.strip():
        return ''
    text = value.strip()
    if not _looks_like_path(text):
        return text if len(text) <= 48 else text[:45] + '…'
    parts = Path(text.replace('~', str(Path.home()))).parts
    if len(parts) >= 2:
        return '…/' + '/'.join(parts[-2:])
    return parts[-1] if parts else text[:48]


def _display_title(row):
    title = scroll.WS.sub(' ', row.get('title') or '').strip()
    if row.get('title_source') == 'app' and title and not _looks_like_path(title):
        return title[:120]
    cleaned = _clean_message(title)
    if cleaned and not _looks_like_path(cleaned):
        return cleaned[:120]
    agent = row['sid'].split(':', 1)[0].capitalize()
    label = _short_label(row.get('project_display') or row.get('project') or '')
    return ('%s chat · %s' % (agent, label))[:120] if label else ('%s chat' % agent)


def _display_preview(row):
    messages = list(dict.fromkeys(_clean_message(text) for text in row.get('users', []) if _clean_message(text)))
    excerpts = messages[:1] + (messages[-1:] if len(messages) > 1 else [])
    preview = scroll.redact(' · '.join(text[:80] for text in excerpts))
    if not preview and row.get('answers'):
        preview = 'Assistant: ' + scroll.redact(_clean_message(row['answers'][-1])[:120])
    if len(preview) > 120:
        preview = preview[:117] + '…'
    return preview


def request(value):
    if not isinstance(value, dict) or value.get('operation') not in ('list', 'collect', 'preview'):
        raise ValueError('Operation must be list, preview, or collect')
    try:
        start = date.fromisoformat(value['start'])
        end = date.fromisoformat(value['end'])
    except (KeyError, TypeError, ValueError):
        raise ValueError('Start and end must be YYYY-MM-DD dates') from None
    if start.isoformat() != value['start'] or end.isoformat() != value['end']:
        raise ValueError('Start and end must be YYYY-MM-DD dates')
    if end < start or (end - start).days >= 366:
        raise ValueError('Choose an inclusive range of 1 to 366 days')
    agents = value.get('agents')
    if not isinstance(agents, list) or not agents or any(not isinstance(a, str) or a not in AGENTS for a in agents):
        raise ValueError('Choose claude, codex, cursor, or grok')
    selected = value.get('selected', [])
    if not isinstance(selected, list) or any(not isinstance(s, str) or not s for s in selected):
        raise ValueError('Selected must contain session IDs')
    if value['operation'] == 'collect' and not selected:
        raise ValueError('Select at least one conversation')
    return start, end, set(agents), set(selected)


def timestamp(value, tz):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if stamp.tzinfo is None:
            return None
        return stamp.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ'), stamp.astimezone(tz).date()
    except (ValueError, OverflowError):
        return None


def claude_sessions(conf, start, end):
    """Read activity dates; a typed user anywhere establishes human eligibility."""
    for directory in conf.project_dirs():
        for path in sorted(directory.glob('*.jsonl')):
            users, answers, stamps, files = [], [], [], []
            actions, known_tools = {}, {}
            title, human = '', False
            with path.open(encoding='utf-8') as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        if not line.endswith('\n'):
                            break
                        raise ValueError('Malformed Claude transcript: ' + path.name) from None
                    if not isinstance(row, dict):
                        raise ValueError('Claude transcript record must be an object')
                    if row.get('isSidechain'):
                        continue
                    if isinstance(row.get('customTitle'), str):
                        title = row['customTitle']
                    message = row.get('message') or {}
                    if not isinstance(message, dict):
                        continue
                    content = message.get('content')
                    origin = row.get('origin') or {}
                    typed = row.get('promptSource') == 'typed' or (isinstance(origin, dict) and origin.get('kind') == 'human')
                    user = row.get('type') == 'user' and typed and isinstance(content, str) and bool(content.strip())
                    human = human or user
                    stamp = timestamp(row.get('timestamp'), conf.tz)
                    in_range = bool(stamp and start <= stamp[1] <= end)
                    if user and in_range:
                        users.append(content)
                        stamps.append(stamp[0])
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        kind = block.get('type')
                        if row.get('type') == 'assistant' and kind == 'tool_use':
                            tool_id = block.get('id') or 'anonymous-%s' % len(known_tools)
                            action = dict(name=block.get('name') or 'tool', status='started', started_at=stamp[0] if stamp else '')
                            known_tools[tool_id] = action
                            if in_range:
                                actions[tool_id] = dict(action)
                                stamps.append(stamp[0])
                        elif row.get('type') == 'user' and kind == 'tool_result' and in_range:
                            tool_id = block.get('tool_use_id') or 'result-%s' % len(actions)
                            action = actions.setdefault(tool_id, dict(known_tools.get(tool_id, dict(name='tool', started_at=''))))
                            action.update(status='error' if block.get('is_error') else 'returned', completed_at=stamp[0])
                            stamps.append(stamp[0])
                        elif row.get('type') == 'assistant' and kind == 'text' and isinstance(block.get('text'), str) and in_range:
                            answers.append(block['text'])
                            stamps.append(stamp[0])
            if human and stamps:
                yield dict(sid='claude:' + path.stem, project=conf.proj_name(directory), title=title or (users[0][:100] if users else 'Claude chat'), users=users,
                           title_source='app' if title else 'message', answers=answers, stamps=sorted(stamps), actions=list(actions.values()), files=files, tools=len(actions))


def load_sessions(conf, start, end, agents):
    rows = []
    if 'claude' in agents:
        rows.extend(claude_sessions(conf, start, end))
    if 'codex' in agents:
        from sources import codex_sessions
    if 'cursor' in agents:
        from cursor_source import sessions as cursor_sessions
    for offset in range((end - start).days + 1):
        day = (start + timedelta(days=offset)).isoformat()
        if 'codex' in agents:
            rows.extend(codex_sessions(conf, day, require_user=False, outside_workdir=True))
        if 'grok' in agents:
            from grok_source import sessions as grok_sessions
            rows.extend(grok_sessions(conf, day, require_user=False))
        if 'cursor' in agents:
            # Collect is an explicit user request; include empty-window Cursor chats
            # here even when daily digest keeps them behind CURSOR_INCLUDE_UNSCOPED.
            rows.extend(cursor_sessions(conf, day, require_user=False, include_unscoped=True))
    merged = {}
    for row in rows:
        sid = row['sid']
        if sid not in merged:
            merged[sid] = dict(row, users=[], answers=[], stamps=[], actions=[], files=[])
        dest = merged[sid]
        for field in ('users', 'answers', 'stamps', 'actions', 'files'):
            dest[field].extend(row.get(field, []))
        if row.get('latest_activity'):
            dest['stamps'].append(row['latest_activity'])
    return merged


def metadata(row):
    stamps = sorted(pair[0] for value in row['stamps'] if (pair := timestamp(value, timezone.utc)))
    if not stamps:
        raise ValueError('Conversation has no activity timestamps in the selected range')
    project = row.get('project_display') or row['project']
    if project in ('No project', 'Cursor (no workspace)', 'No workspace'):
        project = ''
    return dict(id=row['sid'], agent=row['sid'].split(':', 1)[0], title=_display_title(row),
                title_source=row.get('title_source', 'message'), preview=_display_preview(row),
                project=project, project_label=_short_label(project), first=stamps[0], last=stamps[-1])


def render(rows, start, end):
    lines = ['# Selected chat context', '', 'Dates: %s to %s (inclusive).' % (start, end), 'Conversations: %s.' % len(rows), '']
    for row in rows:
        info = metadata(row)
        lines.extend(['## ' + scroll.WS.sub(' ', info['title']), '', '- Agent: ' + info['agent'], *(['- Project: ' + info['project']] if info['project'] else []),
                      '- Session: ' + info['id'], '- First: ' + info['first'], '- Last: ' + info['last'], '', '### User messages', ''])
        for text in row['users']:
            lines.extend([text, ''])
        lines.extend(['### Assistant messages', ''])
        for text in row['answers']:
            lines.extend([text, ''])
        if row['actions']:
            lines.extend(['### Actions', ''])
            for action in row['actions']:
                lines.append('- %s | %s | started %s | completed %s' % (
                    scroll.WS.sub(' ', str(action.get('name', 'tool'))), scroll.WS.sub(' ', str(action.get('status', 'unknown'))),
                    action.get('started_at') or 'unknown', action.get('completed_at') or 'not recorded'))
            lines.append('')
    return scroll.redact('\n'.join(lines))


def summary_context(rows, start, end):
    """Bound preview evidence per chat while preserving every selected chat."""
    budget = max(500, 200000 // max(1, len(rows)))
    parts = []
    for row in rows:
        text = render([row], start, end)
        if len(text) > budget:
            half = (budget - 100) // 2
            text = text[:half] + '\n[Evidence shortened: middle omitted. Do not infer missing outcomes.]\n' + text[-half:]
        parts.append(text)
    return '\n\n'.join(parts)


def execute(value, conf):
    start, end, agents, selected = request(value)
    if value['operation'] == 'preview' and not selected:
        return dict(chats=[], empty=True)
    sessions = load_sessions(conf, start, end, agents)
    chats = sorted((metadata(row) for row in sessions.values()), key=lambda row: (row['first'], row['id']))
    result = dict(chats=chats)
    if value['operation'] in ('collect', 'preview'):
        if not sessions and value['operation'] == 'preview':
            return dict(chats=[], empty=True)
        if selected - sessions.keys():
            raise ValueError('Selection is stale or outside the requested dates and agents; refresh the list')
        rows = [sessions[chat['id']] for chat in chats if chat['id'] in selected]
        if value['operation'] == 'preview':
            from summary import draft, local_draft
            context = render(rows, start, end)
            fallback = local_draft([metadata(row) for row in rows], context, start, end, conf)
            from summary import synthesizer_label
            label = synthesizer_label(conf)
            if str(conf['SUMMARY_ENABLED']).lower() != 'true':
                fallback['notice'] = 'Local evidence draft (summarizer: %s is off in Settings). Summary and categories are excerpts, not AI synthesis.' % label
                fallback['synthesizer'] = label
                return dict(chats=[metadata(row) for row in rows], **fallback)
            try:
                overview = draft(summary_context(rows, start, end), start, end, conf)
                overview['synthesizer'] = label
                overview.setdefault('notice', 'Overview from %s.' % label)
                return dict(chats=[metadata(row) for row in rows], handoff=fallback['handoff'], **overview)
            except (OSError, ValueError):
                fallback['notice'] = 'AI synthesis via %s failed; showing a local evidence draft instead.' % label
                fallback['synthesizer'] = label
                return dict(chats=[metadata(row) for row in rows], **fallback)
        directory = conf.five / 'collections'
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / ('%s-to-%s-%s.md' % (start, end, uuid.uuid4().hex))
        text = render(rows, start, end)
        stream = path.open('x', encoding='utf-8')
        try:
            with stream:
                stream.write(text)
        except OSError:
            path.unlink(missing_ok=True)
            raise
        result.update(chats=[metadata(row) for row in rows], path=str(path), count=len(rows))
    return result


def main():
    try:
        value = json.load(sys.stdin)
        request(value)  # Reject bad requests before configuration creates directories.
        print(json.dumps(execute(value, scroll.Conf())))
        return 0
    except (OSError, ValueError, TypeError, KeyError, ImportError, sqlite3.Error) as error:
        print('Historical collection failed: ' + str(error).splitlines()[0][:240], file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
