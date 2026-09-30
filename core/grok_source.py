"""Read-only Grok Bot hooks when transcript files exist on disk."""
from pathlib import Path


def sessions(conf, day, *, require_user=True):
    """Return dated Grok chats when a supported on-disk format appears.

    Grok Bot currently exposes process metadata, not message transcripts, in the
    paths we can read without the app running. This stays empty until a stable
    export format is confirmed.
    """
    _ = (conf, day, require_user)
    roots = [
        Path.home() / "Library/Application Support/Grok Bot",
        Path.home() / ".grokbot",
    ]
    if not any(r.is_dir() for r in roots):
        return []
    return []
