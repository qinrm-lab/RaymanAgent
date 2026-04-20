#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

MAX_LIST_LIMIT = 200
MAX_SHOW_MESSAGES = 400
DEFAULT_HEAD_MESSAGES = 4
DEFAULT_TAIL_MESSAGES = 8
DEFAULT_COMPACT_TOOL_CHARS = 2000
DEFAULT_COMPACT_TEXT_CHARS = 4000


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def normalize_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def normalize_json(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return value
    return {}


def normalize_list(value: Any) -> List[Any]:
    if isinstance(value, list):
        return value
    if value is None:
        return []
    return [value]


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def stable_hash(*parts: Any) -> str:
    material = "||".join(normalize_text(part) for part in parts)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def lexical_score(query: str, text: str) -> float:
    query = normalize_text(query).lower()
    text = normalize_text(text).lower()
    if not query or not text:
        return 0.0
    q_tokens = set(re.findall(r"[A-Za-z0-9_./:-]+", query))
    t_tokens = set(re.findall(r"[A-Za-z0-9_./:-]+", text))
    if not q_tokens or not t_tokens:
        return 0.0
    overlap = len(q_tokens & t_tokens)
    if overlap <= 0:
        return 0.0
    score = overlap / max(1, len(q_tokens | t_tokens))
    if query in text:
        score += 0.25
    return round(score, 6)


class SharedSessionPaths:
    def __init__(self, workspace_root: str) -> None:
        self.workspace_root = Path(workspace_root).resolve()
        self.state_root = self.workspace_root / ".Rayman" / "state" / "shared_sessions"
        self.runtime_root = self.workspace_root / ".Rayman" / "runtime" / "shared_sessions"
        self.db_path = self.state_root / "shared_sessions.sqlite3"


class SharedSessionStore:
    def __init__(self, paths: SharedSessionPaths) -> None:
        self.paths = paths
        ensure_dir(paths.state_root)
        ensure_dir(paths.runtime_root)
        self.conn = sqlite3.connect(str(paths.db_path), timeout=60.0)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA busy_timeout=60000")
        self.fts5_available = False
        self.ensure_schema()

    def close(self) -> None:
        self.conn.close()

    def ensure_schema(self) -> None:
        self.conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS shared_sessions (
                session_id TEXT PRIMARY KEY,
                schema TEXT NOT NULL DEFAULT 'rayman.shared_session.v1',
                workspace_root TEXT NOT NULL,
                workspace_hash TEXT NOT NULL,
                task_slug TEXT NOT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'active',
                scope TEXT NOT NULL DEFAULT 'same_machine_single_user',
                canonical_kind TEXT NOT NULL DEFAULT 'workspace_task',
                source_of_truth TEXT NOT NULL DEFAULT 'rayman',
                summary_text TEXT NOT NULL DEFAULT '',
                resume_summary_text TEXT NOT NULL DEFAULT '',
                recap_text TEXT NOT NULL DEFAULT '',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                latest_checkpoint_id TEXT NOT NULL DEFAULT '',
                last_message_at TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_shared_sessions_workspace_task
                ON shared_sessions(workspace_hash, task_slug);
            CREATE INDEX IF NOT EXISTS idx_shared_sessions_updated_at
                ON shared_sessions(updated_at DESC);

            CREATE TABLE IF NOT EXISTS shared_session_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                schema TEXT NOT NULL DEFAULT 'rayman.shared_session_message.v1',
                message_id TEXT NOT NULL UNIQUE,
                turn_index INTEGER NOT NULL DEFAULT 0,
                role TEXT NOT NULL,
                author_kind TEXT NOT NULL DEFAULT '',
                author_name TEXT NOT NULL DEFAULT '',
                content_text TEXT NOT NULL DEFAULT '',
                resume_text TEXT NOT NULL DEFAULT '',
                recap_text TEXT NOT NULL DEFAULT '',
                source_kind TEXT NOT NULL DEFAULT 'canonical',
                vendor_name TEXT NOT NULL DEFAULT '',
                vendor_session_id TEXT NOT NULL DEFAULT '',
                queue_state TEXT NOT NULL DEFAULT 'active',
                protected INTEGER NOT NULL DEFAULT 0,
                compacted INTEGER NOT NULL DEFAULT 0,
                artifact_json TEXT NOT NULL DEFAULT '{}',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_shared_session_messages_session_turn
                ON shared_session_messages(session_id, turn_index, id);
            CREATE INDEX IF NOT EXISTS idx_shared_session_messages_updated_at
                ON shared_session_messages(updated_at DESC);

            CREATE TABLE IF NOT EXISTS shared_session_links (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                vendor_name TEXT NOT NULL,
                vendor_session_id TEXT NOT NULL,
                adapter_kind TEXT NOT NULL DEFAULT '',
                continuity_mode TEXT NOT NULL DEFAULT 'transcript_bridge',
                native_resume_supported INTEGER NOT NULL DEFAULT 0,
                workspace_root TEXT NOT NULL DEFAULT '',
                state_json TEXT NOT NULL DEFAULT '{}',
                status TEXT NOT NULL DEFAULT 'linked',
                last_seen_at TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(session_id, vendor_name, vendor_session_id)
            );
            CREATE INDEX IF NOT EXISTS idx_shared_session_links_session
                ON shared_session_links(session_id, vendor_name, updated_at DESC);

            CREATE TABLE IF NOT EXISTS shared_session_locks (
                session_id TEXT PRIMARY KEY,
                lock_id TEXT NOT NULL,
                owner_id TEXT NOT NULL,
                owner_label TEXT NOT NULL DEFAULT '',
                queued_count INTEGER NOT NULL DEFAULT 0,
                queue_json TEXT NOT NULL DEFAULT '[]',
                acquired_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS shared_session_checkpoints (
                checkpoint_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                checkpoint_kind TEXT NOT NULL,
                turn_index INTEGER NOT NULL DEFAULT 0,
                destructive INTEGER NOT NULL DEFAULT 0,
                session_slug TEXT NOT NULL DEFAULT '',
                session_kind TEXT NOT NULL DEFAULT '',
                handover_path TEXT NOT NULL DEFAULT '',
                patch_path TEXT NOT NULL DEFAULT '',
                meta_path TEXT NOT NULL DEFAULT '',
                stash_oid TEXT NOT NULL DEFAULT '',
                worktree_path TEXT NOT NULL DEFAULT '',
                branch TEXT NOT NULL DEFAULT '',
                summary_text TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'active',
                restored_at TEXT NOT NULL DEFAULT '',
                restored_by TEXT NOT NULL DEFAULT '',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_shared_session_checkpoints_session
                ON shared_session_checkpoints(session_id, created_at DESC);
            """
        )
        self.conn.commit()
        self._ensure_fts()

    def _ensure_fts(self) -> None:
        try:
            self.conn.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS shared_session_messages_fts
                USING fts5(
                    session_id,
                    message_id,
                    role,
                    author_name,
                    content_text,
                    resume_text,
                    recap_text,
                    source_kind,
                    vendor_name,
                    vendor_session_id,
                    artifact_text
                );
                """
            )
            self.fts5_available = True
        except sqlite3.OperationalError:
            self.fts5_available = False
            return

        rows = self.conn.execute("SELECT * FROM shared_session_messages").fetchall()
        for row in rows:
            self._refresh_message_fts(dict(row))
        self.conn.commit()

    def scalar(self, sql: str, params: Sequence[Any] = ()) -> int:
        row = self.conn.execute(sql, params).fetchone()
        if row is None:
            return 0
        return int(row[0] or 0)

    def _artifact_text(self, artifact_json: str) -> str:
        try:
            value = json.loads(artifact_json or "{}")
        except Exception:
            value = {}
        tokens: List[str] = []
        if isinstance(value, dict):
            for raw in value.values():
                if isinstance(raw, list):
                    tokens.extend(normalize_text(item) for item in raw)
                else:
                    tokens.append(normalize_text(raw))
        return " ".join(token for token in tokens if token)

    def _refresh_message_fts(self, row: Dict[str, Any]) -> None:
        if not self.fts5_available:
            return
        message_id = normalize_text(row.get("message_id"))
        artifact_text = self._artifact_text(normalize_text(row.get("artifact_json")))
        self.conn.execute("DELETE FROM shared_session_messages_fts WHERE message_id = ?", (message_id,))
        self.conn.execute(
            """
            INSERT INTO shared_session_messages_fts (
                session_id, message_id, role, author_name, content_text, resume_text,
                recap_text, source_kind, vendor_name, vendor_session_id, artifact_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                normalize_text(row.get("session_id")),
                message_id,
                normalize_text(row.get("role")),
                normalize_text(row.get("author_name")),
                normalize_text(row.get("content_text")),
                normalize_text(row.get("resume_text")),
                normalize_text(row.get("recap_text")),
                normalize_text(row.get("source_kind")),
                normalize_text(row.get("vendor_name")),
                normalize_text(row.get("vendor_session_id")),
                artifact_text,
            ),
        )

    def write_status(
        self,
        *,
        enabled: bool,
        config: Dict[str, Any],
        message: str,
    ) -> Dict[str, Any]:
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "enabled": bool(enabled),
            "workspace_root": str(self.paths.workspace_root),
            "db_path": str(self.paths.db_path),
            "fts5_available": bool(self.fts5_available),
            "config": config,
            "counts": {
                "shared_sessions": self.scalar("SELECT COUNT(*) FROM shared_sessions"),
                "shared_session_messages": self.scalar("SELECT COUNT(*) FROM shared_session_messages"),
                "shared_session_links": self.scalar("SELECT COUNT(*) FROM shared_session_links"),
                "shared_session_locks": self.scalar("SELECT COUNT(*) FROM shared_session_locks"),
                "shared_session_checkpoints": self.scalar("SELECT COUNT(*) FROM shared_session_checkpoints"),
                "queued_messages": self.scalar("SELECT COUNT(*) FROM shared_session_messages WHERE queue_state = 'queued'"),
            },
            "message": message,
            "generated_at": utc_now(),
        }

    def _existing_session(self, session_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM shared_sessions WHERE session_id = ?", (session_id,)).fetchone()

    def _max_turn(self, session_id: str) -> int:
        row = self.conn.execute(
            "SELECT MAX(turn_index) FROM shared_session_messages WHERE session_id = ?",
            (session_id,),
        ).fetchone()
        if row is None or row[0] is None:
            return 0
        return int(row[0])

    def _refresh_session_summary(self, session_id: str) -> None:
        session = self._existing_session(session_id)
        if session is None:
            return

        latest_message = self.conn.execute(
            """
            SELECT *
            FROM shared_session_messages
            WHERE session_id = ? AND queue_state <> 'queued'
            ORDER BY turn_index DESC, id DESC
            LIMIT 1
            """,
            (session_id,),
        ).fetchone()
        latest_checkpoint = self.conn.execute(
            """
            SELECT checkpoint_id
            FROM shared_session_checkpoints
            WHERE session_id = ?
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (session_id,),
        ).fetchone()

        summary_text = normalize_text(session["summary_text"])
        recap_text = normalize_text(session["recap_text"])
        resume_summary = normalize_text(session["resume_summary_text"])
        last_message_at = normalize_text(session["last_message_at"])
        if latest_message is not None:
            latest_content = (
                normalize_text(latest_message["recap_text"])
                or normalize_text(latest_message["resume_text"])
                or normalize_text(latest_message["content_text"])
            )
            if latest_content:
                summary_text = latest_content[:600]
            if normalize_text(latest_message["recap_text"]):
                recap_text = normalize_text(latest_message["recap_text"])[:1200]
            if normalize_text(latest_message["resume_text"]):
                resume_summary = normalize_text(latest_message["resume_text"])[:1200]
            last_message_at = normalize_text(latest_message["updated_at"]) or normalize_text(latest_message["created_at"])

        self.conn.execute(
            """
            UPDATE shared_sessions
            SET summary_text = ?,
                recap_text = ?,
                resume_summary_text = ?,
                latest_checkpoint_id = ?,
                last_message_at = ?,
                updated_at = ?
            WHERE session_id = ?
            """,
            (
                summary_text,
                recap_text,
                resume_summary,
                normalize_text(latest_checkpoint["checkpoint_id"]) if latest_checkpoint is not None else normalize_text(session["latest_checkpoint_id"]),
                last_message_at,
                utc_now(),
                session_id,
            ),
        )

    def upsert_session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        if not session_id:
            raise ValueError("session_id is required")

        now = utc_now()
        existing = self._existing_session(session_id)
        created_at = normalize_text(payload.get("created_at")) or (normalize_text(existing["created_at"]) if existing is not None else now)
        updated_at = normalize_text(payload.get("updated_at")) or now
        metadata = normalize_json(payload.get("metadata_json") or payload.get("metadata") or {})
        self.conn.execute(
            """
            INSERT INTO shared_sessions (
                session_id, schema, workspace_root, workspace_hash, task_slug, display_name,
                status, scope, canonical_kind, source_of_truth, summary_text, resume_summary_text,
                recap_text, metadata_json, latest_checkpoint_id, last_message_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                workspace_root=excluded.workspace_root,
                workspace_hash=excluded.workspace_hash,
                task_slug=excluded.task_slug,
                display_name=excluded.display_name,
                status=excluded.status,
                scope=excluded.scope,
                canonical_kind=excluded.canonical_kind,
                source_of_truth=excluded.source_of_truth,
                summary_text=CASE
                    WHEN excluded.summary_text <> '' THEN excluded.summary_text
                    ELSE shared_sessions.summary_text
                END,
                resume_summary_text=CASE
                    WHEN excluded.resume_summary_text <> '' THEN excluded.resume_summary_text
                    ELSE shared_sessions.resume_summary_text
                END,
                recap_text=CASE
                    WHEN excluded.recap_text <> '' THEN excluded.recap_text
                    ELSE shared_sessions.recap_text
                END,
                metadata_json=excluded.metadata_json,
                latest_checkpoint_id=CASE
                    WHEN excluded.latest_checkpoint_id <> '' THEN excluded.latest_checkpoint_id
                    ELSE shared_sessions.latest_checkpoint_id
                END,
                last_message_at=CASE
                    WHEN excluded.last_message_at <> '' THEN excluded.last_message_at
                    ELSE shared_sessions.last_message_at
                END,
                updated_at=excluded.updated_at
            """,
            (
                session_id,
                "rayman.shared_session.v1",
                normalize_text(payload.get("workspace_root")) or str(self.paths.workspace_root),
                normalize_text(payload.get("workspace_hash")),
                normalize_text(payload.get("task_slug")),
                normalize_text(payload.get("display_name")) or normalize_text(payload.get("task_slug")),
                normalize_text(payload.get("status")) or "active",
                normalize_text(payload.get("scope")) or "same_machine_single_user",
                normalize_text(payload.get("canonical_kind")) or "workspace_task",
                normalize_text(payload.get("source_of_truth")) or "rayman",
                normalize_text(payload.get("summary_text")),
                normalize_text(payload.get("resume_summary_text")),
                normalize_text(payload.get("recap_text")),
                json_dumps(metadata),
                normalize_text(payload.get("latest_checkpoint_id")),
                normalize_text(payload.get("last_message_at")),
                created_at,
                updated_at,
            ),
        )
        self.conn.commit()
        row = self.conn.execute("SELECT * FROM shared_sessions WHERE session_id = ?", (session_id,)).fetchone()
        if row is None:
            raise RuntimeError("failed to upsert shared session")
        return {
            "schema": "rayman.shared_session.v1",
            "success": True,
            "created": existing is None,
            "session": self._session_row_to_dict(dict(row)),
        }

    def _session_row_to_dict(self, row: Dict[str, Any]) -> Dict[str, Any]:
        metadata = {}
        try:
            metadata = json.loads(row.get("metadata_json") or "{}")
        except Exception:
            metadata = {}
        return {
            "session_id": normalize_text(row.get("session_id")),
            "workspace_root": normalize_text(row.get("workspace_root")),
            "workspace_hash": normalize_text(row.get("workspace_hash")),
            "task_slug": normalize_text(row.get("task_slug")),
            "display_name": normalize_text(row.get("display_name")),
            "status": normalize_text(row.get("status")),
            "scope": normalize_text(row.get("scope")),
            "canonical_kind": normalize_text(row.get("canonical_kind")),
            "source_of_truth": normalize_text(row.get("source_of_truth")),
            "summary_text": normalize_text(row.get("summary_text")),
            "resume_summary_text": normalize_text(row.get("resume_summary_text")),
            "recap_text": normalize_text(row.get("recap_text")),
            "metadata": metadata,
            "latest_checkpoint_id": normalize_text(row.get("latest_checkpoint_id")),
            "last_message_at": normalize_text(row.get("last_message_at")),
            "created_at": normalize_text(row.get("created_at")),
            "updated_at": normalize_text(row.get("updated_at")),
        }

    def list_sessions(self, *, limit: int = 50) -> Dict[str, Any]:
        limit = max(1, min(MAX_LIST_LIMIT, int(limit)))
        rows = self.conn.execute(
            """
            SELECT *
            FROM shared_sessions
            ORDER BY updated_at DESC, created_at DESC, session_id ASC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        sessions = [self._session_row_to_dict(dict(row)) for row in rows]
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "count": len(sessions),
            "sessions": sessions,
        }

    def _message_row_to_dict(self, row: Dict[str, Any]) -> Dict[str, Any]:
        artifact = {}
        metadata = {}
        try:
            artifact = json.loads(row.get("artifact_json") or "{}")
        except Exception:
            artifact = {}
        try:
            metadata = json.loads(row.get("metadata_json") or "{}")
        except Exception:
            metadata = {}
        return {
            "schema": "rayman.shared_session_message.v1",
            "message_id": normalize_text(row.get("message_id")),
            "session_id": normalize_text(row.get("session_id")),
            "turn_index": int(row.get("turn_index") or 0),
            "role": normalize_text(row.get("role")),
            "author_kind": normalize_text(row.get("author_kind")),
            "author_name": normalize_text(row.get("author_name")),
            "content_text": normalize_text(row.get("content_text")),
            "resume_text": normalize_text(row.get("resume_text")),
            "recap_text": normalize_text(row.get("recap_text")),
            "source_kind": normalize_text(row.get("source_kind")),
            "vendor_name": normalize_text(row.get("vendor_name")),
            "vendor_session_id": normalize_text(row.get("vendor_session_id")),
            "queue_state": normalize_text(row.get("queue_state")),
            "protected": bool(row.get("protected")),
            "compacted": bool(row.get("compacted")),
            "artifact": artifact,
            "metadata": metadata,
            "created_at": normalize_text(row.get("created_at")),
            "updated_at": normalize_text(row.get("updated_at")),
        }

    def append_message(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        if not session_id:
            raise ValueError("session_id is required")
        if self._existing_session(session_id) is None:
            raise ValueError(f"shared session not found: {session_id}")

        now = utc_now()
        turn_index = int(payload.get("turn_index") or 0)
        if turn_index <= 0:
            turn_index = self._max_turn(session_id) + 1
        role = normalize_text(payload.get("role")) or "assistant"
        message_id = normalize_text(payload.get("message_id")) or f"msg-{uuid.uuid4().hex}"
        metadata = normalize_json(payload.get("metadata_json") or payload.get("metadata") or {})
        artifact = normalize_json(payload.get("artifact_json") or payload.get("artifact") or {})
        protected = bool(payload.get("protected"))
        if role == "system" and turn_index <= DEFAULT_HEAD_MESSAGES:
            protected = True

        self.conn.execute(
            """
            INSERT INTO shared_session_messages (
                session_id, schema, message_id, turn_index, role, author_kind, author_name,
                content_text, resume_text, recap_text, source_kind, vendor_name, vendor_session_id,
                queue_state, protected, compacted, artifact_json, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                turn_index=excluded.turn_index,
                role=excluded.role,
                author_kind=excluded.author_kind,
                author_name=excluded.author_name,
                content_text=excluded.content_text,
                resume_text=excluded.resume_text,
                recap_text=excluded.recap_text,
                source_kind=excluded.source_kind,
                vendor_name=excluded.vendor_name,
                vendor_session_id=excluded.vendor_session_id,
                queue_state=excluded.queue_state,
                protected=excluded.protected,
                compacted=excluded.compacted,
                artifact_json=excluded.artifact_json,
                metadata_json=excluded.metadata_json,
                updated_at=excluded.updated_at
            """,
            (
                session_id,
                "rayman.shared_session_message.v1",
                message_id,
                turn_index,
                role,
                normalize_text(payload.get("author_kind")) or "rayman",
                normalize_text(payload.get("author_name")),
                normalize_text(payload.get("content_text")),
                normalize_text(payload.get("resume_text")),
                normalize_text(payload.get("recap_text")),
                normalize_text(payload.get("source_kind")) or "canonical",
                normalize_text(payload.get("vendor_name")),
                normalize_text(payload.get("vendor_session_id")),
                normalize_text(payload.get("queue_state")) or "active",
                1 if protected else 0,
                1 if bool(payload.get("compacted")) else 0,
                json_dumps(artifact),
                json_dumps(metadata),
                normalize_text(payload.get("created_at")) or now,
                normalize_text(payload.get("updated_at")) or now,
            ),
        )
        row = self.conn.execute("SELECT * FROM shared_session_messages WHERE message_id = ?", (message_id,)).fetchone()
        if row is None:
            raise RuntimeError("failed to append shared session message")
        self._refresh_message_fts(dict(row))
        self._refresh_session_summary(session_id)
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_message.v1",
            "success": True,
            "stored": True,
            "message": self._message_row_to_dict(dict(row)),
        }

    def show_session(self, *, session_id: str, message_limit: int = 80) -> Dict[str, Any]:
        session_row = self._existing_session(session_id)
        if session_row is None:
            raise ValueError(f"shared session not found: {session_id}")
        message_limit = max(0, min(MAX_SHOW_MESSAGES, int(message_limit)))
        messages = []
        if message_limit > 0:
            message_rows = self.conn.execute(
                """
                SELECT *
                FROM shared_session_messages
                WHERE session_id = ?
                ORDER BY turn_index DESC, id DESC
                LIMIT ?
                """,
                (session_id, message_limit),
            ).fetchall()
            messages = [self._message_row_to_dict(dict(row)) for row in reversed(message_rows)]

        link_rows = self.conn.execute(
            """
            SELECT *
            FROM shared_session_links
            WHERE session_id = ?
            ORDER BY updated_at DESC, id DESC
            """,
            (session_id,),
        ).fetchall()
        links: List[Dict[str, Any]] = []
        for row in link_rows:
            state = {}
            try:
                state = json.loads(row["state_json"] or "{}")
            except Exception:
                state = {}
            links.append(
                {
                    "vendor_name": normalize_text(row["vendor_name"]),
                    "vendor_session_id": normalize_text(row["vendor_session_id"]),
                    "adapter_kind": normalize_text(row["adapter_kind"]),
                    "continuity_mode": normalize_text(row["continuity_mode"]),
                    "native_resume_supported": bool(row["native_resume_supported"]),
                    "workspace_root": normalize_text(row["workspace_root"]),
                    "status": normalize_text(row["status"]),
                    "last_seen_at": normalize_text(row["last_seen_at"]),
                    "state": state,
                    "created_at": normalize_text(row["created_at"]),
                    "updated_at": normalize_text(row["updated_at"]),
                }
            )

        checkpoint_rows = self.conn.execute(
            """
            SELECT *
            FROM shared_session_checkpoints
            WHERE session_id = ?
            ORDER BY created_at DESC, checkpoint_id DESC
            """,
            (session_id,),
        ).fetchall()
        checkpoints: List[Dict[str, Any]] = []
        for row in checkpoint_rows:
            metadata = {}
            try:
                metadata = json.loads(row["metadata_json"] or "{}")
            except Exception:
                metadata = {}
            checkpoints.append(
                {
                    "checkpoint_id": normalize_text(row["checkpoint_id"]),
                    "checkpoint_kind": normalize_text(row["checkpoint_kind"]),
                    "turn_index": int(row["turn_index"] or 0),
                    "destructive": bool(row["destructive"]),
                    "session_slug": normalize_text(row["session_slug"]),
                    "session_kind": normalize_text(row["session_kind"]),
                    "handover_path": normalize_text(row["handover_path"]),
                    "patch_path": normalize_text(row["patch_path"]),
                    "meta_path": normalize_text(row["meta_path"]),
                    "stash_oid": normalize_text(row["stash_oid"]),
                    "worktree_path": normalize_text(row["worktree_path"]),
                    "branch": normalize_text(row["branch"]),
                    "summary_text": normalize_text(row["summary_text"]),
                    "status": normalize_text(row["status"]),
                    "restored_at": normalize_text(row["restored_at"]),
                    "restored_by": normalize_text(row["restored_by"]),
                    "metadata": metadata,
                    "created_at": normalize_text(row["created_at"]),
                    "updated_at": normalize_text(row["updated_at"]),
                }
            )

        lock_row = self.conn.execute(
            "SELECT * FROM shared_session_locks WHERE session_id = ?",
            (session_id,),
        ).fetchone()
        lock_info = None
        if lock_row is not None:
            queue = []
            try:
                queue = json.loads(lock_row["queue_json"] or "[]")
            except Exception:
                queue = []
            lock_info = {
                "lock_id": normalize_text(lock_row["lock_id"]),
                "owner_id": normalize_text(lock_row["owner_id"]),
                "owner_label": normalize_text(lock_row["owner_label"]),
                "queued_count": int(lock_row["queued_count"] or 0),
                "queue": queue,
                "acquired_at": normalize_text(lock_row["acquired_at"]),
                "expires_at": normalize_text(lock_row["expires_at"]),
                "updated_at": normalize_text(lock_row["updated_at"]),
            }

        queued_rows = self.conn.execute(
            """
            SELECT *
            FROM shared_session_messages
            WHERE session_id = ? AND queue_state = 'queued'
            ORDER BY turn_index ASC, id ASC
            """,
            (session_id,),
        ).fetchall()
        queued_messages = [self._message_row_to_dict(dict(row)) for row in queued_rows]

        return {
            "schema": "rayman.shared_session.v1",
            "success": True,
            "session": self._session_row_to_dict(dict(session_row)),
            "messages": messages,
            "links": links,
            "checkpoints": checkpoints,
            "lock": lock_info,
            "queued_messages": queued_messages,
        }

    def link_session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        vendor_name = normalize_text(payload.get("vendor_name"))
        vendor_session_id = normalize_text(payload.get("vendor_session_id"))
        if not session_id or not vendor_name or not vendor_session_id:
            raise ValueError("session_id, vendor_name, and vendor_session_id are required")
        if self._existing_session(session_id) is None:
            raise ValueError(f"shared session not found: {session_id}")

        now = utc_now()
        state = normalize_json(payload.get("state_json") or payload.get("state") or {})
        self.conn.execute(
            """
            INSERT INTO shared_session_links (
                session_id, vendor_name, vendor_session_id, adapter_kind, continuity_mode,
                native_resume_supported, workspace_root, state_json, status, last_seen_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, vendor_name, vendor_session_id) DO UPDATE SET
                adapter_kind=excluded.adapter_kind,
                continuity_mode=excluded.continuity_mode,
                native_resume_supported=excluded.native_resume_supported,
                workspace_root=excluded.workspace_root,
                state_json=excluded.state_json,
                status=excluded.status,
                last_seen_at=excluded.last_seen_at,
                updated_at=excluded.updated_at
            """,
            (
                session_id,
                vendor_name,
                vendor_session_id,
                normalize_text(payload.get("adapter_kind")),
                normalize_text(payload.get("continuity_mode")) or "transcript_bridge",
                1 if bool(payload.get("native_resume_supported")) else 0,
                normalize_text(payload.get("workspace_root")) or str(self.paths.workspace_root),
                json_dumps(state),
                normalize_text(payload.get("status")) or "linked",
                normalize_text(payload.get("last_seen_at")) or now,
                normalize_text(payload.get("created_at")) or now,
                normalize_text(payload.get("updated_at")) or now,
            ),
        )
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_sync.v1",
            "success": True,
            "linked": True,
            "session_id": session_id,
            "vendor_name": vendor_name,
            "vendor_session_id": vendor_session_id,
        }

    def unlink_session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        vendor_name = normalize_text(payload.get("vendor_name"))
        vendor_session_id = normalize_text(payload.get("vendor_session_id"))
        if not session_id:
            raise ValueError("session_id is required")

        sql = "DELETE FROM shared_session_links WHERE session_id = ?"
        params: List[Any] = [session_id]
        if vendor_name:
            sql += " AND vendor_name = ?"
            params.append(vendor_name)
        if vendor_session_id:
            sql += " AND vendor_session_id = ?"
            params.append(vendor_session_id)
        deleted = self.conn.execute(sql, params).rowcount
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_sync.v1",
            "success": True,
            "deleted": int(deleted),
            "session_id": session_id,
            "vendor_name": vendor_name,
            "vendor_session_id": vendor_session_id,
        }

    def acquire_lock(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        owner_id = normalize_text(payload.get("owner_id"))
        owner_label = normalize_text(payload.get("owner_label")) or owner_id
        timeout_seconds = max(1, int(payload.get("timeout_seconds") or 300))
        if not session_id or not owner_id:
            raise ValueError("session_id and owner_id are required")

        now_dt = datetime.now(timezone.utc)
        now = now_dt.replace(microsecond=0).isoformat()
        expires_at = (now_dt + timedelta(seconds=timeout_seconds)).replace(microsecond=0).isoformat()
        existing = self.conn.execute("SELECT * FROM shared_session_locks WHERE session_id = ?", (session_id,)).fetchone()
        stale_recovered = False

        if existing is not None:
            existing_owner_id = normalize_text(existing["owner_id"])
            existing_expires = normalize_text(existing["expires_at"])
            stale = False
            try:
                stale = datetime.fromisoformat(existing_expires) <= now_dt
            except Exception:
                stale = True
            stale_recovered = stale

            if existing_owner_id and existing_owner_id != owner_id and not stale:
                queue_item = payload.get("queue_item")
                queue = []
                try:
                    queue = json.loads(existing["queue_json"] or "[]")
                except Exception:
                    queue = []
                queued = False
                if queue_item is not None:
                    queue.append(queue_item)
                    self.conn.execute(
                        """
                        UPDATE shared_session_locks
                        SET queued_count = ?, queue_json = ?, updated_at = ?
                        WHERE session_id = ?
                        """,
                        (len(queue), json_dumps(queue), now, session_id),
                    )
                    self.conn.commit()
                    queued = True
                return {
                    "schema": "rayman.shared_session_status.v1",
                    "success": True,
                    "acquired": False,
                    "queued": queued,
                    "stale_recovered": False,
                    "session_id": session_id,
                    "owner_id": existing_owner_id,
                    "lock_id": normalize_text(existing["lock_id"]),
                    "expires_at": existing_expires,
                    "queued_count": len(queue),
                }

        lock_id = f"lock-{uuid.uuid4().hex}"
        self.conn.execute(
            """
            INSERT INTO shared_session_locks (
                session_id, lock_id, owner_id, owner_label, queued_count, queue_json,
                acquired_at, expires_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                lock_id=excluded.lock_id,
                owner_id=excluded.owner_id,
                owner_label=excluded.owner_label,
                queued_count=excluded.queued_count,
                queue_json=excluded.queue_json,
                acquired_at=excluded.acquired_at,
                expires_at=excluded.expires_at,
                updated_at=excluded.updated_at
            """,
            (
                session_id,
                lock_id,
                owner_id,
                owner_label,
                0,
                "[]",
                now,
                expires_at,
                now,
            ),
        )
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "acquired": True,
            "queued": False,
            "stale_recovered": stale_recovered,
            "session_id": session_id,
            "owner_id": owner_id,
            "owner_label": owner_label,
            "lock_id": lock_id,
            "expires_at": expires_at,
            "queued_count": 0,
        }

    def release_lock(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        owner_id = normalize_text(payload.get("owner_id"))
        force = bool(payload.get("force"))
        if not session_id:
            raise ValueError("session_id is required")

        existing = self.conn.execute("SELECT * FROM shared_session_locks WHERE session_id = ?", (session_id,)).fetchone()
        if existing is None:
            return {
                "schema": "rayman.shared_session_status.v1",
                "success": True,
                "released": False,
                "reason": "lock_missing",
                "session_id": session_id,
            }

        existing_owner_id = normalize_text(existing["owner_id"])
        if existing_owner_id and owner_id and existing_owner_id != owner_id and not force:
            return {
                "schema": "rayman.shared_session_status.v1",
                "success": True,
                "released": False,
                "reason": "owner_mismatch",
                "session_id": session_id,
                "owner_id": existing_owner_id,
            }

        self.conn.execute("DELETE FROM shared_session_locks WHERE session_id = ?", (session_id,))
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "released": True,
            "reason": "released",
            "session_id": session_id,
            "owner_id": existing_owner_id,
        }

    def save_checkpoint(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        checkpoint_id = normalize_text(payload.get("checkpoint_id"))
        if not session_id or not checkpoint_id:
            raise ValueError("session_id and checkpoint_id are required")
        if self._existing_session(session_id) is None:
            raise ValueError(f"shared session not found: {session_id}")

        now = utc_now()
        metadata = normalize_json(payload.get("metadata_json") or payload.get("metadata") or {})
        self.conn.execute(
            """
            INSERT INTO shared_session_checkpoints (
                checkpoint_id, session_id, checkpoint_kind, turn_index, destructive,
                session_slug, session_kind, handover_path, patch_path, meta_path, stash_oid,
                worktree_path, branch, summary_text, status, restored_at, restored_by,
                metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(checkpoint_id) DO UPDATE SET
                checkpoint_kind=excluded.checkpoint_kind,
                turn_index=excluded.turn_index,
                destructive=excluded.destructive,
                session_slug=excluded.session_slug,
                session_kind=excluded.session_kind,
                handover_path=excluded.handover_path,
                patch_path=excluded.patch_path,
                meta_path=excluded.meta_path,
                stash_oid=excluded.stash_oid,
                worktree_path=excluded.worktree_path,
                branch=excluded.branch,
                summary_text=excluded.summary_text,
                status=excluded.status,
                restored_at=excluded.restored_at,
                restored_by=excluded.restored_by,
                metadata_json=excluded.metadata_json,
                updated_at=excluded.updated_at
            """,
            (
                checkpoint_id,
                session_id,
                normalize_text(payload.get("checkpoint_kind")) or "checkpoint",
                int(payload.get("turn_index") or 0),
                1 if bool(payload.get("destructive")) else 0,
                normalize_text(payload.get("session_slug")),
                normalize_text(payload.get("session_kind")),
                normalize_text(payload.get("handover_path")),
                normalize_text(payload.get("patch_path")),
                normalize_text(payload.get("meta_path")),
                normalize_text(payload.get("stash_oid")),
                normalize_text(payload.get("worktree_path")),
                normalize_text(payload.get("branch")),
                normalize_text(payload.get("summary_text")),
                normalize_text(payload.get("status")) or "active",
                normalize_text(payload.get("restored_at")),
                normalize_text(payload.get("restored_by")),
                json_dumps(metadata),
                normalize_text(payload.get("created_at")) or now,
                normalize_text(payload.get("updated_at")) or now,
            ),
        )
        self.conn.execute(
            "UPDATE shared_sessions SET latest_checkpoint_id = ?, updated_at = ? WHERE session_id = ?",
            (checkpoint_id, now, session_id),
        )
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "checkpoint_id": checkpoint_id,
            "session_id": session_id,
        }

    def restore_checkpoint(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        checkpoint_id = normalize_text(payload.get("checkpoint_id"))
        restored_by = normalize_text(payload.get("restored_by"))
        if not session_id:
            raise ValueError("session_id is required")

        if not checkpoint_id:
            row = self.conn.execute(
                """
                SELECT checkpoint_id
                FROM shared_session_checkpoints
                WHERE session_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (session_id,),
            ).fetchone()
            checkpoint_id = normalize_text(row["checkpoint_id"]) if row is not None else ""
        if not checkpoint_id:
            raise ValueError(f"checkpoint not found for session: {session_id}")

        now = utc_now()
        updated = self.conn.execute(
            """
            UPDATE shared_session_checkpoints
            SET status = 'restored',
                restored_at = ?,
                restored_by = ?,
                updated_at = ?
            WHERE checkpoint_id = ? AND session_id = ?
            """,
            (now, restored_by, now, checkpoint_id, session_id),
        ).rowcount
        if updated <= 0:
            raise ValueError(f"checkpoint not found: {checkpoint_id}")
        self.conn.execute(
            "UPDATE shared_sessions SET status = 'restored', latest_checkpoint_id = ?, updated_at = ? WHERE session_id = ?",
            (checkpoint_id, now, session_id),
        )
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "restored": True,
            "session_id": session_id,
            "checkpoint_id": checkpoint_id,
            "restored_at": now,
        }

    def compact_session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        if not session_id:
            raise ValueError("session_id is required")

        head_count = max(0, int(payload.get("head_count") or DEFAULT_HEAD_MESSAGES))
        tail_count = max(0, int(payload.get("tail_count") or DEFAULT_TAIL_MESSAGES))
        tool_chars = max(200, int(payload.get("tool_chars") or DEFAULT_COMPACT_TOOL_CHARS))
        text_chars = max(400, int(payload.get("text_chars") or DEFAULT_COMPACT_TEXT_CHARS))

        rows = [dict(row) for row in self.conn.execute(
            "SELECT * FROM shared_session_messages WHERE session_id = ? ORDER BY turn_index ASC, id ASC",
            (session_id,),
        ).fetchall()]
        if not rows:
            return {
                "schema": "rayman.shared_session_status.v1",
                "success": True,
                "session_id": session_id,
                "compacted": 0,
            }

        protected_ids = set()
        for row in rows[:head_count]:
            protected_ids.add(normalize_text(row["message_id"]))
        for row in rows[-tail_count:]:
            protected_ids.add(normalize_text(row["message_id"]))

        first_exchange_count = 0
        for row in rows:
            role = normalize_text(row["role"])
            if role in {"user", "assistant"} and first_exchange_count < 2:
                protected_ids.add(normalize_text(row["message_id"]))
                first_exchange_count += 1

        compacted = 0
        updated_at = utc_now()
        for row in rows:
            message_id = normalize_text(row["message_id"])
            if message_id in protected_ids or bool(row.get("protected")):
                continue
            content = normalize_text(row.get("content_text"))
            if not content:
                continue
            role = normalize_text(row.get("role"))
            over_limit = len(content) >= (tool_chars if role == "tool" else text_chars)
            if not over_limit:
                continue
            summary_prefix = f"[compacted:{role}] "
            summary = content[: min(480, len(content))].replace("\r", " ").replace("\n", " ").strip()
            summary = re.sub(r"\s+", " ", summary)
            if len(content) > 480:
                summary += f" ... ({len(content)} chars)"
            resume_text = summary_prefix + summary
            self.conn.execute(
                """
                UPDATE shared_session_messages
                SET resume_text = ?,
                    recap_text = CASE WHEN recap_text = '' THEN ? ELSE recap_text END,
                    compacted = 1,
                    updated_at = ?
                WHERE message_id = ?
                """,
                (resume_text, resume_text, updated_at, message_id),
            )
            compacted += 1

        if compacted > 0:
            self._refresh_session_summary(session_id)
            refreshed_rows = self.conn.execute(
                "SELECT * FROM shared_session_messages WHERE session_id = ? AND compacted = 1",
                (session_id,),
            ).fetchall()
            for row in refreshed_rows:
                self._refresh_message_fts(dict(row))
        self.conn.commit()
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "session_id": session_id,
            "compacted": compacted,
            "head_count": head_count,
            "tail_count": tail_count,
        }

    def continue_session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        session_id = normalize_text(payload.get("session_id"))
        if not session_id:
            raise ValueError("session_id is required")
        compact_requested = bool(payload.get("compact"))
        if compact_requested:
            self.compact_session({"session_id": session_id})

        show = self.show_session(session_id=session_id, message_limit=int(payload.get("message_limit") or 80))
        session = show["session"]
        messages = show["messages"]
        protected_head = []
        recent_tail = []
        queued_messages = show["queued_messages"]
        head_limit = max(0, int(payload.get("head_count") or DEFAULT_HEAD_MESSAGES))
        tail_limit = max(0, int(payload.get("tail_count") or DEFAULT_TAIL_MESSAGES))
        for item in messages[:head_limit]:
            protected_head.append(item)
        for item in messages[-tail_limit:]:
            recent_tail.append(item)

        live_links = [item for item in show["links"] if bool(item.get("native_resume_supported"))]
        bridge_links = [item for item in show["links"] if not bool(item.get("native_resume_supported"))]
        return {
            "schema": "rayman.shared_session_status.v1",
            "success": True,
            "session": session,
            "continuation": {
                "summary_text": session.get("summary_text") or session.get("resume_summary_text") or session.get("recap_text"),
                "resume_summary_text": session.get("resume_summary_text"),
                "recap_text": session.get("recap_text"),
                "protected_head": protected_head,
                "recent_tail": recent_tail,
                "queued_messages": queued_messages,
                "native_resume_links": live_links,
                "bridge_links": bridge_links,
            },
        }


def load_payload(path: str) -> Dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise ValueError("input payload must be a JSON object")
    return payload


def resolve_config(workspace_root: str) -> Dict[str, Any]:
    enabled_raw = os.environ.get("RAYMAN_SHARED_SESSION_ENABLED", "").strip().lower()
    enabled = enabled_raw in {"1", "true", "yes", "on"}
    return {
        "enabled": enabled,
        "scope": os.environ.get("RAYMAN_SHARED_SESSION_SCOPE", "same_machine_single_user").strip() or "same_machine_single_user",
        "copilot_mode": os.environ.get("RAYMAN_SHARED_SESSION_COPILOT_MODE", "cli_or_sdk").strip() or "cli_or_sdk",
        "lock_timeout_seconds": max(1, int(os.environ.get("RAYMAN_SHARED_SESSION_LOCK_TIMEOUT_SECONDS", "300") or "300")),
        "compaction_enabled": os.environ.get("RAYMAN_SHARED_SESSION_COMPACTION_ENABLED", "1").strip().lower() not in {"0", "false", "no", "off"},
        "workspace_root": str(Path(workspace_root).resolve()),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Rayman shared session backend")
    parser.add_argument(
        "action",
        choices=[
            "status",
            "upsert-session",
            "list",
            "show",
            "append-message",
            "link",
            "unlink",
            "acquire-lock",
            "release-lock",
            "checkpoint",
            "restore-checkpoint",
            "compact",
            "continue",
        ],
    )
    parser.add_argument("--workspace-root", required=True)
    parser.add_argument("--input-json-file", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--message-limit", type=int, default=80)
    parser.add_argument("--json", action="store_true")
    return parser


def emit(result: Dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(result, ensure_ascii=False))


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    paths = SharedSessionPaths(args.workspace_root)
    config = resolve_config(args.workspace_root)
    store = SharedSessionStore(paths)
    try:
        payload = load_payload(args.input_json_file) if normalize_text(args.input_json_file) else {}
        result: Dict[str, Any]
        if args.action == "status":
            result = store.write_status(enabled=bool(config["enabled"]), config=config, message="Shared session store ready")
        elif args.action == "upsert-session":
            result = store.upsert_session(payload)
        elif args.action == "list":
            result = store.list_sessions(limit=args.limit)
        elif args.action == "show":
            session_id = normalize_text(args.session_id) or normalize_text(payload.get("session_id"))
            result = store.show_session(session_id=session_id, message_limit=args.message_limit)
        elif args.action == "append-message":
            result = store.append_message(payload)
        elif args.action == "link":
            result = store.link_session(payload)
        elif args.action == "unlink":
            result = store.unlink_session(payload)
        elif args.action == "acquire-lock":
            result = store.acquire_lock(payload)
        elif args.action == "release-lock":
            result = store.release_lock(payload)
        elif args.action == "checkpoint":
            result = store.save_checkpoint(payload)
        elif args.action == "restore-checkpoint":
            result = store.restore_checkpoint(payload)
        elif args.action == "compact":
            result = store.compact_session(payload)
        elif args.action == "continue":
            session_id = normalize_text(args.session_id) or normalize_text(payload.get("session_id"))
            result = store.continue_session({**payload, "session_id": session_id, "message_limit": args.message_limit})
        else:
            raise ValueError(f"unsupported action: {args.action}")
        emit(result, args.json)
        return 0
    except Exception as exc:
        error = {
            "schema": "rayman.shared_session_status.v1",
            "success": False,
            "message": str(exc),
            "action": args.action,
        }
        emit(error, args.json)
        return 1
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
