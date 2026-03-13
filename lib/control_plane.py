#!/usr/bin/env python3
"""Control-plane CLI for agentify state and GitHub mutations."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any

try:
    from state_store import (
        delete_document,
        delete_keys,
        emit_event,
        get_epic,
        get_interview,
        get_kv,
        get_proposal,
        increment_kv,
        init_db,
        list_epics,
        list_events,
        list_interviews,
        list_proposals,
        list_workers,
        save_epic,
        save_interview,
        save_proposal,
        set_kv,
        worker_delete,
        worker_get,
        worker_replace,
        worker_set,
    )
except ModuleNotFoundError:
    from lib.state_store import (
        delete_document,
        delete_keys,
        emit_event,
        get_epic,
        get_interview,
        get_kv,
        get_proposal,
        increment_kv,
        init_db,
        list_epics,
        list_events,
        list_interviews,
        list_proposals,
        list_workers,
        save_epic,
        save_interview,
        save_proposal,
        set_kv,
        worker_delete,
        worker_get,
        worker_replace,
        worker_set,
    )


def _print(payload: Any) -> None:
    print(json.dumps(payload))


def _gh(args: list[str], cwd: str | None = None, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["gh", *args],
        cwd=cwd or os.getcwd(),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _require_ok(result: subprocess.CompletedProcess[str]) -> str:
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "command failed")
    return result.stdout.strip()


def _load_json_arg(value: str) -> Any:
    return json.loads(value)


def _epic_body_with_metadata(epic: dict[str, Any], proposal: dict[str, Any]) -> str:
    metadata = {
        "validation_commands": proposal.get("validation_commands", []),
        "required_checks": proposal.get("required_checks", []),
        "files_of_interest": proposal.get("files_of_interest", []),
    }
    body = proposal.get("body", "")
    return (
        f"{body}\n\n---\n*Part of epic: {epic['title']}*\n\n"
        "```agentify\n"
        f"{json.dumps(metadata, sort_keys=True)}\n"
        "```"
    )


def cmd_init(_: argparse.Namespace) -> int:
    init_db()
    _print({"ok": True})
    return 0


def cmd_kv_get(args: argparse.Namespace) -> int:
    value = get_kv(args.key, default=args.default)
    print(value)
    return 0


def cmd_kv_set(args: argparse.Namespace) -> int:
    set_kv(args.key, args.value)
    _print({"ok": True})
    return 0


def cmd_kv_increment(args: argparse.Namespace) -> int:
    value = increment_kv(args.key, default=args.default)
    print(value)
    return 0


def cmd_kv_delete(args: argparse.Namespace) -> int:
    delete_keys(args.keys)
    _print({"ok": True})
    return 0


def cmd_emit_event(args: argparse.Namespace) -> int:
    event_id = emit_event(args.type, args.msg)
    _print({"ok": True, "id": event_id})
    return 0


def cmd_list_events(args: argparse.Namespace) -> int:
    _print({"events": list_events(args.after), "total": len(list_events(args.after)) + args.after})
    return 0


def cmd_worker_get(args: argparse.Namespace) -> int:
    payload = worker_get(args.worker_id)
    if args.key:
        print(payload.get(args.key, ""))
        return 0
    _print(payload)
    return 0


def cmd_worker_set(args: argparse.Namespace) -> int:
    value = _load_json_arg(args.value) if args.json else args.value
    payload = worker_set(args.worker_id, args.key, value)
    _print(payload)
    return 0


def cmd_worker_replace(args: argparse.Namespace) -> int:
    worker_replace(args.worker_id, _load_json_arg(args.json_payload))
    _print({"ok": True})
    return 0


def cmd_worker_delete(args: argparse.Namespace) -> int:
    worker_delete(args.worker_id)
    _print({"ok": True})
    return 0


def cmd_worker_list(_: argparse.Namespace) -> int:
    _print(list_workers())
    return 0


def cmd_epic_get(args: argparse.Namespace) -> int:
    payload = get_epic(args.epic_id)
    _print(payload or {})
    return 0


def cmd_epic_list(_: argparse.Namespace) -> int:
    _print({"epics": list_epics()})
    return 0


def cmd_epic_save(args: argparse.Namespace) -> int:
    payload = _load_json_arg(args.json_payload)
    save_epic(payload)
    _print({"ok": True})
    return 0


def cmd_proposal_get(args: argparse.Namespace) -> int:
    payload = get_proposal(args.proposal_id)
    _print(payload or {})
    return 0


def cmd_proposal_list(_: argparse.Namespace) -> int:
    _print({"proposals": list_proposals()})
    return 0


def cmd_proposal_save(args: argparse.Namespace) -> int:
    payload = _load_json_arg(args.json_payload)
    save_proposal(payload)
    _print({"ok": True})
    return 0


def cmd_interview_get(args: argparse.Namespace) -> int:
    payload = get_interview(args.interview_id)
    _print(payload or {})
    return 0


def cmd_interview_list(_: argparse.Namespace) -> int:
    _print({"interviews": list_interviews()})
    return 0


def cmd_interview_save(args: argparse.Namespace) -> int:
    payload = _load_json_arg(args.json_payload)
    save_interview(payload)
    _print({"ok": True})
    return 0


def cmd_interview_delete(args: argparse.Namespace) -> int:
    delete_document("interviews", "interview_id", args.interview_id)
    _print({"ok": True})
    return 0


def approve_epic_action(epic_id: str, index: int, repo: str) -> dict[str, Any]:
    epic = get_epic(epic_id)
    if not epic:
        raise RuntimeError("Epic not found")
    proposal = epic["proposals"][index]
    if proposal["status"] != "pending":
        raise RuntimeError(f"Already {proposal['status']}")

    if epic.get("kind") == "existing-issues":
        waves = proposal.get("waves") or []
        first_wave = waves[0] if waves else []
        if not first_wave:
            raise RuntimeError("Proposal has no execution wave")
        for num in first_wave:
            _require_ok(_gh(["issue", "edit", str(num), "--add-label", "agent"], cwd=repo))
        epic["proposals"][index]["status"] = "approved"
        epic["proposals"][index]["started_waves"] = 1
        epic["status"] = "active"
        save_epic(epic)
        emit_event("group_approved", f"Approved existing issue group: {proposal.get('title', '')}")
        return {"issue_numbers": first_wave}

    body = _epic_body_with_metadata(epic, proposal)
    issue_url = _require_ok(
        _gh(
            ["issue", "create", "--title", proposal["title"], "--body", body, "--label", "agent"],
            cwd=repo,
        )
    )
    issue_num = int(issue_url.rstrip("/").split("/")[-1])
    epic["proposals"][index]["status"] = "approved"
    epic["proposals"][index]["issue_number"] = issue_num
    if not any(p["status"] == "pending" for p in epic["proposals"]):
        epic["status"] = "active"
    save_epic(epic)
    emit_event("issue_approved", f"Approved #{issue_num}: {proposal['title']} (epic: {epic_id})")
    return {"issue_number": issue_num, "url": issue_url}


def cmd_approve_epic(args: argparse.Namespace) -> int:
    _print(approve_epic_action(args.epic_id, args.index, args.repo))
    return 0


def cmd_reject_epic(args: argparse.Namespace) -> int:
    epic = get_epic(args.epic_id)
    if not epic:
        raise RuntimeError("Epic not found")
    epic["proposals"][args.index]["status"] = "rejected"
    if not any(p["status"] == "pending" for p in epic["proposals"]):
        epic["status"] = "active"
    save_epic(epic)
    _print({"ok": True})
    return 0


def cmd_approve_all(args: argparse.Namespace) -> int:
    epic = get_epic(args.epic_id)
    if not epic:
        raise RuntimeError("Epic not found")
    results: list[dict[str, Any]] = []
    for index, proposal in enumerate(epic.get("proposals", [])):
        if proposal.get("status") != "pending":
            continue
        try:
            approve_epic_action(args.epic_id, index, args.repo)
        except Exception:
            continue
        epic = get_epic(args.epic_id) or epic
        proposal = epic["proposals"][index]
        if epic.get("kind") == "existing-issues":
            results.append({"index": index, "issue_numbers": proposal.get("waves", [[]])[0]})
        else:
            results.append({"index": index, "issue_number": proposal.get("issue_number")})
    epic = get_epic(args.epic_id) or epic
    epic["status"] = "active"
    save_epic(epic)
    _print({"approved": results})
    return 0


def cmd_triage_assign(args: argparse.Namespace) -> int:
    _require_ok(_gh(["issue", "edit", str(args.number), "--add-label", "agent"], cwd=args.repo))
    emit_event("triage_assigned", f"Assigned #{args.number} to agent")
    _print({"ok": True, "number": args.number})
    return 0


def cmd_triage_skip(args: argparse.Namespace) -> int:
    _require_ok(_gh(["issue", "edit", str(args.number), "--add-label", "agent-skip"], cwd=args.repo))
    emit_event("triage_skipped", f"Skipped #{args.number}")
    _print({"ok": True, "number": args.number})
    return 0


def cmd_accept_feature_proposal(args: argparse.Namespace) -> int:
    proposal = get_proposal(args.proposal_id)
    if not proposal:
        raise RuntimeError("Proposal not found")
    if proposal.get("status") != "pending":
        raise RuntimeError(f"Already {proposal.get('status')}")
    created = []
    for feature in proposal.get("features", []):
        body = (
            f"{feature.get('description', '')}\n\n"
            f"**Rationale:** {feature.get('rationale', '')}\n"
            f"**Priority:** {feature.get('priority', 'medium')}\n\n"
            "---\n*Proposed by agentify ideation*"
        )
        issue_url = _require_ok(
            _gh(
                ["issue", "create", "--title", feature.get("title", "Untitled feature"), "--body", body, "--label", "agent"],
                cwd=args.repo,
            )
        )
        created.append(
            {
                "title": feature.get("title", "Untitled feature"),
                "number": int(issue_url.rstrip("/").split("/")[-1]),
                "url": issue_url,
            }
        )
    proposal["status"] = "accepted"
    proposal["created_issues"] = created
    save_proposal(proposal)
    emit_event("proposal_accepted", f"Accepted proposal {args.proposal_id}")
    _print({"ok": True, "created": created})
    return 0


def cmd_dismiss_feature_proposal(args: argparse.Namespace) -> int:
    proposal = get_proposal(args.proposal_id)
    if not proposal:
        raise RuntimeError("Proposal not found")
    proposal["status"] = "dismissed"
    save_proposal(proposal)
    emit_event("proposal_dismissed", f"Dismissed proposal {args.proposal_id}")
    _print({"ok": True})
    return 0


def cmd_spawn_manage(args: argparse.Namespace) -> int:
    agentify_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "agentify")
    cmd = [agentify_bin, "manage"]
    if args.pr_number:
        cmd.extend(["--pr", str(args.pr_number)])
        if args.number:
            cmd.append(str(args.number))
    elif args.number:
        cmd.append(str(args.number))
    else:
        raise RuntimeError("Missing issue number or PR number")
    subprocess.Popen(
        cmd,
        cwd=args.repo,
        env={**os.environ, "AGENTIFY_DIR": os.environ.get("AGENTIFY_DIR", ".agentify")},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    _print({"ok": True, "number": args.number, "pr_number": args.pr_number})
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init").set_defaults(func=cmd_init)

    kv_get = subparsers.add_parser("kv-get")
    kv_get.add_argument("key")
    kv_get.add_argument("--default", default="")
    kv_get.set_defaults(func=cmd_kv_get)

    kv_set = subparsers.add_parser("kv-set")
    kv_set.add_argument("key")
    kv_set.add_argument("value")
    kv_set.set_defaults(func=cmd_kv_set)

    kv_inc = subparsers.add_parser("kv-increment")
    kv_inc.add_argument("key")
    kv_inc.add_argument("--default", type=int, default=0)
    kv_inc.set_defaults(func=cmd_kv_increment)

    kv_delete = subparsers.add_parser("kv-delete")
    kv_delete.add_argument("keys", nargs="+")
    kv_delete.set_defaults(func=cmd_kv_delete)

    event_emit = subparsers.add_parser("event-emit")
    event_emit.add_argument("type")
    event_emit.add_argument("msg")
    event_emit.set_defaults(func=cmd_emit_event)

    event_list = subparsers.add_parser("event-list")
    event_list.add_argument("--after", type=int, default=0)
    event_list.set_defaults(func=cmd_list_events)

    worker_get_parser = subparsers.add_parser("worker-get")
    worker_get_parser.add_argument("worker_id")
    worker_get_parser.add_argument("--key")
    worker_get_parser.set_defaults(func=cmd_worker_get)

    worker_set_parser = subparsers.add_parser("worker-set")
    worker_set_parser.add_argument("worker_id")
    worker_set_parser.add_argument("key")
    worker_set_parser.add_argument("value")
    worker_set_parser.add_argument("--json", action="store_true")
    worker_set_parser.set_defaults(func=cmd_worker_set)

    worker_replace_parser = subparsers.add_parser("worker-replace")
    worker_replace_parser.add_argument("worker_id")
    worker_replace_parser.add_argument("json_payload")
    worker_replace_parser.set_defaults(func=cmd_worker_replace)

    worker_delete_parser = subparsers.add_parser("worker-delete")
    worker_delete_parser.add_argument("worker_id")
    worker_delete_parser.set_defaults(func=cmd_worker_delete)

    subparsers.add_parser("worker-list").set_defaults(func=cmd_worker_list)

    epic_get = subparsers.add_parser("epic-get")
    epic_get.add_argument("epic_id")
    epic_get.set_defaults(func=cmd_epic_get)

    subparsers.add_parser("epic-list").set_defaults(func=cmd_epic_list)

    epic_save = subparsers.add_parser("epic-save")
    epic_save.add_argument("json_payload")
    epic_save.set_defaults(func=cmd_epic_save)

    proposal_get = subparsers.add_parser("proposal-get")
    proposal_get.add_argument("proposal_id")
    proposal_get.set_defaults(func=cmd_proposal_get)

    subparsers.add_parser("proposal-list").set_defaults(func=cmd_proposal_list)

    proposal_save = subparsers.add_parser("proposal-save")
    proposal_save.add_argument("json_payload")
    proposal_save.set_defaults(func=cmd_proposal_save)

    interview_get = subparsers.add_parser("interview-get")
    interview_get.add_argument("interview_id")
    interview_get.set_defaults(func=cmd_interview_get)

    subparsers.add_parser("interview-list").set_defaults(func=cmd_interview_list)

    interview_save = subparsers.add_parser("interview-save")
    interview_save.add_argument("json_payload")
    interview_save.set_defaults(func=cmd_interview_save)

    interview_delete = subparsers.add_parser("interview-delete")
    interview_delete.add_argument("interview_id")
    interview_delete.set_defaults(func=cmd_interview_delete)

    approve_epic = subparsers.add_parser("approve-epic")
    approve_epic.add_argument("--repo", default=os.getcwd())
    approve_epic.add_argument("epic_id")
    approve_epic.add_argument("index", type=int)
    approve_epic.set_defaults(func=cmd_approve_epic)

    reject_epic = subparsers.add_parser("reject-epic")
    reject_epic.add_argument("epic_id")
    reject_epic.add_argument("index", type=int)
    reject_epic.set_defaults(func=cmd_reject_epic)

    approve_all = subparsers.add_parser("approve-all")
    approve_all.add_argument("--repo", default=os.getcwd())
    approve_all.add_argument("epic_id")
    approve_all.set_defaults(func=cmd_approve_all)

    triage_assign = subparsers.add_parser("triage-assign")
    triage_assign.add_argument("--repo", default=os.getcwd())
    triage_assign.add_argument("number", type=int)
    triage_assign.set_defaults(func=cmd_triage_assign)

    triage_skip = subparsers.add_parser("triage-skip")
    triage_skip.add_argument("--repo", default=os.getcwd())
    triage_skip.add_argument("number", type=int)
    triage_skip.set_defaults(func=cmd_triage_skip)

    accept_feature = subparsers.add_parser("accept-feature-proposal")
    accept_feature.add_argument("--repo", default=os.getcwd())
    accept_feature.add_argument("proposal_id")
    accept_feature.set_defaults(func=cmd_accept_feature_proposal)

    dismiss_feature = subparsers.add_parser("dismiss-feature-proposal")
    dismiss_feature.add_argument("proposal_id")
    dismiss_feature.set_defaults(func=cmd_dismiss_feature_proposal)

    spawn_manage = subparsers.add_parser("spawn-manage")
    spawn_manage.add_argument("--repo", default=os.getcwd())
    spawn_manage.add_argument("--pr-number")
    spawn_manage.add_argument("number", nargs="?")
    spawn_manage.set_defaults(func=cmd_spawn_manage)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
