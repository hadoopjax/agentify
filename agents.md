# agentify — Agent Playbook

## Agents

### Codex (coder)

- **Role**: Write code to fix issues
- **Model**: `gpt-5.4` (default)
- **Reasoning effort**: `high` (default — set via `-c model_reasoning_effort="high"`)
- **Mode**: `--full-auto` — full shell access, no human confirmation
- **Strengths**: Smart, thorough, good at contained changes, follows instructions literally
- **Weaknesses**: Can over-engineer, not great at poorly defined front-end/UX code, sometimes misses project conventions, won't push back on bad issue descriptions
- **Best for**: All coding tasks

**How to get the best out of Codex:**
- Give it a clear, scoped task — one issue, one concern
- Tell it to read the codebase first so it picks up conventions
- Tell it to run tests — it will actually do it
- Explicitly tell it NOT to commit/push (agentify handles git)
- If the repo has a CLAUDE.md or AGENTS.md, Codex will respect it
- Keep issue descriptions concrete: "add X to Y" not "improve the system"
- Be very specific about the intended end result of the code on the rest of the system

**Codex CLI invocation:**

```bash
# Standard coding task
codex --full-auto \
  --model gpt-5.4 \
  -c model_reasoning_effort="high" \
  -q "Your prompt here"

# Quieter output (background/unattended)
codex --full-auto \
  --model gpt-5.4 \
  -c model_reasoning_effort="high" \
  -q "Your prompt here" 2>/dev/null

# Capture last message to a file for downstream parsing
codex --full-auto \
  --model gpt-5.4 \
  -c model_reasoning_effort="high" \
  --output-last-message /tmp/codex-output.md \
  -q "Your prompt here"

# Lower effort for simple/mechanical tasks (typos, renames, config changes)
codex --full-auto \
  --model gpt-5.4 \
  -c model_reasoning_effort="low" \
  -q "Your prompt here"
```

Key flags:
- `--full-auto` — no confirmations, agent has full shell access
- `--model gpt-5.4` — the model name (NOT `gpt-5.4-high`, effort is separate)
- `-c model_reasoning_effort="high"` — reasoning effort (`low`, `medium`, `high`)
- `-q` — quiet mode, less noisy output
- `--output-last-message <path>` — write final agent message to a file

Do NOT use:
- `--model-reasoning-effort` (wrong flag name, use `-c`)
- `gpt-5.4-high` as a model name (effort is not part of the model ID)

### Claude (reviewer)

- **Role**: Review PRs, plan next steps, decide merge/reject, provide feedback
- **Model**: `claude-opus-4-6` (default)
- **Mode**: Print mode (`-p`) — single prompt, single response
- **Strengths**: Catches bugs, security issues, logic errors, understands intent
- **Weaknesses**: Can lose sight of the end goal of the system, may request changes on style preferences
- **Best for**: Planning, Code review, go/no-go decisions

**How to get the best out of Claude for review:**
- Give it the full diff, not just changed files
- Include the issue context (what was the goal?)
- Ask for a binary decision (LGTM or not) — don't let it hedge
- Keep the review prompt tight — "is this correct?" not "what do you think?"

**Claude Code CLI invocation:**

```bash
# Single-shot review (print mode — prompt in, response out, exit)
claude -p --model claude-opus-4-6 "Your review prompt here"

# Pipe content to Claude
echo "$DIFF" | claude -p --model claude-opus-4-6 "Review this diff..."

# With a heredoc for longer prompts
claude -p --model claude-opus-4-6 <<EOF
Review this PR for issue #42: Fix login bug

DIFF:
$DIFF
EOF
```

Key flags:
- `-p` — print mode (non-interactive, single prompt/response)
- `--model claude-opus-4-6` — the model ID (hyphenated, not dotted)

Do NOT use:
- `claude-opus-4.6` (wrong — use hyphens: `claude-opus-4-6`)
- Interactive mode for automated review (always use `-p`)

## Agent Interaction Pattern

```
Issue creatd by Claude → Codex codes → Claude reviews → merge or retry once → next issue
```

The loop does NOT:
- Let agents talk to each other directly
- Run multiple agents on the same issue concurrently
- Let Codex see Claude's review prompt (or vice versa)
- Retry more than once — if the retry fails review, the PR stays open for a human

## Writing Good Agent Issues

Issues labeled `agent` should be:

1. **Self-contained** — everything the coder needs is in the title + description
2. **Scoped** — one logical change per issue
3. **Testable** — if the repo has tests, say what the expected behavior is
4. **Concrete** — "add a /health endpoint that returns 200" not "improve API"

Bad: "Fix the auth system"
Good: "Fix: login endpoint returns 500 when email has a + character. Expected: 200 with valid session token."

## Customizing Per-Repo

Drop a `.agentify/agents.md` in your repo to add repo-specific context that gets prepended to both agent prompts. Use this for:

- Project-specific conventions ("we use pnpm, not npm")
- Architecture notes ("API routes are in src/routes/, tests in tests/")
- Things agents get wrong ("don't modify the generated/ directory")
- Review criteria ("all PRs must include tests")
