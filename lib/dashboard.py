#!/usr/bin/env python3
"""agentify dashboard and local control surface."""

from __future__ import annotations

import argparse
import http.server
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

try:
    from state_store import get_epic, get_interview, init_db, list_epics, list_events, list_interviews, list_proposals, load_snapshot, save_interview
except ModuleNotFoundError:
    from lib.state_store import get_epic, get_interview, init_db, list_epics, list_events, list_interviews, list_proposals, load_snapshot, save_interview


SCRIPT_DIR = Path(__file__).resolve().parent
HTML_FILE = SCRIPT_DIR / "index.html"
AGENTIFY_BIN = SCRIPT_DIR.parent / "bin" / "agentify"
CONTROL_PLANE = SCRIPT_DIR / "control_plane.py"
DATA_DIR = Path(os.environ.get("AGENTIFY_DIR", ".agentify")).resolve()
ADMIN_TOKEN = os.environ.get("AGENTIFY_ADMIN_TOKEN", "").strip()
HOST = os.environ.get("AGENTIFY_HOST", "127.0.0.1")


def _run(args: list[str], *, timeout: int = 30, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd or os.getcwd())


def _control_plane(*args: str, timeout: int = 30) -> dict:
    result = _run(["python3", str(CONTROL_PLANE), *args], timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "control plane failed")
    output = result.stdout.strip()
    return json.loads(output) if output else {}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "agentify/2"

    def _parse_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        payload = self.rfile.read(length)
        return json.loads(payload.decode("utf-8"))

    def _parse_query(self) -> dict[str, list[str]]:
        return parse_qs(urlparse(self.path).query)

    def _list_issues(self, label: str) -> list[dict]:
        try:
            result = _run(
                ["gh", "issue", "list", "--label", label, "--state", "open", "--limit", "25", "--json", "number,title,url"],
                timeout=15,
            )
            if result.returncode != 0:
                return []
            return json.loads(result.stdout or "[]")
        except Exception:
            return []

    def _reserved_existing_issue_numbers(self) -> set[int]:
        reserved: set[int] = set()
        for epic in list_epics(str(DATA_DIR)):
            if epic.get("kind") != "existing-issues":
                continue
            for proposal in epic.get("proposals", []):
                if proposal.get("status") in {"rejected", "complete"}:
                    continue
                for issue_number in proposal.get("issue_numbers", []):
                    if isinstance(issue_number, int):
                        reserved.add(issue_number)
                    elif isinstance(issue_number, str) and issue_number.isdigit():
                        reserved.add(int(issue_number))
        return reserved

    def _is_authorized(self) -> bool:
        if not ADMIN_TOKEN:
            return True
        return self.headers.get("X-Agentify-Token", "") == ADMIN_TOKEN

    def _require_auth(self) -> bool:
        if self._is_authorized():
            return True
        self._json_response({"error": "Forbidden"}, 403)
        return False

    def _json_response(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_index(self) -> None:
        html = HTML_FILE.read_text(encoding="utf-8")
        html = html.replace("__AGENTIFY_ADMIN_TOKEN__", json.dumps(ADMIN_TOKEN))
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_state(self) -> None:
        snapshot = load_snapshot(str(DATA_DIR))
        state = dict(snapshot.state)
        workers = {}
        workers_dir = DATA_DIR / "workers"
        for worker_id, payload in snapshot.workers.items():
            pid_path = workers_dir / f"{worker_id}.pid"
            active = False
            if pid_path.exists():
                try:
                    pid = int(pid_path.read_text().strip() or "0")
                    os.kill(pid, 0)
                    active = True
                except Exception:
                    active = False
            payload = dict(payload)
            payload["active"] = active
            workers[worker_id] = payload
        state["workers"] = workers
        state["queued_issues"] = self._list_issues("agent")
        state["wip_issues"] = self._list_issues("agent-wip")
        self._json_response(state)

    def _serve_events(self) -> None:
        query = self._parse_query()
        after = int(query.get("after", ["0"])[0] or 0)
        events = list_events(after, str(DATA_DIR))
        total = after + len(events)
        if events:
            total = events[-1]["id"]
        self._json_response({"events": events, "total": total})

    def _serve_event_stream(self) -> None:
        query = self._parse_query()
        after = int(query.get("after", ["0"])[0] or 0)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        for _ in range(300):
            events = list_events(after, str(DATA_DIR))
            for event in events:
                payload = json.dumps(event)
                self.wfile.write(f"id: {event['id']}\ndata: {payload}\n\n".encode("utf-8"))
                self.wfile.flush()
                after = event["id"]
            self.wfile.write(b": keep-alive\n\n")
            self.wfile.flush()
            time.sleep(1)

    def _serve_worker_log(self) -> None:
        query = self._parse_query()
        issue = (query.get("issue", [""])[0] or "").strip()
        if not issue:
            self._json_response({"error": "Missing issue"}, 400)
            return
        log_file = DATA_DIR / "logs" / f"{issue}.log"
        if not log_file.exists():
            self._json_response({"issue": issue, "exists": False, "content": ""})
            return
        lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
        content = "\n".join(lines[-300:])
        self._json_response({"issue": issue, "exists": True, "content": content, "line_count": len(lines)})

    def _serve_worker_log_stream(self) -> None:
        query = self._parse_query()
        issue = (query.get("issue", [""])[0] or "").strip()
        if not issue:
            self._json_response({"error": "Missing issue"}, 400)
            return
        log_file = DATA_DIR / "logs" / f"{issue}.log"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        position = 0
        for _ in range(300):
            if log_file.exists():
                with log_file.open("r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(position)
                    chunk = handle.read()
                    position = handle.tell()
                if chunk:
                    payload = json.dumps({"content": chunk})
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
            self.wfile.write(b": keep-alive\n\n")
            self.wfile.flush()
            time.sleep(1)

    def _serve_epics(self) -> None:
        self._json_response({"epics": list_epics(str(DATA_DIR))})

    def _serve_proposals(self) -> None:
        self._json_response({"proposals": list_proposals(str(DATA_DIR))})

    def _serve_interviews(self) -> None:
        self._json_response({"interviews": list_interviews(str(DATA_DIR))})

    def _serve_triage(self) -> None:
        try:
            result = _run(
                ["gh", "issue", "list", "--state", "open", "--limit", "50", "--json", "number,title,body,labels,createdAt"],
                timeout=15,
            )
            if result.returncode != 0:
                self._json_response({"error": result.stderr.strip(), "issues": []}, 500)
                return
            all_issues = json.loads(result.stdout or "[]")
            reserved = self._reserved_existing_issue_numbers()
            excluded = {"agent", "agent-wip", "agent-skip"}
            issues = []
            for issue in all_issues:
                labels = {label["name"] for label in issue.get("labels", [])}
                if labels & excluded or issue["number"] in reserved:
                    continue
                issues.append(
                    {
                        "number": issue["number"],
                        "title": issue["title"],
                        "body": (issue.get("body") or "")[:300],
                        "labels": sorted(labels),
                        "created_at": issue.get("createdAt", ""),
                    }
                )
            self._json_response({"issues": issues})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Timed out fetching issues", "issues": []}, 504)
        except Exception as exc:
            self._json_response({"error": str(exc), "issues": []}, 500)

    def _handle_plan(self, body: dict) -> None:
        description = body.get("description", "")
        if not description:
            self._json_response({"error": "No description"}, 400)
            return
        script = f"""
source "{SCRIPT_DIR / 'loop.sh'}"
source "{SCRIPT_DIR / 'planner.sh'}"
AGENTIFY_DIR="{DATA_DIR}"
epic_id=$(plan_epic {json.dumps(description)})
echo "$epic_id"
"""
        try:
            result = _run(["bash", "-c", script], timeout=180)
            epic_id = result.stdout.strip().split("\n")[-1]
            epic = get_epic(epic_id, str(DATA_DIR))
            if not epic:
                self._json_response({"error": "Planning failed", "stderr": result.stderr}, 500)
                return
            self._json_response({"epic": epic})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Planning timed out"}, 504)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_group_existing(self) -> None:
        script = f"""
source "{SCRIPT_DIR / 'loop.sh'}"
source "{SCRIPT_DIR / 'planner.sh'}"
AGENTIFY_DIR="{DATA_DIR}"
epic_id=$(group_existing_issues)
echo "$epic_id"
"""
        try:
            result = _run(["bash", "-c", script], timeout=240)
            epic_id = result.stdout.strip().split("\n")[-1]
            epic = get_epic(epic_id, str(DATA_DIR))
            if not epic:
                self._json_response({"error": "Grouping failed", "stderr": result.stderr}, 500)
                return
            self._json_response({"epic": epic})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Grouping timed out"}, 504)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_approve(self, body: dict) -> None:
        try:
            payload = _control_plane("approve-epic", "--repo", os.getcwd(), body.get("epic_id", ""), str(body.get("index", 0)))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_reject(self, body: dict) -> None:
        try:
            payload = _control_plane("reject-epic", body.get("epic_id", ""), str(body.get("index", 0)))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_approve_all(self, body: dict) -> None:
        try:
            payload = _control_plane("approve-all", "--repo", os.getcwd(), body.get("epic_id", ""))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_triage_assign(self, body: dict) -> None:
        try:
            if body.get("number") in self._reserved_existing_issue_numbers():
                self._json_response({"error": "Issue is already reserved by an epic grouping"}, 409)
                return
            payload = _control_plane("triage-assign", "--repo", os.getcwd(), str(body.get("number")))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_triage_skip(self, body: dict) -> None:
        try:
            payload = _control_plane("triage-skip", "--repo", os.getcwd(), str(body.get("number")))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_manage(self, body: dict) -> None:
        try:
            args = ["spawn-manage", "--repo", os.getcwd()]
            if body.get("pr_number"):
                args.extend(["--pr-number", str(body["pr_number"])])
            if body.get("number"):
                args.append(str(body["number"]))
            payload = _control_plane(*args)
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_proposal_accept(self, body: dict) -> None:
        try:
            payload = _control_plane("accept-feature-proposal", "--repo", os.getcwd(), str(body.get("id")))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_proposal_dismiss(self, body: dict) -> None:
        try:
            payload = _control_plane("dismiss-feature-proposal", str(body.get("id")))
            self._json_response(payload)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _extract_json(self, text: str) -> dict | None:
        start = text.find("{")
        if start == -1:
            return None
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:index + 1])
                    except json.JSONDecodeError:
                        return None
        return None

    def _handle_interview_start(self, body: dict) -> None:
        description = body.get("description", "")
        if not description:
            self._json_response({"error": "No description"}, 400)
            return
        try:
            template = (SCRIPT_DIR.parent / "prompts" / "interview.md").read_text(encoding="utf-8")
            repo_ctx = ""
            if Path("product_brief.md").exists():
                repo_ctx = Path("product_brief.md").read_text(encoding="utf-8")
            prompt = template.replace("{{FEATURE_REQUEST}}", description).replace("{{REPO_CONTEXT}}", repo_ctx)
            result = _run(["claude", "-p", "--model", os.environ.get("CLAUDE_MODEL", "claude-opus-4-6"), prompt], timeout=120)
            if result.returncode != 0:
                self._json_response({"error": "Claude call failed", "stderr": result.stderr}, 500)
                return
            parsed = self._extract_json(result.stdout)
            if not parsed:
                self._json_response({"error": "Failed to parse interview response"}, 500)
                return
            interview = {
                "id": str(int(time.time())),
                "description": description,
                "status": "interviewing",
                "questions": parsed.get("questions", []),
                "initial_understanding": parsed.get("initial_understanding", ""),
                "answers": {},
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            save_interview(interview, str(DATA_DIR))
            self._json_response({"interview": interview})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Interview timed out"}, 504)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def _handle_interview_answer(self, body: dict) -> None:
        interview_id = body.get("id", "")
        if not interview_id:
            self._json_response({"error": "No interview id"}, 400)
            return
        interview = get_interview(interview_id, str(DATA_DIR))
        if not interview:
            self._json_response({"error": "Interview not found"}, 404)
            return
        interview.setdefault("answers", {}).update(body.get("answers", {}))
        if len(interview["answers"]) >= len(interview.get("questions", [])):
            interview["status"] = "ready_to_plan"
        save_interview(interview, str(DATA_DIR))
        self._json_response({"interview": interview})

    def _handle_interview_plan(self, body: dict) -> None:
        interview_id = body.get("id", "")
        if not interview_id:
            self._json_response({"error": "No interview id"}, 400)
            return
        interview = get_interview(interview_id, str(DATA_DIR))
        if not interview:
            self._json_response({"error": "Interview not found"}, 404)
            return
        if interview.get("status") != "ready_to_plan":
            self._json_response({"error": f"Interview status is {interview.get('status')}, not ready_to_plan"}, 400)
            return
        parts = [interview["description"], "", "## Clarifications", ""]
        for index, question in enumerate(interview.get("questions", [])):
            answer = interview.get("answers", {}).get(str(index), "")
            parts.append(f"**Q:** {question.get('question', '')}")
            parts.append(f"**A:** {answer}")
            parts.append("")
        enriched = "\n".join(parts)
        script = f"""
source "{SCRIPT_DIR / 'loop.sh'}"
source "{SCRIPT_DIR / 'planner.sh'}"
AGENTIFY_DIR="{DATA_DIR}"
epic_id=$(plan_epic {json.dumps(enriched)})
echo "$epic_id"
"""
        try:
            result = _run(["bash", "-c", script], timeout=240)
            epic_id = result.stdout.strip().split("\n")[-1]
            interview["status"] = "planned"
            interview["epic_id"] = epic_id
            save_interview(interview, str(DATA_DIR))
            self._json_response({"interview": interview, "epic": get_epic(epic_id, str(DATA_DIR))})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Planning timed out"}, 504)
        except Exception as exc:
            self._json_response({"error": str(exc)}, 500)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/":
            self._serve_index()
        elif path == "/state":
            self._serve_state()
        elif path == "/events":
            self._serve_events()
        elif path == "/stream":
            self._serve_event_stream()
        elif path == "/worker-log":
            self._serve_worker_log()
        elif path == "/worker-log/stream":
            self._serve_worker_log_stream()
        elif path == "/epics":
            self._serve_epics()
        elif path == "/triage":
            self._serve_triage()
        elif path == "/proposals":
            self._serve_proposals()
        elif path == "/interviews":
            self._serve_interviews()
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        if not self._require_auth():
            return
        path = urlparse(self.path).path
        body = self._parse_body()
        if path == "/plan":
            self._handle_plan(body)
        elif path == "/group-existing":
            self._handle_group_existing()
        elif path == "/approve":
            self._handle_approve(body)
        elif path == "/reject":
            self._handle_reject(body)
        elif path == "/approve-all":
            self._handle_approve_all(body)
        elif path == "/triage/assign":
            self._handle_triage_assign(body)
        elif path == "/triage/skip":
            self._handle_triage_skip(body)
        elif path == "/manage":
            self._handle_manage(body)
        elif path == "/proposals/accept":
            self._handle_proposal_accept(body)
        elif path == "/proposals/dismiss":
            self._handle_proposal_dismiss(body)
        elif path == "/interview/start":
            self._handle_interview_start(body)
        elif path == "/interview/answer":
            self._handle_interview_answer(body)
        elif path == "/interview/plan":
            self._handle_interview_plan(body)
        else:
            self.send_error(404)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:
        return


class ThreadedServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", nargs="?", type=int, default=4242)
    parser.add_argument("--host", default=HOST)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    global HOST
    HOST = args.host
    init_db(str(DATA_DIR))
    server = ThreadedServer((HOST, args.port), Handler)
    print(f"  Dashboard: http://{HOST}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
