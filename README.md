# agentify

Describe a feature. Claude and GPT-5.4 plan the issues. Codex codes them in parallel. Claude reviews and merges. You approve.

```
agentify plan "Add OAuth login with Google and GitHub"
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

## Setup

### Run locally

```bash
git clone https://github.com/hadoopjax/agentify.git
export PATH="$PATH:$(pwd)/agentify/bin"

# Requires: gh, codex, claude, jq, python3
cd your-repo

# Add your keys
echo "OPENAI_API_KEY=sk-..." >> .env
echo "ANTHROPIC_API_KEY=sk-ant-..." >> .env
echo "GH_TOKEN=ghp_..." >> .env

agentify init
agentify run
```

agentify loads `.env` from the repo directory (or `~/.agentify.env`). Add `.env` to your `.gitignore`.

### Run in Docker / Colima

```bash
git clone https://github.com/hadoopjax/agentify.git
cd your-repo

# Add your keys
echo "OPENAI_API_KEY=sk-..." >> .env
echo "ANTHROPIC_API_KEY=sk-ant-..." >> .env
echo "GH_TOKEN=ghp_..." >> .env

# Start (builds image on first run)
/path/to/agentify/start.sh
```

`start.sh` builds the image if needed, mounts your repo, injects only `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GH_TOKEN`, and starts the loop with dashboard.

Dashboard at `http://localhost:4242`. With Tailscale, accessible from any device on your tailnet.

## Commands

```
agentify run              Start the loop + dashboard
agentify plan "desc"      Plan an epic (Claude + GPT-5.4 dialectic)
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
