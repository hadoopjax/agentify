# agentify

Describe a feature. Claude and GPT-5.4 plan the issues. Codex codes them in parallel. Claude reviews and merges. You approve.

```
agentify plan "Add OAuth login with Google and GitHub"
agentify group
agentify approve <epic-id>
agentify run
```

## How it works

```
 You describe a feature
        ↓
 Claude proposes issues ←→ GPT-5.4 critiques
        ↓
 Dashboard: approve / reject each issue
        ↓
 ┌──────────────────────────────────────────┐
 │  Worker 1: #42 coding...                 │
 │  Worker 2: #43 reviewing...              │
 │  Worker 3: #44 merging...                │
 │          (parallel worktrees)            │
 └──────────────────────────────────────────┘
        ↓
 All issues done → epic complete → plan next
```

### Planning

1. `agentify plan "description"` or type it in the dashboard
2. Claude reads the codebase, proposes issues as structured JSON
3. GPT-5.4 critiques the plan — flags issues too large, spots gaps, adds suggestions
4. You approve/reject in the dashboard or via `agentify approve <id>`
5. Approved issues get the `agent` label

### Triage

Point agentify at a repo with existing issues:

1. `agentify triage` lists open issues that haven't been triaged
2. Dashboard shows a **Triage** section with all untriaged issues
3. **Assign** adds the `agent` label — the loop will pick it up
4. **Skip** adds `agent-skip` — hides it from future triage
5. Issues already labeled `agent`, `agent-wip`, or `agent-skip` are excluded

### Group Existing Issues

1. `agentify group` asks Claude to cluster eligible open issues into epic proposals
2. GPT-5.4 critiques the grouping for overlap, missing groups, and unsafe sequencing
3. agentify stores the approved-local proposal in `.agentify/epics/*.json`
4. Existing issues in a grouped proposal are reserved locally so triage will not assign them twice
5. Approving a grouped epic starts only its first execution wave by labeling those issues `agent`
6. Later waves unlock automatically after the prior wave closes
7. Existing-issue epics execute one issue at a time within each epic, so different epics can run in parallel without same-epic merge collisions
8. Existing-issue grouping is intentionally conservative: only 2-issue groups survive, and if GPT flags a Claude group as unsafe, agentify drops it and returns those issues to the ungrouped pool

### Execution

1. Dispatcher picks up to N issues labeled `agent` (default: 3 concurrent)
2. Each issue gets its own **git worktree** + background worker process
3. Worker claims the issue (swaps `agent` → `agent-wip` label)
4. Codex codes in the worktree — your checkout stays on `main`
5. Opens a PR, waits for CI
6. Claude reviews the diff — LGTM or requests changes
7. One retry with feedback if changes requested
8. Merges on approval, cleans up, picks next issue
9. When all epic issues close, marks epic complete

### Failure recovery

- `agent-wip` means the issue is actively owned by a live worker, not permanently removed from the queue.
- If a worker disappears and an issue is left in `agent-wip` without a live worker PID, the loop automatically re-queues it back to `agent` during normal polling. Recovery is not limited to process startup.
- Quota and billing failures pause new Codex dispatch globally instead of hammering the same issues.
- The pause window is stored in `.agentify/state.json`, survives restarts, and the dashboard shows the pause reason and retry time.
- Once the pause expires, any recovered `agent` issues are eligible for dispatch again automatically.
- Long-running work is governed by an inactivity watchdog, not a "must finish by X minutes" rule.
- The worker is allowed to keep running as long as its log is advancing or the worktree is changing.
- A hard absolute ceiling is optional, disabled by default, and intended only as an explicit operator override.
- High-confidence systemic repo blockers can be captured as deduplicated `agent-blocker` issues.
- This is intentionally narrow: agentify should create blocker issues for durable repo problems like broken test harnesses, not for ordinary task-local implementation failures.

## Setup

### Run locally

```bash
git clone https://github.com/hadoopjax/agentify.git
export PATH="$PATH:$(pwd)/agentify/bin"

# Requires: gh, codex, claude, jq, python3
cd your-repo

# Add agent-only keys
mkdir -p .agentify
cat > .agentify/agent.env <<EOF
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GH_TOKEN=ghp_...
EOF

agentify init
agentify run
```

agentify loads `.agentify/agent.env` only. Keep agent credentials separate from your app's `.env`.

### Run in Docker / Colima

```bash
git clone https://github.com/hadoopjax/agentify.git
cd your-repo

# Add agent-only keys
mkdir -p .agentify
cat > .agentify/agent.env <<EOF
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GH_TOKEN=ghp_...
EOF

# Start (builds image on first run)
/path/to/agentify/start.sh
```

`start.sh` builds the image if needed, reads `.agentify/agent.env`, injects only `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GH_TOKEN`, and starts the loop with dashboard.

Dashboard at `http://localhost:4242`. With Tailscale, accessible from any device on your tailnet.

## Commands

```
agentify run              Start the loop + dashboard
agentify plan "desc"      Plan an epic (Claude + GPT-5.4 dialectic)
agentify group            Group existing issues into epic proposals
agentify approve <id>     Approve all pending issues for an epic
agentify triage           Review existing issues — assign or skip
agentify init             Create agent/agent-wip/agent-skip labels
agentify test             Create a test issue
agentify dashboard        Open just the dashboard
agentify status           Show state + recent activity
```

## Options

```
--concurrency N      Parallel workers (default: 3)
--max-runs N         Stop after N completed runs (0 = unlimited)
--poll N             Seconds between idle checks (default: 60)
--port N             Dashboard port (default: 4242)
--codex-model M      Codex model (default: gpt-5.4)
--codex-effort L     Reasoning effort: low, medium, high (default: high)
--claude-model M     Claude model (default: claude-opus-4-6)
--no-dashboard       Skip the dashboard
```

## Per-repo config

Drop `.agentify/agents.md` in your repo with project-specific context:

```markdown
- We use pnpm, not npm
- API routes are in src/routes/
- All PRs must include tests
- Never modify the generated/ directory
```

Both Codex and Claude see this in every prompt.

## Design lineage

This project is not trying to be "a chatbot that writes code." It is trying to turn
agentic coding into an operational loop with durable state, clear role boundaries,
and observable execution.

The main design influences show up in concrete ways:

### 1. Karpathy / `autoresearch`: loop + external state + git as the machine

The core Karpathy idea is that the intelligence should not live only in a single
prompt transcript. It should operate against durable external state and keep going.

How that materializes here:

- `lib/loop.sh` is the long-running supervisor. It keeps polling for work, spawns
  workers, reaps them, advances epics, and never assumes a single request/response
  interaction is the whole system.
- `.agentify/state.json`, `.agentify/events.jsonl`, `.agentify/workers/`, and
  `.agentify/epics/` are the durable state machine. If the process restarts, the
  repo still contains the run state.
- Quota pause state also lives in `.agentify/state.json`, so temporary budget
  exhaustion becomes a resumable control state rather than a silent failure.
- `git worktree` usage in `lib/loop.sh` makes git itself part of the execution
  model: each issue gets an isolated branch and worktree instead of mutating the
  user's checkout directly.
- `lib/dashboard.py` and `lib/index.html` expose that state back to humans so the
  loop is inspectable rather than opaque.

Why we do it this way:

- repos are the durable substrate we already trust
- state should survive process restarts
- the agent should be observable as a system, not just as a conversation

### 2. Practical agent factory pattern (the Will Brown-style idea): role separation instead of one omni-agent

The second major idea is that planning, coding, and review should not all be done
by one undifferentiated agent run. Different steps have different failure modes.

How that materializes here:

- `lib/planner.sh` splits planning into a dialectic:
  - Claude proposes issue breakdowns or existing-issue groups
  - GPT-5.4 critiques those proposals before anything is approved
- `prompts/plan.md` and `prompts/plan-critique.md` make planning and critique
  separate prompt contracts rather than a single fuzzy planning call.
- `prompts/group-existing.md` and `prompts/group-existing-critique.md` apply the
  same pattern to grouping existing issues into safe, execution-ready epics.
- `prompts/code.md` is only for coding.
- `prompts/review.md` is only for review.
- `prompts/retry.md` is only for the bounded "fix the review feedback" retry pass.

Why we do it this way:

- planners are good at decomposition, but bad at self-policing scope
- coders are good at making local changes, but should not be the final judge of
  correctness
- review should happen against an actual diff and PR state, not against intent

### 3. Queue, claim, review, merge: software work as an explicit pipeline

This repo treats issues and PRs as the control surface for the system, not as side
effects after the fact.

How that materializes here:

- `agent`, `agent-wip`, and `agent-skip` labels are the queue protocol.
- `agentify triage`, `agentify group`, and `agentify approve` move work into or out
  of that queue in a controlled way.
- `lib/loop.sh` claims issues by swapping `agent` to `agent-wip`, then opens PRs,
  waits for CI, requests review, retries once, and merges.
- `lib/loop.sh` also reconciles orphaned `agent-wip` issues back into `agent`
  during normal polling, so queue state self-heals instead of relying on restarts.
- `check_epic_completion` and `advance_existing_issue_epics` in `lib/planner.sh`
  turn epic progress into explicit workflow transitions instead of informal notes.

Why we do it this way:

- human and agent work need the same visible state transitions
- concurrency only works if issue ownership is explicit
- PRs and CI are the natural governance layer for agent-written code

### 4. Conservative orchestration beats clever orchestration

The system intentionally leaves a lot of work ungrouped or pending instead of trying
to maximize automation at all costs.

How that materializes here:

- existing-issue grouping in `lib/planner.sh` is intentionally conservative:
  only simple 2-issue groups survive
- if GPT critiques a Claude grouping as unsafe, agentify drops it rather than trying
  to be clever and force it through
- existing-issue epics execute one wave at a time, and one issue at a time within a
  wave, even though cross-epic parallelism is allowed

Why we do it this way:

- false-positive grouping is worse than leaving work ungrouped
- parallelism is valuable only when it does not create hidden merge or schema
  collisions
- the product should fail toward legibility and safety, not toward "maximum agentic"

### 5. Live observability is part of the product

The dashboard is not decoration. It is part of the control model.

How that materializes here:

- `lib/dashboard.py` serves live state, events, epics, triage data, and worker log
  tails
- `lib/index.html` renders the queue, active workers, grouped epics, latest events,
  and live per-worker Codex logs
- `.agentify/logs/*.log` captures actual worker output so you can inspect what a
  running agent is doing, not just whether it is "active"

Why we do it this way:

- if an agent is writing code unattended, operators need more than a green dot
- debugging agent systems requires replayable state and readable logs
- trust comes from being able to inspect the machine while it is running

## Architecture

```
agentify/
├── bin/agentify           CLI entry point
├── lib/
│   ├── loop.sh            Dispatcher + parallel workers
│   ├── planner.sh         Epic planning (Claude + GPT-5.4)
│   ├── dashboard.py       Threaded HTTP server
│   └── index.html         Dashboard UI (south beach theme)
├── prompts/
│   ├── plan.md            Epic → issues breakdown
│   ├── plan-critique.md   GPT-5.4 plan review
│   ├── code.md            Codex coding prompt
│   ├── review.md          Claude review prompt
│   └── retry.md           Codex retry with feedback
├── agents.md              Agent playbook
└── Dockerfile             Container support
```

State lives in the repo at `.agentify/`:
- `state.json` — global counters
- `events.jsonl` — event log (dashboard timeline)
- `workers/` — per-worker state files
- `worktrees/` — git worktrees (one per issue)
- `epics/` — epic plans + proposals

## Inspired by

- [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — loop forever, git as state machine
- [AnandChowdhary/continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — PR lifecycle automation
- [paperclipai/paperclip](https://github.com/paperclipai/paperclip) — issue claiming, agent orchestration
