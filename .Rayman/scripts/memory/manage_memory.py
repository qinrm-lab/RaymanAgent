#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import io
import json
import math
import os
import re
import sqlite3
import struct
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

MODEL_NAME_DEFAULT = "sentence-transformers/all-MiniLM-L6-v2"
SEMANTIC_KINDS = {
    "constraint",
    "environment_fact",
    "playbook",
    "anti_pattern",
    "preference",
    "artifact_hint",
}
MAX_HINTS = 5
MAX_RECENT_SUMMARIES = 2


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def normalize_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def normalize_tags(values: Sequence[Any]) -> List[str]:
    seen = set()
    result: List[str] = []
    for item in values:
        tag = normalize_text(item).lower()
        if not tag or tag in seen:
            continue
        seen.add(tag)
        result.append(tag)
    return result


def stable_hash(*parts: Any) -> str:
    joined = "||".join(normalize_text(part) for part in parts)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def tokenize(text: str) -> List[str]:
    return re.findall(r"[A-Za-z0-9_./:-]+", text.lower())


def lexical_score(query: str, text: str) -> float:
    q_tokens = tokenize(query)
    t_tokens = tokenize(text)
    if not q_tokens or not t_tokens:
        return 0.0
    q_set = set(q_tokens)
    t_set = set(t_tokens)
    overlap = len(q_set & t_set)
    if overlap == 0:
        return 0.0
    union = len(q_set | t_set)
    score = overlap / max(1, union)
    if query.strip() and query.lower() in text.lower():
        score += 0.25
    return score


def encode_vector(values: Sequence[float]) -> bytes:
    floats = [float(v) for v in values]
    return struct.pack(f"<{len(floats)}f", *floats)


def decode_vector(blob: Optional[bytes]) -> List[float]:
    if not blob:
        return []
    if len(blob) % 4 != 0:
        return []
    count = len(blob) // 4
    return list(struct.unpack(f"<{count}f", blob))


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for av, bv in zip(a, b):
        dot += av * bv
        norm_a += av * av
        norm_b += bv * bv
    if norm_a <= 0 or norm_b <= 0:
        return 0.0
    return dot / math.sqrt(norm_a * norm_b)


@dataclass
class MemoryPaths:
    workspace_root: Path
    memory_root: Path
    runtime_root: Path
    db_path: Path
    status_path: Path
    pending_dir: Path


def resolve_paths(workspace_root: str) -> MemoryPaths:
    root = Path(workspace_root).resolve()
    memory_root = root / ".Rayman" / "state" / "memory"
    runtime_root = root / ".Rayman" / "runtime" / "memory"
    pending_dir = runtime_root / "pending"
    return MemoryPaths(
        workspace_root=root,
        memory_root=memory_root,
        runtime_root=runtime_root,
        db_path=memory_root / "memory.sqlite3",
        status_path=runtime_root / "status.json",
        pending_dir=pending_dir,
    )


class EmbeddingEngine:
    def __init__(self, model_name: str) -> None:
        self.model_name = model_name
        self.available = False
        self.backend = "lexical"
        self.reason = "embedding_runtime_unavailable"
        self._model = None

    def load(self, prewarm: bool = False) -> None:
        if self.available or self._model is not None:
            return

        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                from sentence_transformers import SentenceTransformer  # type: ignore
        except Exception as exc:
            self.available = False
            self.backend = "lexical"
            self.reason = f"sentence_transformers_import_failed:{exc.__class__.__name__}"
            return

        try:
            with contextlib.redirect_stderr(io.StringIO()):
                self._model = SentenceTransformer(self.model_name)
            self.available = True
            self.backend = "embedding"
            self.reason = "ready"
            if prewarm:
                self.encode(["rayman agent memory warmup"])
        except Exception as exc:
            self._model = None
            self.available = False
            self.backend = "lexical"
            self.reason = f"embedding_model_unavailable:{exc.__class__.__name__}"

    def encode(self, texts: Sequence[str]) -> List[List[float]]:
        if not texts:
            return []
        self.load(prewarm=False)
        if not self.available or self._model is None:
            return []
        encoded = self._model.encode(list(texts), normalize_embeddings=True)
        result: List[List[float]] = []
        for row in encoded:
            values = row.tolist() if hasattr(row, "tolist") else list(row)
            result.append([float(v) for v in values])
        return result


class MemoryStore:
    def __init__(self, paths: MemoryPaths, model_name: str) -> None:
        self.paths = paths
        self.model_name = model_name
        ensure_dir(paths.memory_root)
        ensure_dir(paths.runtime_root)
        ensure_dir(paths.pending_dir)
        self.conn = sqlite3.connect(str(paths.db_path), timeout=60.0)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA busy_timeout=60000")
        self.engine = EmbeddingEngine(model_name)
        self.ensure_schema()

    def close(self) -> None:
        self.conn.close()

    def ensure_schema(self) -> None:
        self.conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                episode_key TEXT NOT NULL UNIQUE,
                run_id TEXT NOT NULL,
                task_key TEXT NOT NULL,
                task_kind TEXT NOT NULL,
                stage TEXT NOT NULL,
                round INTEGER NOT NULL DEFAULT 0,
                success INTEGER,
                error_kind TEXT,
                duration_ms INTEGER,
                selected_tools TEXT NOT NULL DEFAULT '[]',
                diff_summary TEXT,
                artifact_refs_json TEXT NOT NULL DEFAULT '[]',
                summary_text TEXT NOT NULL DEFAULT '',
                payload_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_episodes_task_key ON episodes(task_key, created_at);
            CREATE INDEX IF NOT EXISTS idx_episodes_run_id ON episodes(run_id);

            CREATE TABLE IF NOT EXISTS task_summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_key TEXT NOT NULL UNIQUE,
                task_kind TEXT NOT NULL,
                episode_ids TEXT NOT NULL DEFAULT '[]',
                outcome TEXT NOT NULL,
                success INTEGER NOT NULL DEFAULT 0,
                summary_text TEXT NOT NULL,
                files_touched TEXT NOT NULL DEFAULT '[]',
                lessons_json TEXT NOT NULL DEFAULT '[]',
                last_run_id TEXT NOT NULL DEFAULT '',
                last_episode_at TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_task_summaries_updated_at ON task_summaries(updated_at DESC);

            CREATE TABLE IF NOT EXISTS semantic_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                scope TEXT NOT NULL,
                task_kind TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '[]',
                evidence_ids TEXT NOT NULL DEFAULT '[]',
                confidence REAL NOT NULL DEFAULT 0.5,
                last_used_at TEXT NOT NULL DEFAULT '',
                embedding_blob BLOB,
                embedding_hash TEXT NOT NULL DEFAULT '',
                content_text TEXT NOT NULL,
                source_task_key TEXT NOT NULL DEFAULT '',
                readonly INTEGER NOT NULL DEFAULT 0,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_semantic_memories_lookup
                ON semantic_memories(scope, kind, task_kind, updated_at DESC);
            """
        )
        self.conn.commit()

    def write_status(
        self,
        *,
        success: bool,
        message: str,
        prewarm: bool = False,
        extra: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        if prewarm:
            self.engine.load(prewarm=True)
        else:
            self.engine.load(prewarm=False)

        counts = {
            "episodes": self.scalar("SELECT COUNT(*) FROM episodes"),
            "task_summaries": self.scalar("SELECT COUNT(*) FROM task_summaries"),
            "semantic_memories": self.scalar("SELECT COUNT(*) FROM semantic_memories"),
        }
        status = {
            "schema": "rayman.agent_memory.status.v1",
            "success": bool(success),
            "message": message,
            "workspace_root": str(self.paths.workspace_root),
            "memory_root": str(self.paths.memory_root),
            "db_path": str(self.paths.db_path),
            "status_path": str(self.paths.status_path),
            "embedding_model": self.model_name,
            "deps_ready": bool(self.engine.available),
            "search_backend": self.engine.backend,
            "fallback_reason": self.engine.reason,
            "prewarm_requested": bool(prewarm),
            "counts": counts,
            "generated_at": utc_now(),
            "python_version": sys.version.split()[0],
        }
        if extra:
            status.update(extra)
        self.paths.status_path.write_text(json_dumps(status), encoding="utf-8")
        return status

    def scalar(self, sql: str, params: Sequence[Any] = ()) -> int:
        row = self.conn.execute(sql, params).fetchone()
        if row is None:
            return 0
        return int(row[0] or 0)

    def write_runtime_artifact(self, name: str, payload: Dict[str, Any]) -> None:
        path = self.paths.runtime_root / name
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    def record_episode(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        now = utc_now()
        run_id = normalize_text(payload.get("run_id"))
        task_key = normalize_text(payload.get("task_key"))
        task_kind = normalize_text(payload.get("task_kind")) or "general"
        stage = normalize_text(payload.get("stage")) or "dispatch"
        if not run_id:
            raise ValueError("run_id is required")
        if not task_key:
            raise ValueError("task_key is required")

        round_value = int(payload.get("round") or 0)
        success_raw = payload.get("success")
        success_value = None if success_raw is None else (1 if bool(success_raw) else 0)
        error_kind = normalize_text(payload.get("error_kind"))
        duration_ms = payload.get("duration_ms")
        if duration_ms is not None:
            duration_ms = int(duration_ms)
        selected_tools = normalize_tags(payload.get("selected_tools") or [])
        artifact_refs = payload.get("artifact_refs_json") or payload.get("artifact_refs") or []
        if not isinstance(artifact_refs, list):
            artifact_refs = [artifact_refs]
        summary_text = normalize_text(payload.get("summary_text"))
        diff_summary = payload.get("diff_summary")
        episode_key = normalize_text(payload.get("episode_key"))
        if not episode_key:
            episode_key = stable_hash(run_id, task_key, stage, round_value)

        self.conn.execute(
            """
            INSERT INTO episodes (
                episode_key, run_id, task_key, task_kind, stage, round, success,
                error_kind, duration_ms, selected_tools, diff_summary,
                artifact_refs_json, summary_text, payload_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(episode_key) DO UPDATE SET
                run_id=excluded.run_id,
                task_key=excluded.task_key,
                task_kind=excluded.task_kind,
                stage=excluded.stage,
                round=excluded.round,
                success=excluded.success,
                error_kind=excluded.error_kind,
                duration_ms=excluded.duration_ms,
                selected_tools=excluded.selected_tools,
                diff_summary=excluded.diff_summary,
                artifact_refs_json=excluded.artifact_refs_json,
                summary_text=excluded.summary_text,
                payload_json=excluded.payload_json,
                updated_at=excluded.updated_at
            """,
            (
                episode_key,
                run_id,
                task_key,
                task_kind,
                stage,
                round_value,
                success_value,
                error_kind,
                duration_ms,
                json_dumps(selected_tools),
                json_dumps(diff_summary) if diff_summary is not None else "",
                json_dumps(artifact_refs),
                summary_text,
                json_dumps(payload),
                now,
                now,
            ),
        )
        self.conn.commit()
        row = self.conn.execute(
            "SELECT id, created_at, updated_at FROM episodes WHERE episode_key = ?",
            (episode_key,),
        ).fetchone()
        return {
            "schema": "rayman.agent_memory.record_result.v1",
            "stored": True,
            "episode_id": int(row["id"]),
            "episode_key": episode_key,
            "task_key": task_key,
            "run_id": run_id,
            "task_kind": task_kind,
            "stage": stage,
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def summarize_tasks(
        self,
        *,
        task_key: str = "",
        run_id: str = "",
        drain_pending: bool = False,
    ) -> Dict[str, Any]:
        self.seed_constraints()
        task_keys = set()
        if task_key:
            task_keys.add(task_key)
        if run_id:
            rows = self.conn.execute(
                "SELECT DISTINCT task_key FROM episodes WHERE run_id = ?",
                (run_id,),
            ).fetchall()
            task_keys.update(normalize_text(row["task_key"]) for row in rows)
        if drain_pending:
            for marker in self.paths.pending_dir.glob("*.json"):
                try:
                    data = json.loads(marker.read_text(encoding="utf-8"))
                except Exception:
                    data = {}
                candidate = normalize_text(data.get("task_key"))
                if candidate:
                    task_keys.add(candidate)
        if not task_keys:
            rows = self.conn.execute(
                """
                SELECT DISTINCT e.task_key
                FROM episodes e
                LEFT JOIN task_summaries ts ON ts.task_key = e.task_key
                WHERE ts.task_key IS NULL OR e.updated_at > ts.updated_at
                """
            ).fetchall()
            task_keys.update(normalize_text(row["task_key"]) for row in rows)

        summarized = []
        for item in sorted(key for key in task_keys if key):
            summary = self._summarize_task(item)
            if summary:
                summarized.append(summary)
        if drain_pending:
            self._clear_pending_markers({item["task_key"] for item in summarized})
        return {
            "schema": "rayman.agent_memory.summarize_result.v1",
            "success": True,
            "count": len(summarized),
            "task_summaries": summarized,
        }

    def search(
        self,
        *,
        query: str,
        task_kind: str = "",
        task_key: str = "",
        scope: str = "",
        kind: str = "",
        tags: Optional[Sequence[str]] = None,
        limit: int = MAX_HINTS,
        recent_limit: int = MAX_RECENT_SUMMARIES,
    ) -> Dict[str, Any]:
        self.seed_constraints()
        limit = max(1, min(MAX_HINTS, int(limit)))
        recent_limit = max(0, min(MAX_RECENT_SUMMARIES, int(recent_limit)))
        query_text = normalize_text(query)
        filter_tags = normalize_tags(tags or [])
        self.engine.load(prewarm=False)

        conditions = []
        params: List[Any] = []
        if scope:
            conditions.append("scope = ?")
            params.append(scope)
        if kind:
            conditions.append("kind = ?")
            params.append(kind)
        if task_kind:
            conditions.append("(task_kind = '' OR task_kind = ?)")
            params.append(task_kind)
        sql = "SELECT * FROM semantic_memories"
        if conditions:
            sql += " WHERE " + " AND ".join(conditions)
        sql += " ORDER BY confidence DESC, updated_at DESC"
        candidates = [dict(row) for row in self.conn.execute(sql, params).fetchall()]

        if filter_tags:
            filtered = []
            for row in candidates:
                row_tags = set(json.loads(row["tags"] or "[]"))
                if set(filter_tags).issubset(row_tags):
                    filtered.append(row)
            candidates = filtered

        query_vector: List[float] = []
        if query_text and self.engine.available:
            encoded = self.engine.encode([query_text])
            if encoded:
                query_vector = encoded[0]

        scored = []
        for row in candidates:
            content_text = normalize_text(row["content_text"])
            row_vector = decode_vector(row["embedding_blob"])
            lexical = lexical_score(query_text, content_text) if query_text else 0.0
            semantic = cosine_similarity(query_vector, row_vector) if query_vector and row_vector else 0.0
            score = semantic if semantic > 0 else lexical
            score += float(row["confidence"] or 0.0) * 0.05
            scored.append((score, lexical, semantic, row))
        scored.sort(key=lambda item: (item[0], item[2], item[1], item[3]["updated_at"]), reverse=True)

        hints = []
        used_ids = []
        for score, lexical, semantic, row in scored[:limit]:
            hints.append(
                {
                    "id": int(row["id"]),
                    "kind": row["kind"],
                    "scope": row["scope"],
                    "task_kind": row["task_kind"],
                    "content": row["content_text"],
                    "tags": json.loads(row["tags"] or "[]"),
                    "confidence": float(row["confidence"] or 0.0),
                    "score": round(score, 6),
                    "lexical_score": round(lexical, 6),
                    "semantic_score": round(semantic, 6),
                    "source_task_key": row["source_task_key"],
                    "readonly": bool(row["readonly"]),
                }
            )
            used_ids.append(int(row["id"]))

        if used_ids:
            now = utc_now()
            self.conn.executemany(
                "UPDATE semantic_memories SET last_used_at = ? WHERE id = ?",
                [(now, item) for item in used_ids],
            )
            self.conn.commit()

        summary_conditions = []
        summary_params: List[Any] = []
        if task_key:
            summary_conditions.append("task_key = ?")
            summary_params.append(task_key)
        elif task_kind:
            summary_conditions.append("task_kind = ?")
            summary_params.append(task_kind)
        summary_sql = "SELECT * FROM task_summaries"
        if summary_conditions:
            summary_sql += " WHERE " + " AND ".join(summary_conditions)
        summary_sql += " ORDER BY updated_at DESC LIMIT ?"
        summary_params.append(recent_limit)
        recent_rows = [
            {
                "task_key": row["task_key"],
                "task_kind": row["task_kind"],
                "outcome": row["outcome"],
                "success": bool(row["success"]),
                "summary_text": row["summary_text"],
                "files_touched": json.loads(row["files_touched"] or "[]"),
                "lessons": json.loads(row["lessons_json"] or "[]"),
                "updated_at": row["updated_at"],
            }
            for row in self.conn.execute(summary_sql, summary_params).fetchall()
        ]

        return {
            "schema": "rayman.agent_memory.search_result.v1",
            "success": True,
            "query": query_text,
            "task_key": task_key,
            "task_kind": task_kind,
            "scope": scope or "workspace",
            "kind": kind,
            "tags": filter_tags,
            "memory_hints": hints,
            "recent_task_summaries": recent_rows,
            "search_backend": self.engine.backend,
            "embedding_model": self.model_name,
            "fallback_reason": self.engine.reason,
        }

    def prune(
        self,
        *,
        max_age_days: int = 0,
        keep_per_task: int = 0,
    ) -> Dict[str, Any]:
        deleted_episodes = 0
        deleted_summaries = 0
        deleted_semantic = 0
        if max_age_days > 0:
            cutoff = datetime.now(timezone.utc).timestamp() - (max_age_days * 86400)
            cutoff_iso = datetime.fromtimestamp(cutoff, timezone.utc).replace(microsecond=0).isoformat()
            deleted_summaries = self.conn.execute(
                "DELETE FROM task_summaries WHERE updated_at < ?",
                (cutoff_iso,),
            ).rowcount
            deleted_semantic = self.conn.execute(
                "DELETE FROM semantic_memories WHERE readonly = 0 AND updated_at < ?",
                (cutoff_iso,),
            ).rowcount
            deleted_episodes = self.conn.execute(
                "DELETE FROM episodes WHERE updated_at < ?",
                (cutoff_iso,),
            ).rowcount
        if keep_per_task > 0:
            task_rows = self.conn.execute("SELECT DISTINCT task_key FROM episodes").fetchall()
            for task_row in task_rows:
                task_key_value = task_row["task_key"]
                ids = [
                    int(row["id"])
                    for row in self.conn.execute(
                        "SELECT id FROM episodes WHERE task_key = ? ORDER BY updated_at DESC, id DESC",
                        (task_key_value,),
                    ).fetchall()
                ]
                drop = ids[keep_per_task:]
                if drop:
                    placeholders = ",".join("?" for _ in drop)
                    deleted_episodes += self.conn.execute(
                        f"DELETE FROM episodes WHERE id IN ({placeholders})",
                        drop,
                    ).rowcount
        self.conn.commit()
        self.conn.execute("VACUUM")
        self.conn.commit()
        return {
            "schema": "rayman.agent_memory.prune_result.v1",
            "success": True,
            "deleted": {
                "episodes": deleted_episodes,
                "task_summaries": deleted_summaries,
                "semantic_memories": deleted_semantic,
            },
        }

    def seed_constraints(self) -> None:
        solution_name = self.paths.workspace_root.name
        constraint_sources = [
            self.paths.workspace_root / f".{solution_name}" / f".{solution_name}.requirements.md",
            self.paths.workspace_root / ".Rayman" / "RELEASE_REQUIREMENTS.md",
        ]
        for source in constraint_sources:
            if not source.is_file():
                continue
            heading = ""
            try:
                lines = source.read_text(encoding="utf-8").splitlines()
            except Exception:
                continue
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("## "):
                    heading = stripped[3:].strip()
                    continue
                if stripped.startswith("- "):
                    text = stripped[2:].strip()
                elif stripped.startswith("MUST_"):
                    text = stripped
                else:
                    continue
                if not text:
                    continue
                content = text if not heading else f"{heading}: {text}"
                self._upsert_semantic_memory(
                    kind="constraint",
                    scope="workspace",
                    task_kind="",
                    tags=["constraint", "requirements"],
                    evidence_ids=[],
                    confidence=1.0,
                    content_text=content,
                    source_task_key="workspace/constraints",
                    readonly=True,
                    metadata={"source_path": str(source.relative_to(self.paths.workspace_root))},
                )
        self.conn.commit()

    def _summarize_task(self, task_key: str) -> Optional[Dict[str, Any]]:
        rows = self.conn.execute(
            "SELECT * FROM episodes WHERE task_key = ? ORDER BY created_at ASC, id ASC",
            (task_key,),
        ).fetchall()
        if not rows:
            return None

        episodes = [dict(row) for row in rows]
        latest = episodes[-1]
        task_kind = normalize_text(latest["task_kind"]) or "general"
        stage_chain = [normalize_text(item["stage"]) for item in episodes]
        error_kinds = [
            normalize_text(item["error_kind"])
            for item in episodes
            if normalize_text(item["error_kind"]) and normalize_text(item["error_kind"]) != "ok"
        ]
        error_counter = Counter(error_kinds)
        dominant_error = error_counter.most_common(1)[0][0] if error_counter else ""
        files_touched = sorted(self._extract_files_touched(episodes))
        selected_tools = sorted(
            {
                tool
                for item in episodes
                for tool in json.loads(item["selected_tools"] or "[]")
                if normalize_text(tool)
            }
        )
        success_value = latest["success"]
        success = bool(success_value) if success_value is not None else (normalize_text(latest["error_kind"]) in {"", "ok"})

        if success:
            outcome = "success"
        elif dominant_error and error_counter[dominant_error] >= 2:
            outcome = "anti_pattern"
        else:
            outcome = "failed"

        summary_parts = [
            f"task_kind={task_kind}",
            f"outcome={outcome}",
            f"episodes={len(episodes)}",
            f"stages={','.join(stage_chain)}",
        ]
        if dominant_error:
            summary_parts.append(f"dominant_error={dominant_error}")
        if selected_tools:
            summary_parts.append(f"selected_tools={','.join(selected_tools)}")
        if files_touched:
            summary_parts.append(f"files={','.join(files_touched[:6])}")
        summary_text = "; ".join(summary_parts)

        lessons: List[Dict[str, Any]] = []
        if success:
            lessons.append(
                {
                    "kind": "playbook",
                    "text": f"{task_kind} succeeded after {len(episodes)} episode(s). Preferred tools: {', '.join(selected_tools) if selected_tools else 'n/a'}.",
                }
            )
        if dominant_error and error_counter[dominant_error] >= 2:
            lessons.append(
                {
                    "kind": "anti_pattern",
                    "text": f"Repeated failure pattern `{dominant_error}` observed {error_counter[dominant_error]} times for task `{task_key}`.",
                }
            )
        if files_touched:
            lessons.append(
                {
                    "kind": "artifact_hint",
                    "text": f"Relevant files touched: {', '.join(files_touched[:8])}.",
                }
            )

        now = utc_now()
        episode_ids = [int(item["id"]) for item in episodes]
        self.conn.execute(
            """
            INSERT INTO task_summaries (
                task_key, task_kind, episode_ids, outcome, success, summary_text,
                files_touched, lessons_json, last_run_id, last_episode_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_key) DO UPDATE SET
                task_kind=excluded.task_kind,
                episode_ids=excluded.episode_ids,
                outcome=excluded.outcome,
                success=excluded.success,
                summary_text=excluded.summary_text,
                files_touched=excluded.files_touched,
                lessons_json=excluded.lessons_json,
                last_run_id=excluded.last_run_id,
                last_episode_at=excluded.last_episode_at,
                updated_at=excluded.updated_at
            """,
            (
                task_key,
                task_kind,
                json_dumps(episode_ids),
                outcome,
                1 if success else 0,
                summary_text,
                json_dumps(files_touched),
                json_dumps(lessons),
                normalize_text(latest["run_id"]),
                normalize_text(latest["updated_at"]),
                now,
                now,
            ),
        )

        evidence_ids = [str(item) for item in episode_ids]
        if success:
            self._upsert_semantic_memory(
                kind="playbook",
                scope="workspace",
                task_kind=task_kind,
                tags=["playbook", task_kind],
                evidence_ids=evidence_ids,
                confidence=0.8,
                content_text=summary_text,
                source_task_key=task_key,
                metadata={"files_touched": files_touched, "selected_tools": selected_tools},
            )
        if dominant_error and error_counter[dominant_error] >= 2:
            self._upsert_semantic_memory(
                kind="anti_pattern",
                scope="workspace",
                task_kind=task_kind,
                tags=["anti_pattern", task_kind, dominant_error],
                evidence_ids=evidence_ids,
                confidence=min(1.0, 0.55 + error_counter[dominant_error] * 0.1),
                content_text=f"{task_kind} repeatedly failed with {dominant_error}. {summary_text}",
                source_task_key=task_key,
                metadata={"error_kind": dominant_error},
            )
        if files_touched:
            self._upsert_semantic_memory(
                kind="artifact_hint",
                scope="workspace",
                task_kind=task_kind,
                tags=["artifact_hint", task_kind],
                evidence_ids=evidence_ids,
                confidence=0.65 if success else 0.5,
                content_text=f"{task_kind} commonly touches {', '.join(files_touched[:8])}.",
                source_task_key=task_key,
                metadata={"files_touched": files_touched},
            )

        self.conn.commit()
        return {
            "task_key": task_key,
            "task_kind": task_kind,
            "outcome": outcome,
            "success": success,
            "summary_text": summary_text,
            "episode_ids": episode_ids,
            "files_touched": files_touched,
            "lessons": lessons,
            "updated_at": now,
        }

    def _upsert_semantic_memory(
        self,
        *,
        kind: str,
        scope: str,
        task_kind: str,
        tags: Sequence[str],
        evidence_ids: Sequence[str],
        confidence: float,
        content_text: str,
        source_task_key: str,
        readonly: bool = False,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> None:
        if kind not in SEMANTIC_KINDS:
            return
        text = normalize_text(content_text)
        if not text:
            return
        self.engine.load(prewarm=False)
        tags_value = normalize_tags(tags)
        now = utc_now()
        embedding_blob = None
        embedding_hash = ""
        vectors = self.engine.encode([text]) if self.engine.available else []
        if vectors:
            embedding_blob = encode_vector(vectors[0])
            embedding_hash = hashlib.sha256(embedding_blob).hexdigest()
        memory_key = stable_hash(kind, scope, task_kind, text)
        existing = self.conn.execute(
            "SELECT id, confidence FROM semantic_memories WHERE memory_key = ?",
            (memory_key,),
        ).fetchone()
        merged_confidence = max(float(existing["confidence"] or 0.0), float(confidence)) if existing else float(confidence)
        self.conn.execute(
            """
            INSERT INTO semantic_memories (
                memory_key, kind, scope, task_kind, tags, evidence_ids, confidence,
                last_used_at, embedding_blob, embedding_hash, content_text, source_task_key,
                readonly, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(memory_key) DO UPDATE SET
                tags=excluded.tags,
                evidence_ids=excluded.evidence_ids,
                confidence=excluded.confidence,
                embedding_blob=CASE
                    WHEN excluded.embedding_blob IS NOT NULL THEN excluded.embedding_blob
                    ELSE semantic_memories.embedding_blob
                END,
                embedding_hash=CASE
                    WHEN excluded.embedding_hash <> '' THEN excluded.embedding_hash
                    ELSE semantic_memories.embedding_hash
                END,
                content_text=excluded.content_text,
                source_task_key=excluded.source_task_key,
                readonly=excluded.readonly,
                metadata_json=excluded.metadata_json,
                updated_at=excluded.updated_at
            """,
            (
                memory_key,
                kind,
                scope or "workspace",
                task_kind,
                json_dumps(tags_value),
                json_dumps(list(evidence_ids)),
                merged_confidence,
                "",
                embedding_blob,
                embedding_hash,
                text,
                source_task_key,
                1 if readonly else 0,
                json_dumps(metadata or {}),
                now,
                now,
            ),
        )

    def _extract_files_touched(self, episodes: Sequence[Dict[str, Any]]) -> Iterable[str]:
        files = set()
        for item in episodes:
            diff_summary_raw = item.get("diff_summary")
            diff_summary = {}
            if isinstance(diff_summary_raw, str) and diff_summary_raw:
                try:
                    diff_summary = json.loads(diff_summary_raw)
                except Exception:
                    diff_summary = {}
            elif isinstance(diff_summary_raw, dict):
                diff_summary = diff_summary_raw
            if isinstance(diff_summary, dict):
                for key in ("top_files", "files", "touched_files"):
                    values = diff_summary.get(key) or []
                    if isinstance(values, list):
                        for entry in values:
                            path_value = normalize_text(entry.get("path")) if isinstance(entry, dict) else normalize_text(entry)
                            if path_value:
                                files.add(path_value)
            artifact_refs_raw = item.get("artifact_refs_json")
            refs = []
            if isinstance(artifact_refs_raw, str) and artifact_refs_raw:
                try:
                    refs = json.loads(artifact_refs_raw)
                except Exception:
                    refs = []
            elif isinstance(artifact_refs_raw, list):
                refs = artifact_refs_raw
            for ref in refs:
                value = normalize_text(ref.get("path") or ref.get("ref")) if isinstance(ref, dict) else normalize_text(ref)
                if value:
                    files.add(value)
        return files

    def _clear_pending_markers(self, task_keys: Iterable[str]) -> None:
        keep = set(task_keys)
        for marker in self.paths.pending_dir.glob("*.json"):
            try:
                data = json.loads(marker.read_text(encoding="utf-8"))
            except Exception:
                data = {}
            marker_task_key = normalize_text(data.get("task_key"))
            if marker_task_key and marker_task_key in keep:
                try:
                    marker.unlink()
                except FileNotFoundError:
                    pass


def load_payload(path: str) -> Dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("input payload must be a JSON object")
    return payload


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Rayman Agent Memory backend")
    parser.add_argument("action", choices=["status", "record", "summarize", "search", "prune"])
    parser.add_argument("--workspace-root", required=True)
    parser.add_argument("--model-name", default=os.environ.get("RAYMAN_MEMORY_EMBEDDING_MODEL", MODEL_NAME_DEFAULT))
    parser.add_argument("--input-json-file", default="")
    parser.add_argument("--query", default="")
    parser.add_argument("--task-key", default="")
    parser.add_argument("--task-kind", default="")
    parser.add_argument("--scope", default="")
    parser.add_argument("--kind", default="")
    parser.add_argument("--tag", action="append", dest="tags", default=[])
    parser.add_argument("--limit", type=int, default=MAX_HINTS)
    parser.add_argument("--recent-limit", type=int, default=MAX_RECENT_SUMMARIES)
    parser.add_argument("--drain-pending", action="store_true")
    parser.add_argument("--prewarm", action="store_true")
    parser.add_argument("--max-age-days", type=int, default=0)
    parser.add_argument("--keep-per-task", type=int, default=0)
    parser.add_argument("--json", action="store_true")
    return parser


def emit(result: Dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    if "message" in result:
        print(result["message"])
    else:
        print(json.dumps(result, ensure_ascii=False))


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    paths = resolve_paths(args.workspace_root)
    store = MemoryStore(paths, args.model_name)
    try:
        if args.action == "status":
            result = store.write_status(
                success=True,
                message="Agent Memory runtime ready",
                prewarm=bool(args.prewarm),
            )
        elif args.action == "record":
            payload = load_payload(args.input_json_file)
            result = store.record_episode(payload)
            store.write_status(success=True, message="Episode recorded")
            store.write_runtime_artifact("record.last.json", result)
        elif args.action == "summarize":
            result = store.summarize_tasks(
                task_key=normalize_text(args.task_key),
                run_id=normalize_text(args.query or ""),
                drain_pending=bool(args.drain_pending),
            )
            store.write_status(success=True, message="Agent Memory summarizer completed")
            store.write_runtime_artifact("summarize.last.json", result)
        elif args.action == "search":
            result = store.search(
                query=args.query,
                task_kind=args.task_kind,
                task_key=args.task_key,
                scope=args.scope,
                kind=args.kind,
                tags=args.tags,
                limit=args.limit,
                recent_limit=args.recent_limit,
            )
            store.write_status(success=True, message="Agent Memory search completed")
            store.write_runtime_artifact("search.last.json", result)
        elif args.action == "prune":
            result = store.prune(
                max_age_days=max(0, int(args.max_age_days)),
                keep_per_task=max(0, int(args.keep_per_task)),
            )
            store.write_status(success=True, message="Agent Memory prune completed")
            store.write_runtime_artifact("prune.last.json", result)
        else:
            raise ValueError(f"unsupported action: {args.action}")
        emit(result, args.json)
        return 0
    except Exception as exc:
        error = {
            "schema": "rayman.agent_memory.error.v1",
            "success": False,
            "message": str(exc),
            "action": args.action,
        }
        store.write_status(success=False, message=str(exc))
        emit(error, args.json)
        return 1
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
