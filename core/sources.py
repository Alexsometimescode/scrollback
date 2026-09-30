"""Read-only saved agent transcripts. Never infer message dates from file mtime."""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def _rows(path):
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                row = json.loads(line)
            except ValueError:
                if not line.endswith("\n"):
                    # An active writer may not have completed its final record.
                    break
                raise
            if not isinstance(row, dict):
                raise ValueError("Transcript record must be a JSON object: " + str(path))
            yield row


def _stamp(value, tz):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            return None
        return stamp.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), stamp.astimezone(tz).date().isoformat()
    except (ValueError, OverflowError):
        return None


def read_cursor(path):
    """Return undated export content for explicit viewing, never daily attribution.

    Verified against installed Cursor's sFd JSONL serializer and text format.
    Neither serializer emits per-message timestamps.
    """
    path = Path(path)
    users, answers = [], []
    if path.suffix == ".jsonl":
        for row in _rows(path):
            message = row.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content", [])
            if not isinstance(content, list):
                continue
            text = "\n".join(part["text"] for part in content
                             if isinstance(part, dict) and part.get("type") == "text"
                             and isinstance(part.get("text"), str))
            if text.strip() and row.get("role") in ("user", "assistant"):
                (users if row["role"] == "user" else answers).append(text.strip())
    elif path.suffix == ".txt":
        text = path.read_text(encoding="utf-8", errors="replace")
        chunks = re.split(r"(?m)^(user|assistant):\s*\n", text)
        for role, body in zip(chunks[1::2], chunks[2::2]):
            body = re.split(r"(?m)^\[Tool (?:call|result)\]", body)[0].strip()
            queries = re.findall(r"<user_query>([\s\S]*?)</user_query>", body)
            if role == "user" and queries:
                body = "\n".join(queries).strip()
            if body:
                (users if role == "user" else answers).append(body)
    return users, answers


def _codex_text_blocks(content):
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        text = part.get("text")
        if isinstance(text, str) and text.strip() and kind in ("text", "input_text", "output_text", "Text"):
            parts.append(text.strip())
    return "\n".join(parts).strip()


def _codex_project(cwd, work, *, outside_workdir=False):
    path = Path(cwd).expanduser().resolve()
    try:
        relative = path.relative_to(work)
        return str(relative) if relative.parts else work.name, None
    except (ValueError, OSError):
        if not outside_workdir:
            return None, None
        label = path.name or "Codex"
        if path.parent.name:
            label = "%s · %s" % (path.parent.name, label)
        return label, label


def codex_sessions(conf, day, *, require_user=True, outside_workdir=False):
    root = Path(conf["CODEX_SESSIONS"] or Path.home() / ".codex/sessions").expanduser()
    work = Path(conf.workdir).expanduser().resolve()
    from chat_metadata import codex_metadata
    catalog = codex_metadata(root)
    result, seen = [], set()
    for path in sorted(root.rglob("*.jsonl")):
        # Older mtime safely rejects ordinary append-only sessions, including
        # historical requests; newer mtime never establishes user activity.
        if datetime.fromtimestamp(path.stat().st_mtime, conf.tz).date().isoformat() < day:
            continue
        rows = _rows(path)
        first = next(rows, {})
        meta = first.get("payload") if first.get("type") == "session_meta" else None
        if not isinstance(meta, dict):
            rows.close()
            continue
        if meta.get("parent_thread_id") or meta.get("agent_role") or meta.get("agent_path"):
            rows.close()
            continue
        source = meta.get("source")
        if isinstance(source, dict) and "subagent" in source:
            rows.close()
            continue
        cwd = meta.get("cwd")
        sid = meta.get("id") or meta.get("session_id")
        if not isinstance(cwd, str) or not cwd or not isinstance(sid, str) or not sid:
            rows.close()
            continue
        project, project_display = _codex_project(cwd, work, outside_workdir=outside_workdir)
        if project is None:
            rows.close()
            continue
        users, answers, stamps, unique, tool_calls = [], [], [], set(), set()
        fallback_users, fallback_answers, fallback_stamps = [], [], []
        has_user_events = False
        has_human = False
        activity = []
        actions = {}
        pending_actions = {}
        for row in rows:
            event = row.get("payload")
            if not isinstance(event, dict):
                continue
            stamp = _stamp(row.get("timestamp"), conf.tz)
            if row.get("type") == "event_msg" and event.get("type") == "user_message":
                text = event.get("message")
                has_human = has_human or (isinstance(text, str) and bool(text.strip()))
            if row.get("type") == "event_msg" and event.get("type") == "item_completed" and stamp and stamp[1] == day:
                item = event.get("item") or {}
                if isinstance(item, dict) and item.get("type") == "UserMessage":
                    text = _codex_text_blocks(item.get("content"))
                    if text:
                        has_human = True
                        key = (stamp[0], "item_user", text)
                        if key not in unique:
                            unique.add(key)
                            activity.append(stamp[0])
                            users.append(text)
                            stamps.append(stamp[0])
            if row.get("type") == "response_item" and event.get("type") == "message" and event.get("role") == "user":
                metadata = row.get("metadata") or {}
                passthrough = event.get("internal_chat_message_metadata_passthrough") or {}
                content = event.get("content") or []
                if isinstance(metadata, dict) and not metadata.get("inherited_user_message") and isinstance(content, list):
                    kinds = passthrough.get("content_item_kinds") or [] if isinstance(passthrough, dict) else []
                    if isinstance(kinds, list) and kinds:
                        has_human = has_human or any(i < len(kinds) and kinds[i] == "user.text" and isinstance(part, dict)
                                                    and isinstance(part.get("text"), str) and bool(part["text"].strip())
                                                    for i, part in enumerate(content))
                    else:
                        text = _codex_text_blocks(content)
                        has_human = has_human or bool(text)
            if row.get("type") == "response_item" and stamp:
                call_id = event.get("call_id")
                if call_id and event.get("type") in ("function_call", "custom_tool_call"):
                    action = dict(name=event.get("name") or "tool", status="started",
                                  started_at=stamp[0], completed_at="")
                    pending_actions[call_id] = action
                    if stamp[1] == day:
                        actions[call_id] = action.copy()
                        activity.append(stamp[0])
                elif call_id and event.get("type") in ("function_call_output", "custom_tool_call_output") and stamp[1] == day:
                    action = pending_actions.get(call_id, dict(name="tool", started_at="")).copy()
                    action.update(status="returned", completed_at=stamp[0])
                    actions[call_id] = action
                    tool_calls.add(str(call_id))
                    activity.append(stamp[0])
            if row.get("type") == "response_item" and event.get("type") in ("function_call", "custom_tool_call"):
                if stamp and stamp[1] == day:
                    tool_calls.add(str(event.get("call_id") or event.get("id") or json.dumps(event, sort_keys=True)))
            if row.get("type") == "response_item" and event.get("type") == "message" and stamp and stamp[1] == day:
                metadata = row.get("metadata") or {}
                passthrough = event.get("internal_chat_message_metadata_passthrough") or {}
                content = event.get("content") or []
                if isinstance(metadata, dict) and isinstance(content, list) and not metadata.get("inherited_user_message"):
                    kinds = passthrough.get("content_item_kinds") or [] if isinstance(passthrough, dict) else []
                    role = event.get("role")
                    text = ""
                    if isinstance(kinds, list) and kinds:
                        text = "\n".join(part["text"] for i, part in enumerate(content)
                                         if isinstance(part, dict) and isinstance(part.get("text"), str)
                                         and ((role == "user" and i < len(kinds) and kinds[i] == "user.text")
                                              or (role == "assistant" and (event.get("phase") == "final"
                                                  or (not require_user and event.get("phase") == "commentary")))))
                    elif role == "user":
                        text = _codex_text_blocks(content)
                    elif role == "assistant" and (event.get("phase") == "final"
                                                or (not require_user and event.get("phase") == "commentary")):
                        text = _codex_text_blocks(content)
                    key = (stamp[0], role, text)
                    if text.strip() and key not in unique:
                        unique.add(key)
                        activity.append(stamp[0])
                        if role == "user":
                            fallback_users.append(text.strip())
                            fallback_stamps.append(stamp[0])
                        elif role == "assistant":
                            fallback_answers.append(text.strip())
            if row.get("type") != "event_msg":
                continue
            if event.get("type") == "user_message" and stamp and stamp[1] == day:
                has_user_events = True
            text = event.get("message")
            if not stamp or stamp[1] != day or not isinstance(text, str) or not text.strip():
                continue
            kind = event.get("type")
            key = (stamp[0], kind, text)
            if key in unique:
                continue
            unique.add(key)
            if kind in ("user_message", "agent_message"):
                activity.append(stamp[0])
            if kind == "user_message":
                users.append(text.strip())
                stamps.append(stamp[0])
            elif kind == "agent_message":
                answers.append(text.strip())
        if not has_user_events:
            users, stamps = fallback_users, fallback_stamps
        if not answers:
            answers = fallback_answers
        info = catalog.get(sid, {})
        sid = "codex:" + sid
        if not has_human or (require_user and not users) or not activity or sid in seen:
            continue
        seen.add(sid)
        display = info.get("project") or project_display
        result.append(dict(sid=sid, project=project,
                           project_display=display,
                           title=info.get("title") or (users[0][:100] if users else "Codex chat"),
                           title_source="app" if info.get("title") else "message", stamps=sorted(stamps or activity), users=users,
                           answers=answers, tools=len(tool_calls), files=[], path=str(path),
                           latest_activity=max(activity) if activity else max(stamps),
                           actions=list(actions.values())))
    return result


def sessions(conf, day, *, require_user=True):
    result = codex_sessions(conf, day, require_user=require_user)
    try:
        from .cursor_source import sessions as cursor_sessions
    except ImportError:
        from cursor_source import sessions as cursor_sessions
    result.extend(cursor_sessions(conf, day, require_user=require_user))
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["cursor"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    if args.path.suffix not in (".txt", ".jsonl"):
        parser.error("Cursor transcript must be a .txt or .jsonl file")
    try:
        users, answers = read_cursor(args.path)
    except (OSError, ValueError) as error:
        parser.exit(1, "Cannot read Cursor transcript: " + str(error) + "\n")
    print("Undated Cursor transcript, excluded from daily counts")
    for role, blocks in (("User", users), ("Assistant", answers)):
        for number, text in enumerate(blocks, 1):
            print("\n## %s %s\n\n%s" % (role, number, text))
