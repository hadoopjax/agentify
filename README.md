# agentify

Describe a feature. Claude and GPT-5.4 plan the issues. Codex codes them in parallel. Claude reviews and merges. You approve.

```
cd your-repo
agentify
```

That's it. Dashboard opens, workers start, issues get built.

## How it works

```
 You describe a feature (dashboard or CLI)
        ↓
 Interview agent clarifies requirements
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
 All issues done → epic complete → ideation proposes next features
```

### Planning

1. Type a feature description in the dashboard drawer, or `agentify plan "description"`
2. **Interview agent** asks 3-5 clarifying questions to reduce ambiguity
3. Once answered, Claude reads the codebase and proposes issues as structured JSON
4. GPT-5.4 critiques the plan — flags issues too large, spots gaps, adds suggestions
5. You approve/reject in the dashboard
6. Approved issues get the `agent` label and enter the queue

### Auto-Ideation

When the system is idle and a `product_brief.md` exists in the repo root:

1. Claude reads the product brief + codebase structure
2. Proposes 2-5 new features aligned with the product vision
3. Feature proposals appear in the dashboard's **Needs You** drawer
4. You can **Create Issues** (turns them into GitHub issues with `agent` label) or **Dismiss**
5. Won't propose again while pending proposals exist
6. Cooldown: 30 minutes (configurable via `AUTO_IDEATION_COOLDOWN_SECONDS`)

### Auto-Sequencing

When more than 3 issues are queued, Claude orders them by priority before dispatch:

- Dependencies — issues that unblock others come first
- Risk — high-risk changes early when there's time to fix
- Value — higher user-visible impact prioritized
- Size — smaller issues preferred when priorities are similar

Falls back to GitHub's default ordering if sequencing fails.

### Triage

Point agentify at a repo with existing issues:

1. Dashboard shows untriaged issues in the **Needs You** drawer
2. **Assign** adds the `agent` label — the loop picks it up
3. **Skip** adds `agent-skip` — hides it from future triage
4. Issues labeled `agent`, `agent-wip`, or `agent-skip` are excluded

### Group Existing Issues

1. `agentify group` asks Claude to cluster eligible open issues into epic proposals
2. GPT-5.4 critiques the grouping for overlap, missing groups, and unsafe sequencing
3. Proposals stored in the local SQLite state store at `.agentify/state.db`
4. Approving a grouped epic starts its first execution wave
5. Later waves unlock automatically after the prior wave closes
6. One issue at a time within each epic; different epics run in parallel
7. Conservative by design: only 2-issue groups survive; if GPT flags a group as unsafe, it gets dropped
8. Auto-grouping triggers every 10 minutes when idle (configurable via `AUTO_GROUP_COOLDOWN_SECONDS`)

### Execution

1. Dispatcher picks up to N issues labeled `agent` (default: 3 concurrent)
2. Each issue gets its own **git worktree** + background worker process
3. Worker claims the issue (swaps `agent` → `agent-wip` label)
4. Codex codes in the worktree — your checkout stays on `main`
5. Runs issue-declared validation commands when available
6. Opens a PR, waits for CI and required checks
7. Claude reviews the diff alongside the recorded validation results
7. One retry with feedback if changes requested
8. Merges on approval, cleans up, picks next issue
9. Epic advancement runs every cycle — detects completed issues, starts next waves

### Failure Recovery & Self-Healing

**Retry with backoff:**
- First failure: waits 120 seconds before retrying (exponential backoff based on retry count)
- Second failure: immediately escalates to the **manager agent** for auto-triage
- No infinite retry loops, no burning through API rate limits

**Dead worker detection:**
- Every loop cycle, checks if worker PIDs are actually alive
- Dead processes get cleaned up, their issues requeued
- Stale git worktrees pruned automatically at startup and before each worktree create

**Manager agent (auto-triage):**
- When a worker gets blocked after 2 retries, the manager agent is spawned automatically
- Manager reads the logs, diagnoses the problem, and attempts a fix
- No human intervention needed — blocked items show in the dashboard with full context (error, retry count, phase, logs)
- Also available manually: `agentify manage <issue>` or `agentify manage --pr <pr>`

**Rate limit protection:**
- Detects GitHub API rate limit errors and pauses all dispatch globally
- Pause state persists in `.agentify/state.db`, survives restarts
- Dashboard shows pause reason and estimated resume time
- Automatically resumes when the rate limit resets

**Self-healing error reports:**
- When error rate is high (every 25 errors after 10), creates a deduplicated issue in the agentify repo itself
- Requires `--self-repo OWNER/REPO` flag or `AGENTIFY_SELF_REPO` env var
- Issues labeled `agent` so the system can fix itself

**Quota handling:**
- OpenAI quota exhaustion pauses new Codex dispatch globally
- Long-running work governed by inactivity watchdog, not hard timeouts
- Worker keeps running as long as its log is advancing or the worktree is changing

## Dashboard

The dashboard is not a separate thing — `agentify` starts both the dashboard and the worker loop. There is no `agentify dashboard` vs `agentify run` distinction; it's all one command.

**Three zones:**
- **Burndown bar** — shipped / active / queued / blocked counts
- **In Flight** — live workers with phase indicators (Coding, Reviewing, Shipping, Blocked) + queued issues
- **Recently Shipped** — completed work

**Needs You drawer** (amber banner → slide-out panel):
- Feature request form — describe a feature, triggers interview → plan flow
- Active interviews — answer clarifying questions inline
- Blocked workers — error details, retry count, logs, auto-triage status
- Epic proposals — approve/reject planned issues
- Feature ideas — accept (creates GitHub issues) or dismiss ideation proposals
- Untriaged issues — assign to agent or skip

**Browser notifications** via Notification API when new items need attention.

By default the dashboard binds to `127.0.0.1` and all mutating routes require a per-run admin token embedded into the local UI. Use `--host` to opt into a broader bind address.

## Setup

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

agentify init    # creates labels
agentify         # starts everything
```

agentify loads `.agentify/agent.env` only. Keep agent credentials separate from your app's `.env`.

**Requirements:** `gh`, `claude`, `jq`, `node`, `python3`. Codex CLI (`@openai/codex`) must be installed via npm — agentify auto-discovers it from the npm global bin.

### Run in Docker / Colima

```bash
git clone https://github.com/hadoopjax/agentify.git
cd your-repo
mkdir -p .agentify
cat > .agentify/agent.env <<EOF
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GH_TOKEN=ghp_...
EOF

/path/to/agentify/start.sh
```

Dashboard at `http://localhost:4242`. With Tailscale, accessible from any device on your tailnet.

## Commands

```
agentify                  Start the loop + dashboard (default)
agentify run              Same as above
agentify update           Update this agentify checkout to the latest default-branch commit
agentify plan "desc"      Plan an epic (Claude + GPT-5.4 dialectic)
agentify group            Group existing issues into epic proposals
agentify manage <issue>   Run the manager for a blocked worker
agentify manage --pr <pr> Adopt and manage an existing blocked PR
agentify approve <id>     Approve all pending issues for an epic
agentify triage           Review existing issues — assign or skip
agentify init             Create agent/agent-wip/agent-skip labels
agentify test             Create a test issue
agentify status           Show state + recent activity
```

`agentify update` updates the installed agentify checkout itself, not the repo you're running it against. It fast-forwards the checkout to the remote default branch and refuses to run if that checkout has uncommitted changes.

## Options

```
--concurrency N      Parallel workers (default: 3)
--max-runs N         Stop after N completed runs (0 = unlimited)
--poll N             Seconds between idle checks (default: 60)
--port N             Dashboard port (default: 4242)
--host HOST          Dashboard bind host (default: 127.0.0.1)
--codex-model M      Codex model (default: gpt-5.4)
--codex-effort L     Reasoning effort: low, medium, high (default: high)
--manager-model M    Manager model (default: gpt-5.4)
--manager-effort L   Manager reasoning effort (default: high)
--pr N               Pull request number/URL for `manage`
--claude-model M     Claude model (default: claude-opus-4-6)
--self-repo OWNER/REPO  Agentify repo for self-healing error reports
--no-dashboard       Skip the dashboard
```

## Per-repo config

**Product brief** — drop `product_brief.md` in the repo root. Used by:
- Ideation agent (feature proposals)
- Interview agent (clarifying questions)
- Sequencing agent (priority ordering)
- All planning prompts

**Agent context** — drop `.agentify/agents.md` in your repo:

```markdown
- We use pnpm, not npm
- API routes are in src/routes/
- All PRs must include tests
- Never modify the generated/ directory
```

Both Codex and Claude see this in every prompt.

## Architecture

```
agentify/
├── bin/agentify           CLI entry point
├── lib/
│   ├── loop.sh            Dispatcher + parallel workers + failure recovery
│   ├── planner.sh         Epic planning, grouping, ideation, sequencing
│   ├── control_plane.py   Local control-plane CLI for state and queue mutations
│   ├── state_store.py     SQLite state layer
│   ├── dashboard.py       Local HTTP server (state, epics, proposals, interviews, triage, streams)
│   └── index.html         Dashboard UI (dark theme, coral→violet gradient)
├── prompts/
│   ├── plan.md            Epic → issues breakdown
│   ├── plan-critique.md   GPT-5.4 plan review
│   ├── code.md            Codex coding prompt
│   ├── review.md          Claude review prompt
│   ├── retry.md           Codex retry with feedback
│   ├── ideate.md          Feature ideation prompt
│   ├── interview.md       Feature clarification interview
│   ├── sequence.md        LLM-driven priority ordering
│   ├── group-existing.md          Existing issue grouping
│   └── group-existing-critique.md GPT-5.4 grouping review
├── agents.md              Agent playbook
└── Dockerfile             Container support
```

State lives in the target repo at `.agentify/`:
- `state.db` — SQLite state store for globals, workers, epics, proposals, interviews, and events
- `workers/` — PID files for active worker processes
- `worktrees/` — git worktrees (one per issue)
- `logs/` — per-worker log files

## Validation Metadata

Planned issues now carry an `agentify` metadata block with:
- `validation_commands` — shell commands run locally before handoff
- `required_checks` — CI checks that must report success before review/merge
- `files_of_interest` — optional scoping hints for the coding agent

This metadata is embedded in approved issue bodies and then enforced by the runtime.

## Tests

Run the focused regression tests with:

```bash
python3 -m unittest discover -s tests
```

## Role Separation

Different LLMs for different jobs:

| Role | Model | What it does |
|------|-------|-------------|
| Planner | Claude | Proposes issue breakdowns, groups existing issues |
| Critic | GPT-5.4 | Reviews plans for gaps, scope creep, unsafe sequencing |
| Coder | Codex (gpt-5.4) | Writes code in isolated worktrees |
| Reviewer | Claude | Reviews PRs against the diff |
| Manager | GPT-5.4 | Diagnoses and fixes blocked workers |
| Ideator | Claude | Proposes new features from product brief |
| Interviewer | Claude | Clarifies vague feature requests |
| Sequencer | Claude | Orders issues by priority |

## Design Principles

1. **Loop + external state + git as the machine** — Intelligence operates against durable state (`.agentify/`), not just prompt transcripts. Process restarts resume from where they left off.

2. **Role separation over omni-agents** — Planning, coding, review, and triage are separate prompt contracts with different failure modes. Planners decompose; critics police scope; coders implement; reviewers verify.

3. **Issues and PRs as the control surface** — Labels (`agent`, `agent-wip`, `agent-skip`) are the queue protocol. PRs and CI are the governance layer. Human and agent work share the same visible state transitions.

4. **Conservative orchestration** — False-positive grouping is worse than leaving work ungrouped. One issue at a time within epics. Parallelism only when it can't create merge collisions.

5. **Self-healing over manual intervention** — Dead workers detected and requeued. Failed workers escalated to manager after 2 retries. Rate limits pause globally. The system should fix itself; the human approves direction, not babysits execution.

6. **Live observability** — Dashboard shows queue state, active workers, grouped epics, per-worker logs, and needs-attention items. Trust comes from being able to inspect the machine while it runs.

## Inspired by

- [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — loop forever, git as state machine
- [AnandChowdhary/continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — PR lifecycle automation
- [paperclipai/paperclip](https://github.com/paperclipai/paperclip) — issue claiming, agent orchestration
