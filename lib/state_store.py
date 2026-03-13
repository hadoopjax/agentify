#!/usr/bin/env python3
"""SQLite-backed local state store for agentify."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any


SCHEMA_VERSION = 1
_LOCK = threading.Lock()


def agentify_dir(explicit_dir: str | None = None) -> str:
    return os.path.abspath(explicit_dir or os.environ.get("AGENTIFY_DIR", ".agentify"))


def db_path(explicit_dir: str | None = None) -> str:
    return os.path.join(agentify_dir(explicit_dir), "state.db")


def _connect(explicit_dir: str | None = None) -> sqlite3.Connection:
    path = db_path(explicit_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path, timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=30000")
    return conn


def init_db(explicit_dir: str | None = None) -> None:
    with _LOCK:
      with _connect(explicit_dir) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS kv_state (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workers (
              worker_id TEXT PRIMARY KEY,
              data TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS epics (
              epic_id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'planned-issues',
              title TEXT NOT NULL,
              data TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS proposals (
              proposal_id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              data TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS interviews (
              interview_id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              data TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              type TEXT NOT NULL,
              msg TEXT NOT NULL
            );
            """
        )
        conn.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
            (str(SCHEMA_VERSION),),
        )


def _json_dump(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _json_load(payload: str | None, fallback: Any = None) -> Any:
    if not payload:
        return fallback
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return fallback


@contextmanager
def transaction(explicit_dir: str | None = None):
    init_db(explicit_dir)
    with _LOCK:
        with _connect(explicit_dir) as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                yield conn
            except Exception:
                conn.execute("ROLLBACK")
                raise
            else:
                conn.execute("COMMIT")


def set_kv(key: str, value: Any, explicit_dir: str | None = None) -> None:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO kv_state(key, value) VALUES(?, ?)",
            (key, str(value)),
        )


def get_kv(key: str, explicit_dir: str | None = None, default: Any = "") -> Any:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        row = conn.execute("SELECT value FROM kv_state WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def delete_keys(keys: list[str], explicit_dir: str | None = None) -> None:
    if not keys:
        return
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        conn.executemany("DELETE FROM kv_state WHERE key = ?", [(key,) for key in keys])


def increment_kv(key: str, explicit_dir: str | None = None, default: int = 0) -> int:
    with transaction(explicit_dir) as conn:
        row = conn.execute("SELECT value FROM kv_state WHERE key = ?", (key,)).fetchone()
        current = int(row["value"]) if row and str(row["value"]).strip() else default
        current += 1
        conn.execute(
            "INSERT OR REPLACE INTO kv_state(key, value) VALUES(?, ?)",
            (key, str(current)),
        )
        return current


def emit_event(event_type: str, msg: str, explicit_dir: str | None = None) -> int:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        cursor = conn.execute(
            """
            INSERT INTO events(ts, type, msg)
            VALUES(strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?, ?)
            """,
            (event_type, msg),
        )
        return int(cursor.lastrowid)


def list_events(after_id: int = 0, explicit_dir: str | None = None) -> list[dict[str, Any]]:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        rows = conn.execute(
            "SELECT id, ts, type, msg FROM events WHERE id > ? ORDER BY id ASC",
            (after_id,),
        ).fetchall()
    return [dict(row) for row in rows]


def worker_get(worker_id: str, explicit_dir: str | None = None) -> dict[str, Any]:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        row = conn.execute("SELECT data FROM workers WHERE worker_id = ?", (worker_id,)).fetchone()
    return _json_load(row["data"], {}) if row else {}


def worker_set(worker_id: str, key: str, value: Any, explicit_dir: str | None = None) -> dict[str, Any]:
    with transaction(explicit_dir) as conn:
        row = conn.execute("SELECT data FROM workers WHERE worker_id = ?", (worker_id,)).fetchone()
        payload = _json_load(row["data"], {}) if row else {}
        payload[key] = value
        conn.execute(
            """
            INSERT INTO workers(worker_id, data, updated_at)
            VALUES(?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT(worker_id) DO UPDATE SET
              data = excluded.data,
              updated_at = excluded.updated_at
            """,
            (worker_id, _json_dump(payload)),
        )
        return payload


def worker_replace(worker_id: str, data: dict[str, Any], explicit_dir: str | None = None) -> None:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        conn.execute(
            """
            INSERT INTO workers(worker_id, data, updated_at)
            VALUES(?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT(worker_id) DO UPDATE SET
              data = excluded.data,
              updated_at = excluded.updated_at
            """,
            (worker_id, _json_dump(data)),
        )


def worker_delete(worker_id: str, explicit_dir: str | None = None) -> None:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        conn.execute("DELETE FROM workers WHERE worker_id = ?", (worker_id,))


def list_workers(explicit_dir: str | None = None) -> dict[str, dict[str, Any]]:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        rows = conn.execute("SELECT worker_id, data FROM workers ORDER BY worker_id ASC").fetchall()
    return {row["worker_id"]: _json_load(row["data"], {}) for row in rows}


def _save_document(table: str, id_field: str, item_id: str, payload: dict[str, Any], explicit_dir: str | None = None) -> None:
    init_db(explicit_dir)
    status = str(payload.get("status", "pending"))
    if table == "epics":
        kind = str(payload.get("kind", "planned-issues"))
        title = str(payload.get("title", item_id))
        query = f"""
            INSERT INTO {table}({id_field}, status, kind, title, data, updated_at)
            VALUES(?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT({id_field}) DO UPDATE SET
              status = excluded.status,
              kind = excluded.kind,
              title = excluded.title,
              data = excluded.data,
              updated_at = excluded.updated_at
        """
        args = (item_id, status, kind, title, _json_dump(payload))
    else:
        query = f"""
            INSERT INTO {table}({id_field}, status, data, updated_at)
            VALUES(?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT({id_field}) DO UPDATE SET
              status = excluded.status,
              data = excluded.data,
              updated_at = excluded.updated_at
        """
        args = (item_id, status, _json_dump(payload))
    with _connect(explicit_dir) as conn:
        conn.execute(query, args)


def _get_document(table: str, id_field: str, item_id: str, explicit_dir: str | None = None) -> dict[str, Any] | None:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        row = conn.execute(f"SELECT data FROM {table} WHERE {id_field} = ?", (item_id,)).fetchone()
    if not row:
        return None
    return _json_load(row["data"], {})


def _list_documents(table: str, id_field: str, explicit_dir: str | None = None) -> list[dict[str, Any]]:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        rows = conn.execute(f"SELECT data FROM {table} ORDER BY {id_field} ASC").fetchall()
    return [_json_load(row["data"], {}) for row in rows]


def save_epic(payload: dict[str, Any], explicit_dir: str | None = None) -> None:
    epic_id = str(payload["id"])
    _save_document("epics", "epic_id", epic_id, payload, explicit_dir)


def get_epic(epic_id: str, explicit_dir: str | None = None) -> dict[str, Any] | None:
    return _get_document("epics", "epic_id", epic_id, explicit_dir)


def list_epics(explicit_dir: str | None = None) -> list[dict[str, Any]]:
    return _list_documents("epics", "epic_id", explicit_dir)


def save_proposal(payload: dict[str, Any], explicit_dir: str | None = None) -> None:
    proposal_id = str(payload["id"])
    _save_document("proposals", "proposal_id", proposal_id, payload, explicit_dir)


def get_proposal(proposal_id: str, explicit_dir: str | None = None) -> dict[str, Any] | None:
    return _get_document("proposals", "proposal_id", proposal_id, explicit_dir)


def list_proposals(explicit_dir: str | None = None) -> list[dict[str, Any]]:
    return _list_documents("proposals", "proposal_id", explicit_dir)


def save_interview(payload: dict[str, Any], explicit_dir: str | None = None) -> None:
    interview_id = str(payload["id"])
    _save_document("interviews", "interview_id", interview_id, payload, explicit_dir)


def get_interview(interview_id: str, explicit_dir: str | None = None) -> dict[str, Any] | None:
    return _get_document("interviews", "interview_id", interview_id, explicit_dir)


def list_interviews(explicit_dir: str | None = None) -> list[dict[str, Any]]:
    return _list_documents("interviews", "interview_id", explicit_dir)


def delete_document(table: str, id_field: str, item_id: str, explicit_dir: str | None = None) -> None:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        conn.execute(f"DELETE FROM {table} WHERE {id_field} = ?", (item_id,))


@dataclass
class Snapshot:
    state: dict[str, Any]
    workers: dict[str, dict[str, Any]]
    epics: list[dict[str, Any]]
    proposals: list[dict[str, Any]]
    interviews: list[dict[str, Any]]


def load_snapshot(explicit_dir: str | None = None) -> Snapshot:
    init_db(explicit_dir)
    with _connect(explicit_dir) as conn:
        state_rows = conn.execute("SELECT key, value FROM kv_state").fetchall()
    return Snapshot(
        state={row["key"]: row["value"] for row in state_rows},
        workers=list_workers(explicit_dir),
        epics=list_epics(explicit_dir),
        proposals=list_proposals(explicit_dir),
        interviews=list_interviews(explicit_dir),
    )
