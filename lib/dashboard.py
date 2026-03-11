#!/usr/bin/env python3
"""agentify dashboard — monitoring + planning UI."""
import http.server
import json
import os
import subprocess
import sys
from socketserver import ThreadingMixIn

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4242
DATA_DIR = os.environ.get("AGENTIFY_DIR", ".agentify")
HTML_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
AGENTIFY_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "agentify")


class Handler(http.server.BaseHTTPRequestHandler):
    def _list_issues(self, label):
        try:
            result = subprocess.run(
                ["gh", "issue", "list", "--label", label, "--state", "open", "--limit", "25",
                 "--json", "number,title,url"],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                return []
            return json.loads(result.stdout) if result.stdout.strip() else []
        except Exception:
            return []

    def do_GET(self):
        if self.path == "/":
            self._serve_file(HTML_FILE, "text/html")
        elif self.path == "/state":
            self._serve_state()
        elif self.path.startswith("/events"):
            self._serve_events()
        elif self.path.startswith("/worker-log"):
            self._serve_worker_log()
        elif self.path == "/epics":
            self._serve_epics()
        elif self.path == "/triage":
            self._serve_triage()
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path == "/plan":
            self._handle_plan(body)
        elif self.path == "/group-existing":
            self._handle_group_existing()
        elif self.path == "/approve":
            self._handle_approve(body)
        elif self.path == "/reject":
            self._handle_reject(body)
        elif self.path == "/approve-all":
            self._handle_approve_all(body)
        elif self.path == "/triage/assign":
            self._handle_triage_assign(body)
        elif self.path == "/triage/skip":
            self._handle_triage_skip(body)
        else:
            self.send_error(404)

    def _serve_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_error(404)

    def _serve_state(self):
        state = {}
        try:
            with open(os.path.join(DATA_DIR, "state.json")) as f:
                state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            pass

        # Merge workers
        workers = {}
        workers_dir = os.path.join(DATA_DIR, "workers")
        if os.path.isdir(workers_dir):
            for fname in os.listdir(workers_dir):
                if fname.endswith(".json"):
                    try:
                        with open(os.path.join(workers_dir, fname)) as f:
                            workers[fname[:-5]] = json.load(f)
                    except (json.JSONDecodeError, FileNotFoundError):
                        pass
        state["workers"] = workers
        state["queued_issues"] = self._list_issues("agent")
        state["wip_issues"] = self._list_issues("agent-wip")

        self._json_response(state)

    def _serve_events(self):
        after = 0
        if "?" in self.path:
            for param in self.path.split("?")[1].split("&"):
                if "=" in param:
                    k, v = param.split("=", 1)
                    if k == "after":
                        after = int(v)

        events = []
        try:
            with open(os.path.join(DATA_DIR, "events.jsonl")) as f:
                for i, line in enumerate(f):
                    if i >= after:
                        line = line.strip()
                        if line:
                            try:
                                events.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
        except FileNotFoundError:
            pass

        self._json_response({"events": events, "total": after + len(events)})

    def _serve_epics(self):
        epics = []
        epics_dir = os.path.join(DATA_DIR, "epics")
        if os.path.isdir(epics_dir):
            for fname in sorted(os.listdir(epics_dir)):
                if fname.endswith(".json"):
                    try:
                        with open(os.path.join(epics_dir, fname)) as f:
                            epics.append(json.load(f))
                    except (json.JSONDecodeError, FileNotFoundError):
                        pass
        self._json_response({"epics": epics})

    def _serve_worker_log(self):
        issue = None
        if "?" in self.path:
            for param in self.path.split("?", 1)[1].split("&"):
                if "=" in param:
                    k, v = param.split("=", 1)
                    if k == "issue":
                        issue = v
                        break

        if not issue or not issue.isdigit():
            self._json_response({"error": "Missing issue"}, 400)
            return

        log_file = os.path.join(DATA_DIR, "logs", f"{issue}.log")
        try:
            with open(log_file, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except FileNotFoundError:
            self._json_response({"issue": int(issue), "exists": False, "content": ""})
            return

        content = "".join(lines[-300:])
        self._json_response({
            "issue": int(issue),
            "exists": True,
            "content": content,
            "line_count": len(lines),
        })

    def _reserved_existing_issue_numbers(self):
        reserved = set()
        epics_dir = os.path.join(DATA_DIR, "epics")
        if not os.path.isdir(epics_dir):
            return reserved

        for fname in os.listdir(epics_dir):
            if not fname.endswith(".json"):
                continue
            try:
                with open(os.path.join(epics_dir, fname)) as f:
                    epic = json.load(f)
            except (json.JSONDecodeError, FileNotFoundError):
                continue

            if epic.get("kind") != "existing-issues":
                continue

            for proposal in epic.get("proposals", []):
                if proposal.get("status") in {"rejected", "complete"}:
                    continue
                for num in proposal.get("issue_numbers", []):
                    if isinstance(num, int):
                        reserved.add(num)

        return reserved

    def _handle_plan(self, body):
        description = body.get("description", "")
        if not description:
            self._json_response({"error": "No description"}, 400)
            return

        # Shell out to the planner
        # We source loop.sh + planner.sh and call plan_epic
        script = f"""
source "{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'loop.sh')}"
source "{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'planner.sh')}"
AGENTIFY_DIR="{DATA_DIR}"
EVENTS_FILE="{DATA_DIR}/events.jsonl"
STATE_FILE="{DATA_DIR}/state.json"
epic_id=$(plan_epic {json.dumps(description)})
echo "$epic_id"
"""
        try:
            result = subprocess.run(
                ["bash", "-c", script],
                capture_output=True, text=True, timeout=120,
                env={**os.environ, "AGENTIFY_DIR": DATA_DIR}
            )
            epic_id = result.stdout.strip().split("\n")[-1]

            # Read the epic file
            epic_file = os.path.join(DATA_DIR, "epics", f"{epic_id}.json")
            if os.path.exists(epic_file):
                with open(epic_file) as f:
                    epic = json.load(f)
                self._json_response({"epic": epic})
            else:
                self._json_response({"error": "Planning failed", "stderr": result.stderr}, 500)
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Planning timed out"}, 504)
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _handle_group_existing(self):
        script = f"""
source "{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'loop.sh')}"
source "{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'planner.sh')}"
AGENTIFY_DIR="{DATA_DIR}"
EVENTS_FILE="{DATA_DIR}/events.jsonl"
STATE_FILE="{DATA_DIR}/state.json"
epic_id=$(group_existing_issues)
echo "$epic_id"
"""
        try:
            result = subprocess.run(
                ["bash", "-c", script],
                capture_output=True, text=True, timeout=180,
                env={**os.environ, "AGENTIFY_DIR": DATA_DIR}
            )
            epic_id = result.stdout.strip().split("\n")[-1]

            epic_file = os.path.join(DATA_DIR, "epics", f"{epic_id}.json")
            if os.path.exists(epic_file):
                with open(epic_file) as f:
                    epic = json.load(f)
                self._json_response({"epic": epic})
            else:
                self._json_response({"error": "Grouping failed", "stderr": result.stderr}, 500)
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Grouping timed out"}, 504)
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _handle_approve(self, body):
        epic_id = body.get("epic_id", "")
        index = body.get("index", 0)
        epic_file = os.path.join(DATA_DIR, "epics", f"{epic_id}.json")

        if not os.path.exists(epic_file):
            self._json_response({"error": "Epic not found"}, 404)
            return

        try:
            with open(epic_file) as f:
                epic = json.load(f)

            proposal = epic["proposals"][index]
            if proposal["status"] != "pending":
                self._json_response({"error": f"Already {proposal['status']}"}, 400)
                return

            if epic.get("kind") == "existing-issues":
                waves = proposal.get("waves") or []
                first_wave = waves[0] if waves else []
                if not first_wave:
                    self._json_response({"error": "Proposal has no execution wave"}, 500)
                    return

                for num in first_wave:
                    result = subprocess.run(
                        ["gh", "issue", "edit", str(num), "--add-label", "agent"],
                        capture_output=True, text=True, timeout=30
                    )
                    if result.returncode != 0:
                        self._json_response({"error": result.stderr}, 500)
                        return

                epic["proposals"][index]["status"] = "approved"
                epic["proposals"][index]["started_waves"] = 1
                epic["status"] = "active"

                with open(epic_file, "w") as f:
                    json.dump(epic, f)

                self._json_response({"issue_numbers": first_wave})
                return

            # Create GitHub issue
            result = subprocess.run(
                ["gh", "issue", "create",
                 "--title", proposal["title"],
                 "--body", proposal["body"] + f"\n\n---\n*Part of epic: {epic['title']}*",
                 "--label", "agent"],
                capture_output=True, text=True, timeout=30
            )

            if result.returncode != 0:
                self._json_response({"error": result.stderr}, 500)
                return

            issue_url = result.stdout.strip()
            issue_num = int(issue_url.rstrip("/").split("/")[-1])

            epic["proposals"][index]["status"] = "approved"
            epic["proposals"][index]["issue_number"] = issue_num

            # Check if all resolved
            pending = sum(1 for p in epic["proposals"] if p["status"] == "pending")
            if pending == 0:
                epic["status"] = "active"

            with open(epic_file, "w") as f:
                json.dump(epic, f)

            self._json_response({"issue_number": issue_num, "url": issue_url})
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _handle_reject(self, body):
        epic_id = body.get("epic_id", "")
        index = body.get("index", 0)
        epic_file = os.path.join(DATA_DIR, "epics", f"{epic_id}.json")

        if not os.path.exists(epic_file):
            self._json_response({"error": "Epic not found"}, 404)
            return

        try:
            with open(epic_file) as f:
                epic = json.load(f)

            epic["proposals"][index]["status"] = "rejected"

            pending = sum(1 for p in epic["proposals"] if p["status"] == "pending")
            if pending == 0:
                epic["status"] = "active"

            with open(epic_file, "w") as f:
                json.dump(epic, f)

            self._json_response({"ok": True})
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _handle_approve_all(self, body):
        epic_id = body.get("epic_id", "")
        epic_file = os.path.join(DATA_DIR, "epics", f"{epic_id}.json")

        if not os.path.exists(epic_file):
            self._json_response({"error": "Epic not found"}, 404)
            return

        try:
            with open(epic_file) as f:
                epic = json.load(f)

            results = []
            for i, p in enumerate(epic["proposals"]):
                if p["status"] != "pending":
                    continue

                if epic.get("kind") == "existing-issues":
                    waves = p.get("waves") or []
                    first_wave = waves[0] if waves else []
                    if not first_wave:
                        continue

                    ok = True
                    for num in first_wave:
                        result = subprocess.run(
                            ["gh", "issue", "edit", str(num), "--add-label", "agent"],
                            capture_output=True, text=True, timeout=30
                        )
                        if result.returncode != 0:
                            ok = False
                            break

                    if ok:
                        epic["proposals"][i]["status"] = "approved"
                        epic["proposals"][i]["started_waves"] = 1
                        results.append({"index": i, "issue_numbers": first_wave})
                    continue

                result = subprocess.run(
                    ["gh", "issue", "create",
                     "--title", p["title"],
                     "--body", p["body"] + f"\n\n---\n*Part of epic: {epic['title']}*",
                     "--label", "agent"],
                    capture_output=True, text=True, timeout=30
                )

                if result.returncode == 0:
                    issue_url = result.stdout.strip()
                    issue_num = int(issue_url.rstrip("/").split("/")[-1])
                    epic["proposals"][i]["status"] = "approved"
                    epic["proposals"][i]["issue_number"] = issue_num
                    results.append({"index": i, "issue_number": issue_num})

            epic["status"] = "active"
            with open(epic_file, "w") as f:
                json.dump(epic, f)

            self._json_response({"approved": results})
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _serve_triage(self):
        """Fetch open issues not labeled agent/agent-wip/agent-skip."""
        try:
            result = subprocess.run(
                ["gh", "issue", "list", "--state", "open", "--limit", "50",
                 "--json", "number,title,body,labels,createdAt"],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                self._json_response({"error": result.stderr, "issues": []}, 500)
                return

            all_issues = json.loads(result.stdout) if result.stdout.strip() else []
            skip_labels = {"agent", "agent-wip", "agent-skip"}
            reserved = self._reserved_existing_issue_numbers()
            untriaged = []
            for issue in all_issues:
                issue_labels = {l["name"] for l in issue.get("labels", [])}
                if not issue_labels & skip_labels and issue["number"] not in reserved:
                    untriaged.append({
                        "number": issue["number"],
                        "title": issue["title"],
                        "body": (issue.get("body") or "")[:300],
                        "labels": [l["name"] for l in issue.get("labels", [])],
                        "created_at": issue.get("createdAt", ""),
                    })

            self._json_response({"issues": untriaged})
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Timed out fetching issues", "issues": []}, 504)
        except Exception as e:
            self._json_response({"error": str(e), "issues": []}, 500)

    def _handle_triage_assign(self, body):
        """Add 'agent' label to an issue."""
        num = body.get("number")
        if not num:
            self._json_response({"error": "No issue number"}, 400)
            return
        if num in self._reserved_existing_issue_numbers():
            self._json_response({"error": "Issue is already reserved by an epic grouping"}, 409)
            return
        try:
            result = subprocess.run(
                ["gh", "issue", "edit", str(num), "--add-label", "agent"],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                self._json_response({"error": result.stderr}, 500)
            else:
                self._json_response({"ok": True, "number": num})
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _handle_triage_skip(self, body):
        """Add 'agent-skip' label to an issue."""
        num = body.get("number")
        if not num:
            self._json_response({"error": "No issue number"}, 400)
            return
        try:
            result = subprocess.run(
                ["gh", "issue", "edit", str(num), "--add-label", "agent-skip"],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                self._json_response({"error": result.stderr}, 500)
            else:
                self._json_response({"ok": True, "number": num})
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _json_response(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        pass


class ThreadedServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedServer(("", PORT), Handler)
    print(f"  Dashboard: http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
