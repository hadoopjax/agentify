#!/usr/bin/env bash
# agentify loop — parallel workers, one worktree per issue

# -- Colors --
C_RESET="\033[0m"
C_DIM="\033[2m"
C_BOLD="\033[1m"
C_TEAL="\033[38;5;43m"
C_CORAL="\033[38;5;210m"
C_GREEN="\033[38;5;114m"
C_YELLOW="\033[38;5;222m"
C_RED="\033[38;5;203m"

# -- Config --
AGENTIFY_DIR=".agentify"
EVENTS_FILE="$AGENTIFY_DIR/events.jsonl"
STATE_FILE="$AGENTIFY_DIR/state.json"
WORKERS_DIR="$AGENTIFY_DIR/workers"
WORKTREE_DIR="$AGENTIFY_DIR/worktrees"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_RUNS="${MAX_RUNS:-0}"
MAX_CONCURRENT="${MAX_CONCURRENT:-3}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"

# -- Logging --
log() {
  printf "  ${C_DIM}├─${C_RESET} ${C_DIM}[$(date +%H:%M:%S)]${C_RESET} %b${C_RESET}\n" "$1"
}

wlog() {
  local num="$1"; shift
  printf "  ${C_DIM}├─${C_RESET} ${C_DIM}[$(date +%H:%M:%S)]${C_RESET} ${C_TEAL}#$num${C_RESET} %b${C_RESET}\n" "$1"
}

emit() {
  local type="$1"; shift
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg type "$type" --arg msg "$*" \
    '{ts: $ts, type: $type, msg: $msg}' >> "$EVENTS_FILE"
}

# -- Global state (locked for concurrent access) --
set_state() {
  local lockdir="$AGENTIFY_DIR/.state.lock"
  while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.1; done
  local tmp=$(mktemp)
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  rmdir "$lockdir"
}

increment_global() {
  local key="$1"
  local lockdir="$AGENTIFY_DIR/.state.lock"
  while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.1; done
  local val=$(jq -r ".$key // \"0\"" "$STATE_FILE")
  val=$((val + 1))
  local tmp=$(mktemp)
  jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  rmdir "$lockdir"
}

# -- Per-worker state (no lock needed, one writer per file) --
set_worker() {
  local num="$1" key="$2" val="$3"
  local wfile="$WORKERS_DIR/$num.json"
  local tmp=$(mktemp)
  if [ -f "$wfile" ]; then
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$wfile" > "$tmp" && mv "$tmp" "$wfile"
  else
    jq -nc --arg k "$key" --arg v "$val" '{($k): $v}' > "$wfile"
  fi
}

remove_worker() {
  local num="$1"
  rm -f "$WORKERS_DIR/$num.json" "$WORKERS_DIR/$num.pid"
}

# -- Worker management --
active_worker_count() {
  local count=0
  for pidfile in "$WORKERS_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill -0 "$(cat "$pidfile")" 2>/dev/null && ((count++))
  done
  echo "$count"
}

reap_workers() {
  for pidfile in "$WORKERS_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    local pid=$(cat "$pidfile")
    local num=$(basename "$pidfile" .pid)
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      rm -f "$pidfile" "$WORKERS_DIR/$num.json"
    fi
  done
}

is_issue_claimed() {
  local num="$1"
  [ -f "$WORKERS_DIR/$num.pid" ] && kill -0 "$(cat "$WORKERS_DIR/$num.pid")" 2>/dev/null
}

# -- Repo context & prompt rendering --
repo_context() {
  if [ -f ".agentify/agents.md" ]; then
    echo "## Repo-Specific Context"
    echo ""
    cat ".agentify/agents.md"
  fi
}

render_prompt() {
  local template="$1"
  local content
  content=$(cat "$PROMPTS_DIR/$template")
  content="${content//\{\{NUM\}\}/$ISSUE_NUM}"
  content="${content//\{\{TITLE\}\}/$ISSUE_TITLE}"
  content="${content//\{\{BODY\}\}/$ISSUE_BODY}"
  content="${content//\{\{DIFF\}\}/$ISSUE_DIFF}"
  content="${content//\{\{REVIEW\}\}/$REVIEW_TEXT}"
  content="${content//\{\{REPO_CONTEXT\}\}/$(repo_context)}"
  echo "$content"
}

# -- Worktree helpers --
create_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git branch -D "$branch" 2>/dev/null
  git fetch origin -q 2>/dev/null
  git worktree add "$wt_path" -b "$branch" origin/main -q 2>/dev/null
  echo "$wt_path"
}

cleanup_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git branch -D "$branch" -q 2>/dev/null
  git push origin --delete "$branch" -q 2>/dev/null
}

# -- CI --
wait_for_ci() {
  local pr="$1" num="$2" waited=0
  while [ $waited -lt 300 ]; do
    local checks
    checks=$(gh pr checks "$pr" 2>/dev/null) || return 0
    [ -z "$checks" ] && return 0
    echo "$checks" | grep -qi "fail" && return 1
    echo "$checks" | grep -qi "pending" || return 0
    sleep 10
    ((waited += 10))
    emit "ci_waiting" "[#$num] CI running... (${waited}s)"
  done
  return 0
}

# ============================================================
# Worker — handles one issue end-to-end in its own worktree
# Runs as a background process, one per issue
# ============================================================
work_issue() {
  local issue_json="$1"
  local num=$(echo "$issue_json" | jq -r '.number')
  local title=$(echo "$issue_json" | jq -r '.title')
  local body=$(echo "$issue_json" | jq -r '.body // ""')

  # Prompt template vars
  ISSUE_NUM="$num"
  ISSUE_TITLE="$title"
  ISSUE_BODY="$body"

  local branch="agent/issue-$num"

  # Init worker state
  set_worker "$num" "phase" "coding"
  set_worker "$num" "issue" "$num"
  set_worker "$num" "title" "$title"
  set_worker "$num" "branch" "$branch"

  # Claim: swap labels so dispatcher won't re-pick
  gh issue edit "$num" --remove-label "agent" --add-label "agent-wip" 2>/dev/null
  gh issue comment "$num" --body "🤖 Agent picking this up." -q 2>/dev/null

  # Worktree
  local wt_path
  wt_path=$(create_worktree "$branch")
  set_worker "$num" "worktree" "$wt_path"
  wlog "$num" "${C_DIM}worktree: $wt_path"

  # ---- Code ----
  wlog "$num" "${C_TEAL}Codex coding..."
  emit "coding_start" "[#$num] Codex working on: $title"

  local code_prompt
  code_prompt=$(render_prompt "code.md")

  if ! (cd "$wt_path" && codex --full-auto --model "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" -q "$code_prompt") 2>/dev/null; then
    wlog "$num" "${C_RED}Codex failed"
    emit "error" "[#$num] Codex failed"
    increment_global "errors"
    cleanup_worktree "$branch"
    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" 2>/dev/null
    remove_worker "$num"
    return 1
  fi

  # Check for changes
  if (cd "$wt_path" && git diff --quiet && git diff --cached --quiet && \
     [ -z "$(git ls-files --others --exclude-standard)" ]); then
    wlog "$num" "${C_YELLOW}No changes produced"
    emit "coding_done" "[#$num] No changes — needs more detail"
    gh issue comment "$num" --body "🤖 Couldn't produce changes. May need a more detailed description." -q 2>/dev/null
    cleanup_worktree "$branch"
    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" 2>/dev/null
    remove_worker "$num"
    return 1
  fi

  # Commit & push
  (cd "$wt_path" && git add -A && git commit -q -m "fix: #$num $title")
  (cd "$wt_path" && git push -u origin HEAD -q) 2>/dev/null
  wlog "$num" "${C_TEAL}Changes pushed"
  emit "coding_done" "[#$num] Changes pushed to $branch"

  # ---- PR ----
  set_worker "$num" "phase" "pr"
  local pr_url
  pr_url=$(gh pr create \
    --title "fix: $title" \
    --body "Closes #$num

---
*agentify — Codex coded, Claude reviewed.*" \
    --head "$branch" 2>/dev/null)

  wlog "$num" "PR: $pr_url"
  emit "pr_created" "[#$num] $pr_url"

  # ---- CI ----
  set_worker "$num" "phase" "ci"
  sleep 5
  if ! wait_for_ci "$pr_url" "$num"; then
    wlog "$num" "${C_RED}CI failed"
    emit "ci_failed" "[#$num] CI failed"
    gh pr comment "$pr_url" --body "🤖 CI failed. Leaving PR open." -q 2>/dev/null
    local wt_clean="$WORKTREE_DIR/$branch"
    [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
    remove_worker "$num"
    return 1
  fi
  emit "ci_passed" "[#$num] CI passed"

  # ---- Review ----
  set_worker "$num" "phase" "reviewing"
  wlog "$num" "${C_CORAL}Claude reviewing..."
  emit "review_start" "[#$num] Claude reviewing"

  ISSUE_DIFF=$(gh pr diff "$pr_url")
  local review_prompt review
  review_prompt=$(render_prompt "review.md")
  review=$(claude -p --model "$CLAUDE_MODEL" "$review_prompt")

  if echo "$review" | grep -q "LGTM"; then
    wlog "$num" "${C_GREEN}LGTM ✓"
    emit "review_done" "[#$num] LGTM ✅"
    gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" -q 2>/dev/null

    set_worker "$num" "phase" "merging"
    gh pr merge "$pr_url" --squash --delete-branch 2>/dev/null || \
      gh pr merge "$pr_url" --squash --auto --delete-branch 2>/dev/null

    wlog "$num" "${C_GREEN}Merged!"
    emit "pr_merged" "[#$num] Merged"
    increment_global "completed"

    local wt_clean="$WORKTREE_DIR/$branch"
    [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
    gh issue edit "$num" --remove-label "agent-wip" 2>/dev/null
    remove_worker "$num"
    return 0
  fi

  # ---- Retry with feedback ----
  wlog "$num" "${C_CORAL}Changes requested — retrying"
  emit "review_done" "[#$num] Changes requested"
  gh pr comment "$pr_url" --body "🤖 **Review:**

$review" -q 2>/dev/null

  set_worker "$num" "phase" "retrying"
  emit "retry" "[#$num] Retrying with review feedback"

  REVIEW_TEXT="$review"
  local retry_prompt
  retry_prompt=$(render_prompt "retry.md")

  (cd "$wt_path" && codex --full-auto --model "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" -q "$retry_prompt") 2>/dev/null || true

  if (cd "$wt_path" && (! git diff --quiet || ! git diff --cached --quiet || \
     [ -n "$(git ls-files --others --exclude-standard)" ])); then
    (cd "$wt_path" && git add -A && git commit -q -m "fix: address review on #$num")
    (cd "$wt_path" && git push -q) 2>/dev/null

    set_worker "$num" "phase" "reviewing"
    ISSUE_DIFF=$(gh pr diff "$pr_url")
    review_prompt=$(render_prompt "review.md")
    review=$(claude -p --model "$CLAUDE_MODEL" "$review_prompt")

    if echo "$review" | grep -q "LGTM"; then
      wlog "$num" "${C_GREEN}LGTM on retry ✓"
      emit "review_done" "[#$num] LGTM on retry ✅"
      gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" -q 2>/dev/null

      set_worker "$num" "phase" "merging"
      gh pr merge "$pr_url" --squash --delete-branch 2>/dev/null || \
        gh pr merge "$pr_url" --squash --auto --delete-branch 2>/dev/null

      wlog "$num" "${C_GREEN}Merged after retry!"
      emit "pr_merged" "[#$num] Merged after retry"
      increment_global "completed"

      local wt_clean="$WORKTREE_DIR/$branch"
      [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
      gh issue edit "$num" --remove-label "agent-wip" 2>/dev/null
      remove_worker "$num"
      return 0
    fi
  fi

  # Give up — leave PR open for human
  wlog "$num" "${C_CORAL}Still needs work. Leaving PR open."
  emit "review_done" "[#$num] Still needs work after retry"
  gh pr comment "$pr_url" --body "🤖 **Still needs work:**

$review" -q 2>/dev/null

  local wt_clean="$WORKTREE_DIR/$branch"
  [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
  remove_worker "$num"
  return 1
}

# ============================================================
# Dispatcher — manages concurrency, spawns workers
# ============================================================
init_run() {
  mkdir -p "$AGENTIFY_DIR" "$WORKERS_DIR" "$WORKTREE_DIR"
  echo '{"completed":"0","errors":"0"}' > "$STATE_FILE"
  : > "$EVENTS_FILE"
  # Clean stale worker state from previous runs
  rm -f "$WORKERS_DIR"/*.json "$WORKERS_DIR"/*.pid 2>/dev/null
}

recover_stale_wip_issues() {
  local issues_json count
  issues_json=$(gh issue list --label agent-wip --state open --limit 100 --json number,title 2>/dev/null || echo '[]')
  count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

  if [ "$count" -eq 0 ]; then
    return 0
  fi

  for ((i=0; i<count; i++)); do
    local issue num title
    issue=$(echo "$issues_json" | jq -c ".[$i]")
    num=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title')

    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" 2>/dev/null || continue
    emit "requeued" "[#$num] Re-queued stale agent-wip issue: $title"
  done
}

main_loop() {
  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "unknown")

  init_run
  set_state "repo" "$repo"
  recover_stale_wip_issues

  printf "\n  ${C_TEAL}${C_BOLD}agentify${C_RESET} ${C_DIM}◉${C_RESET} running\n"
  printf "  ${C_DIM}├─${C_RESET} repo: ${C_BOLD}$repo${C_RESET}\n"
  printf "  ${C_DIM}├─${C_RESET} concurrency: ${C_BOLD}$MAX_CONCURRENT${C_RESET}\n"
  printf "  ${C_DIM}├─${C_RESET} worktrees: ${C_BOLD}$WORKTREE_DIR${C_RESET}\n"
  if [ -f ".agentify/agents.md" ]; then
    printf "  ${C_DIM}├─${C_RESET} repo agents.md: ${C_GREEN}loaded${C_RESET}\n"
  fi
  printf "  ${C_DIM}│${C_RESET}\n"

  emit "loop_start" "Agent loop started for $repo (concurrency: $MAX_CONCURRENT)"

  while true; do
    # Check run limit
    if [ "$MAX_RUNS" -gt 0 ]; then
      local completed=$(jq -r '.completed // "0"' "$STATE_FILE")
      if [ "$completed" -ge "$MAX_RUNS" ]; then
        log "${C_GREEN}Done. Completed $completed runs."
        emit "loop_end" "Completed $completed runs"
        break
      fi
    fi

    # Reap finished workers
    reap_workers

    # Check available slots
    local active=$(active_worker_count)
    local slots=$((MAX_CONCURRENT - active))

    if [ "$slots" -gt 0 ]; then
      # Pick issues (only those labeled 'agent', not 'agent-wip')
      local issues_json
      issues_json=$(gh issue list --label agent --state open --limit "$slots" --json number,title,body 2>/dev/null)
      local count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

      if [ "$count" -gt 0 ]; then
        for ((i=0; i<count; i++)); do
          local issue=$(echo "$issues_json" | jq -c ".[$i]")
          local num=$(echo "$issue" | jq -r '.number')
          local title=$(echo "$issue" | jq -r '.title')

          # Skip if already claimed
          is_issue_claimed "$num" && continue

          log "${C_YELLOW}Spawning worker for #$num: $title"

          work_issue "$issue" &
          echo "$!" > "$WORKERS_DIR/$num.pid"
        done
      elif [ "$active" -eq 0 ]; then
        log "${C_DIM}No agent issues. Checking in ${POLL_INTERVAL}s..."
        emit "idle" "No issues, sleeping ${POLL_INTERVAL}s"
        sleep "$POLL_INTERVAL"
        continue
      fi
    fi

    # Check if any epics completed
    if [ -d "$AGENTIFY_DIR/epics" ]; then
      source "$SCRIPT_DIR/planner.sh" 2>/dev/null
      check_epic_completion
    fi

    sleep 5
  done

  # Wait for remaining workers before exiting
  log "${C_DIM}Waiting for active workers..."
  for pidfile in "$WORKERS_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    wait "$(cat "$pidfile")" 2>/dev/null
    local num=$(basename "$pidfile" .pid)
    rm -f "$pidfile" "$WORKERS_DIR/$num.json"
  done
}
