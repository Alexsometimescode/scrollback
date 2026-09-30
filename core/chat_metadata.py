"""Optional local Codex display metadata, never conversation eligibility."""
import json
import sqlite3
from pathlib import Path


def codex_metadata(root):
    home = Path(root).expanduser().parent
    result = {}
    try:
        with (home / 'session_index.jsonl').open(encoding='utf-8') as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get('id'), str) and isinstance(row.get('thread_name'), str) and row['thread_name'].strip():
                    result[row['id']] = {'title': row['thread_name'].strip()}
    except (OSError, UnicodeError):
        pass
    try:
        databases = [p for p in home.glob('state_*.sqlite') if p.stem.removeprefix('state_').isdigit()]
    except OSError:
        databases = []
    if databases:
        db = max(databases, key=lambda p: int(p.stem.removeprefix('state_')))
        connection = None
        try:
            connection = sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True)
            connection.execute('PRAGMA query_only=ON')
            connection.execute('BEGIN')
            columns = {r[1] for r in connection.execute('PRAGMA table_info(threads)')}
            fields = [name for name in ('id', 'name', 'title', 'project_id') if name in columns]
            projects = {}
            try:
                projects = dict(connection.execute('SELECT id,name FROM projects'))
            except sqlite3.Error:
                pass
            if 'id' in fields:
                for values in connection.execute('SELECT ' + ','.join(fields) + ' FROM threads'):
                    row = dict(zip(fields, values))
                    if not isinstance(row['id'], str):
                        continue
                    item = result.setdefault(row['id'], {})
                    title = next((value for value in (row.get('name'), row.get('title')) if isinstance(value, str) and value.strip()), None)
                    if isinstance(title, str) and title.strip():
                        item['title'] = title.strip()
                    project = projects.get(row.get('project_id'))
                    if isinstance(project, str) and project.strip():
                        item['project'] = project.strip()
        except (OSError, sqlite3.Error):
            pass
        finally:
            if connection is not None:
                connection.close()
    try:
        state = json.loads((home / '.codex-global-state.json').read_text(encoding='utf-8'))
        if not isinstance(state, dict):
            return result
        projects = state.get('local-projects') or {}
        assignments = state.get('thread-project-assignments') or {}
        if isinstance(projects, dict) and isinstance(assignments, dict):
            for sid, assignment in assignments.items():
                if not isinstance(assignment, dict):
                    continue
                project_id = assignment.get('projectId')
                if not isinstance(project_id, str):
                    continue
                project = projects.get(project_id)
                if isinstance(project, dict) and isinstance(project.get('name'), str) and project['name'].strip():
                    result.setdefault(sid, {})['project'] = project['name'].strip()
        projectless = state.get('projectless-thread-ids') or []
        if isinstance(projectless, list):
            for sid in projectless:
                if isinstance(sid, str):
                    result.setdefault(sid, {})['project'] = 'No project'
    except (OSError, ValueError):
        pass
    return result
