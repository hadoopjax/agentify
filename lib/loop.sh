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
LOGS_DIR="$AGENTIFY_DIR/logs"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_RUNS="${MAX_RUNS:-0}"
MAX_CONCURRENT="${MAX_CONCURRENT:-3}"
PAUSE_ON_QUOTA_SECONDS="${PAUSE_ON_QUOTA_SECONDS:-1800}"
CODEX_PROGRESS_TIMEOUT_SECONDS="${CODEX_PROGRESS_TIMEOUT_SECONDS:-600}"
CODEX_ABSOLUTE_TIMEOUT_SECONDS="${CODEX_ABSOLUTE_TIMEOUT_SECONDS:-0}"
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

epoch_to_iso() {
  local epoch="$1"
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

clear_pause_state() {
  local lockdir="$AGENTIFY_DIR/.state.lock"
  while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.1; done
  local tmp
  tmp=$(mktemp)
  jq 'del(.pause_kind, .pause_reason, .paused_until, .paused_until_epoch)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  rmdir "$lockdir"
}

set_pause_state() {
  local kind="$1" reason="$2" seconds="$3"
  local now until_epoch until_iso previous_until previous_kind
  now=$(date +%s)
  until_epoch=$((now + seconds))
  until_iso=$(epoch_to_iso "$until_epoch")
  previous_until=$(jq -r '.paused_until_epoch // 0' "$STATE_FILE")
  previous_kind=$(jq -r '.pause_kind // ""' "$STATE_FILE")

  local lockdir="$AGENTIFY_DIR/.state.lock"
  while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.1; done
  local tmp
  tmp=$(mktemp)
  jq \
    --arg kind "$kind" \
    --arg reason "$reason" \
    --arg until_iso "$until_iso" \
    --argjson until_epoch "$until_epoch" \
    '.pause_kind = $kind
     | .pause_reason = $reason
     | .paused_until = $until_iso
     | .paused_until_epoch = $until_epoch' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  rmdir "$lockdir"

  [ "$until_epoch" -gt "${previous_until:-0}" ] || [ "$kind" != "$previous_kind" ]
}

pause_remaining_seconds() {
  local until now
  until=$(jq -r '.paused_until_epoch // 0' "$STATE_FILE")
  now=$(date +%s)
  if [ "${until:-0}" -gt "$now" ]; then
    echo $((until - now))
  else
    echo 0
  fi
}

resume_pause_if_expired() {
  local until now reason
  until=$(jq -r '.paused_until_epoch // 0' "$STATE_FILE")
  now=$(date +%s)
  if [ "${until:-0}" -le 0 ] || [ "$until" -gt "$now" ]; then
    return 1
  fi

  reason=$(jq -r '.pause_reason // "pause window expired"' "$STATE_FILE")
  clear_pause_state
  emit "resumed" "Resuming dispatch after pause: $reason"
  return 0
}

worker_log_has_quota_error() {
  local logfile="$1"
  [ -f "$logfile" ] || return 1
  grep -Eiq 'quota exceeded|insufficient_quota|check your plan and billing details|billing details|rate limit|rate_limit|429' "$logfile"
}

pause_dispatch_for_quota() {
  local num="$1" title="$2" worker_log="$3"
  local reason until_iso
  reason="Codex quota or billing failure while working on #$num $title"
  if set_pause_state "quota" "$reason" "$PAUSE_ON_QUOTA_SECONDS"; then
    until_iso=$(jq -r '.paused_until // ""' "$STATE_FILE")
    emit "paused" "[#$num] Paused new work until $until_iso after Codex quota exhaustion"
  fi
  write_worker_log "$worker_log" "Global dispatch paused for $PAUSE_ON_QUOTA_SECONDS seconds due to quota or billing failure"
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

worker_log_file() {
  local num="$1"
  echo "$LOGS_DIR/$num.log"
}

write_worker_log() {
  local logfile="$1"
  shift
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$logfile"
}

# -- Worker management --
active_worker_count() {
  local count=0
  for pidfile in "$WORKERS_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      ((++count))
    fi
  done
  echo "$count"
}

reap_workers() {
  for pidfile in "$WORKERS_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    local pid=$(cat "$pidfile")
    local num=$(basename "$pidfile" .pid)
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
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
  content="${content//\{\{DIFF\}\}/${ISSUE_DIFF-}}"
  content="${content//\{\{REVIEW\}\}/${REVIEW_TEXT-}}"
  content="${content//\{\{REPO_CONTEXT\}\}/$(repo_context)}"
  echo "$content"
}

# -- Worktree helpers --
default_base_ref() {
  local base_ref=""

  base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$base_ref" ]; then
    local default_branch
    default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
    [ -n "$default_branch" ] && base_ref="origin/$default_branch"
  fi
  if [ -z "$base_ref" ]; then
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || true)
    [ -n "$current_branch" ] && base_ref="$current_branch"
  fi

  echo "$base_ref"
}

create_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  local base_ref=""

  if [ -d "$wt_path" ] && git -C "$wt_path" rev-parse --verify HEAD > /dev/null 2>&1; then
    echo "$wt_path"
    return 0
  fi

  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git fetch origin -q > /dev/null 2>&1

  if git rev-parse --verify "$branch" > /dev/null 2>&1; then
    git worktree add "$wt_path" "$branch" -q > /dev/null 2>&1 || return 1
    echo "$wt_path"
    return 0
  fi

  base_ref=$(default_base_ref)
  [ -n "$base_ref" ] || return 1

  git rev-parse --verify "$base_ref" > /dev/null 2>&1 || return 1
  git worktree add "$wt_path" -b "$branch" "$base_ref" -q > /dev/null 2>&1 || return 1
  echo "$wt_path"
}

cleanup_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git branch -D "$branch" -q > /dev/null 2>&1 || true
  git push origin --delete "$branch" -q > /dev/null 2>&1 || true
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

worktree_has_uncommitted_changes() {
  local workdir="$1"
  (
    cd "$workdir" && (
      ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]
    )
  ) > /dev/null 2>&1
}

worktree_unique_commit_count() {
  local workdir="$1" base_ref
  base_ref=$(default_base_ref)
  [ -n "$base_ref" ] || {
    echo 0
    return 0
  }
  (
    cd "$workdir" && git rev-list --count "${base_ref}..HEAD" 2>/dev/null
  ) || echo 0
}

worktree_change_count() {
  local workdir="$1"
  (
    cd "$workdir" && {
      git diff --name-only
      git diff --cached --name-only
      git ls-files --others --exclude-standard
    } | awk 'NF {count++} END {print count+0}'
  ) 2>/dev/null
}

run_codex_with_watchdog() {
  local workdir="$1" prompt="$2" logfile="$3"
  local start_ts last_activity_ts now_ts elapsed total_elapsed pid
  local last_log_size current_log_size last_change_count current_change_count

  (
    cd "$workdir" && \
      codex exec --full-auto --model "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" "$prompt"
  ) >> "$logfile" 2>&1 &
  pid=$!
  start_ts=$(date +%s)
  last_activity_ts="$start_ts"
  last_log_size=$(wc -c < "$logfile" 2>/dev/null || echo 0)
  last_change_count=$(worktree_change_count "$workdir")

  while kill -0 "$pid" 2>/dev/null; do
    now_ts=$(date +%s)
    current_log_size=$(wc -c < "$logfile" 2>/dev/null || echo 0)
    current_change_count=$(worktree_change_count "$workdir")

    if [ "$current_log_size" != "$last_log_size" ] || [ "$current_change_count" != "$last_change_count" ]; then
      last_activity_ts="$now_ts"
      last_log_size="$current_log_size"
      last_change_count="$current_change_count"
    fi

    elapsed=$((now_ts - last_activity_ts))
    total_elapsed=$((now_ts - start_ts))

    if [ "${CODEX_ABSOLUTE_TIMEOUT_SECONDS:-0}" -gt 0 ] && [ "$total_elapsed" -ge "$CODEX_ABSOLUTE_TIMEOUT_SECONDS" ]; then
      write_worker_log "$logfile" "Codex hit absolute timeout after ${CODEX_ABSOLUTE_TIMEOUT_SECONDS}s"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi

    if [ "$elapsed" -ge "$CODEX_PROGRESS_TIMEOUT_SECONDS" ]; then
      write_worker_log "$logfile" "Codex stalled with no log or file-change progress for ${CODEX_PROGRESS_TIMEOUT_SECONDS}s"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 125
    fi
    sleep 5
  done

  wait "$pid"
}

existing_pr_url_for_branch() {
  local branch="$1"
  gh pr list --head "$branch" --state open --limit 1 --json url -q '.[0].url // ""' 2>/dev/null || true
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
  local worker_log
  worker_log=$(worker_log_file "$num")
  : > "$worker_log"
  write_worker_log "$worker_log" "Worker started for #$num $title"

  # Init worker state
  set_worker "$num" "phase" "coding"
  set_worker "$num" "issue" "$num"
  set_worker "$num" "title" "$title"
  set_worker "$num" "branch" "$branch"
  set_worker "$num" "log_file" "$worker_log"

  # Claim: swap labels so dispatcher won't re-pick
  gh issue edit "$num" --remove-label "agent" --add-label "agent-wip" > /dev/null 2>&1 || true
  gh issue comment "$num" --body "🤖 Agent picking this up." > /dev/null 2>&1 || true

  # Worktree
  local wt_path
  if ! wt_path=$(create_worktree "$branch"); then
    wlog "$num" "${C_RED}Worktree setup failed"
    write_worker_log "$worker_log" "Worktree setup failed"
    emit "error" "[#$num] Worktree setup failed"
    increment_global "errors"
    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
    remove_worker "$num"
    return 1
  fi
  set_worker "$num" "worktree" "$wt_path"
  wlog "$num" "${C_DIM}worktree: $wt_path"
  write_worker_log "$worker_log" "Worktree ready at $wt_path"

  local unique_commit_count
  unique_commit_count=$(worktree_unique_commit_count "$wt_path")
  if ! worktree_has_uncommitted_changes "$wt_path" && [ "${unique_commit_count:-0}" -gt 0 ]; then
    write_worker_log "$worker_log" "Detected existing local commit(s) ahead of base; resuming from preserved work"
    emit "coding_resume" "[#$num] Resuming from preserved local commit(s)"
  else

    # ---- Code ----
    wlog "$num" "${C_TEAL}Codex coding..."
    emit "coding_start" "[#$num] Codex working on: $title"
    write_worker_log "$worker_log" "Starting Codex coding pass"
    write_worker_log "$worker_log" "Codex progress watchdog: ${CODEX_PROGRESS_TIMEOUT_SECONDS}s of inactivity"
    if [ "${CODEX_ABSOLUTE_TIMEOUT_SECONDS:-0}" -gt 0 ]; then
      write_worker_log "$worker_log" "Codex absolute ceiling: ${CODEX_ABSOLUTE_TIMEOUT_SECONDS}s"
    fi

    local code_prompt
    code_prompt=$(render_prompt "code.md")

    local codex_status=0
    if run_codex_with_watchdog "$wt_path" "$code_prompt" "$worker_log"; then
      codex_status=0
    else
      codex_status=$?
    fi
    if [ "$codex_status" -ne 0 ]; then
      wlog "$num" "${C_RED}Codex failed"
      if [ "$codex_status" -eq 124 ]; then
        wlog "$num" "${C_YELLOW}Codex hit absolute ceiling"
        write_worker_log "$worker_log" "Codex coding pass hit absolute ceiling"
        emit "timeout" "[#$num] Codex hit absolute ceiling"
      elif [ "$codex_status" -eq 125 ]; then
        wlog "$num" "${C_YELLOW}Codex stalled"
        write_worker_log "$worker_log" "Codex coding pass stalled"
        emit "stalled" "[#$num] Codex stalled with no progress for ${CODEX_PROGRESS_TIMEOUT_SECONDS}s"
      else
        write_worker_log "$worker_log" "Codex coding pass failed"
      fi
      if worker_log_has_quota_error "$worker_log"; then
        wlog "$num" "${C_YELLOW}Pausing new work for quota exhaustion"
        pause_dispatch_for_quota "$num" "$title" "$worker_log"
      fi
      emit "error" "[#$num] Codex failed"
      increment_global "errors"
      cleanup_worktree "$branch"
      gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
      remove_worker "$num"
      return 1
    fi
  fi

  # Check for changes
  unique_commit_count=$(worktree_unique_commit_count "$wt_path")

  if ! worktree_has_uncommitted_changes "$wt_path" && [ "${unique_commit_count:-0}" -eq 0 ]; then
    wlog "$num" "${C_YELLOW}No changes produced"
    write_worker_log "$worker_log" "Codex produced no file changes"
    emit "coding_done" "[#$num] No changes — needs more detail"
    gh issue comment "$num" --body "🤖 Couldn't produce changes. May need a more detailed description." > /dev/null 2>&1 || true
    cleanup_worktree "$branch"
    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
    remove_worker "$num"
    return 1
  fi

  # Commit & push
  if worktree_has_uncommitted_changes "$wt_path"; then
    if ! (cd "$wt_path" && git add -A && git commit -q -m "fix: #$num $title") >> "$worker_log" 2>&1; then
      wlog "$num" "${C_RED}Commit failed"
      write_worker_log "$worker_log" "Commit failed after coding pass"
      emit "error" "[#$num] Commit failed"
      increment_global "errors"
      gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
      remove_worker "$num"
      return 1
    fi
  else
    write_worker_log "$worker_log" "Reusing existing local commit(s) ahead of base"
  fi

  if ! (cd "$wt_path" && git push -u origin HEAD -q) >> "$worker_log" 2>&1; then
    wlog "$num" "${C_RED}Push failed"
    write_worker_log "$worker_log" "Push failed for $branch"
    emit "error" "[#$num] Push failed"
    increment_global "errors"
    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
    remove_worker "$num"
    return 1
  fi
  wlog "$num" "${C_TEAL}Changes pushed"
  write_worker_log "$worker_log" "Changes committed and pushed on $branch"
  emit "coding_done" "[#$num] Changes pushed to $branch"

  # ---- PR ----
  set_worker "$num" "phase" "pr"
  local pr_url
  pr_url=$(existing_pr_url_for_branch "$branch")
  if [ -z "$pr_url" ]; then
    if ! pr_url=$(gh pr create \
      --title "fix: $title" \
      --body "Closes #$num

---
*agentify — Codex coded, Claude reviewed.*" \
      --head "$branch" 2>> "$worker_log"); then
      wlog "$num" "${C_RED}PR creation failed"
      write_worker_log "$worker_log" "PR creation failed for $branch"
      emit "error" "[#$num] PR creation failed"
      increment_global "errors"
      gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" > /dev/null 2>&1 || true
      remove_worker "$num"
      return 1
    fi
  else
    write_worker_log "$worker_log" "Reusing existing PR $pr_url"
  fi

  wlog "$num" "PR: $pr_url"
  write_worker_log "$worker_log" "Opened PR $pr_url"
  emit "pr_created" "[#$num] $pr_url"

  # ---- CI ----
  set_worker "$num" "phase" "ci"
  sleep 5
  if ! wait_for_ci "$pr_url" "$num"; then
    wlog "$num" "${C_RED}CI failed"
    write_worker_log "$worker_log" "CI failed for $pr_url"
    emit "ci_failed" "[#$num] CI failed"
    gh pr comment "$pr_url" --body "🤖 CI failed. Leaving PR open." > /dev/null 2>&1 || true
    local wt_clean="$WORKTREE_DIR/$branch"
    [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
    remove_worker "$num"
    return 1
  fi
  emit "ci_passed" "[#$num] CI passed"
  write_worker_log "$worker_log" "CI passed"

  # ---- Review ----
  set_worker "$num" "phase" "reviewing"
  wlog "$num" "${C_CORAL}Claude reviewing..."
  write_worker_log "$worker_log" "Claude review started"
  emit "review_start" "[#$num] Claude reviewing"

  ISSUE_DIFF=$(gh pr diff "$pr_url")
  local review_prompt review
  review_prompt=$(render_prompt "review.md")
  review=$(claude -p --model "$CLAUDE_MODEL" "$review_prompt")

  if echo "$review" | grep -q "LGTM"; then
    wlog "$num" "${C_GREEN}LGTM ✓"
    write_worker_log "$worker_log" "Claude review result: LGTM"
    emit "review_done" "[#$num] LGTM ✅"
    gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" > /dev/null 2>&1 || true

    set_worker "$num" "phase" "merging"
    gh pr merge "$pr_url" --squash --delete-branch 2>/dev/null || \
      gh pr merge "$pr_url" --squash --auto --delete-branch 2>/dev/null

    wlog "$num" "${C_GREEN}Merged!"
    write_worker_log "$worker_log" "PR merged successfully"
    emit "pr_merged" "[#$num] Merged"
    increment_global "completed"

    local wt_clean="$WORKTREE_DIR/$branch"
    [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
    gh issue edit "$num" --remove-label "agent-wip" > /dev/null 2>&1 || true
    remove_worker "$num"
    return 0
  fi

  # ---- Retry with feedback ----
  wlog "$num" "${C_CORAL}Changes requested — retrying"
  write_worker_log "$worker_log" "Claude requested changes; retrying"
  emit "review_done" "[#$num] Changes requested"
  gh pr comment "$pr_url" --body "🤖 **Review:**

$review" > /dev/null 2>&1 || true

  set_worker "$num" "phase" "retrying"
  emit "retry" "[#$num] Retrying with review feedback"

  REVIEW_TEXT="$review"
  local retry_prompt
  retry_prompt=$(render_prompt "retry.md")

  write_worker_log "$worker_log" "Starting Codex retry pass with ${CODEX_PROGRESS_TIMEOUT_SECONDS}s inactivity watchdog"
  if run_codex_with_watchdog "$wt_path" "$retry_prompt" "$worker_log"; then
    codex_status=0
  else
    codex_status=$?
  fi
  if [ "$codex_status" -eq 124 ]; then
    write_worker_log "$worker_log" "Codex retry pass hit absolute ceiling"
    emit "timeout" "[#$num] Codex retry hit absolute ceiling"
  elif [ "$codex_status" -eq 125 ]; then
    write_worker_log "$worker_log" "Codex retry pass stalled"
    emit "stalled" "[#$num] Codex retry stalled with no progress for ${CODEX_PROGRESS_TIMEOUT_SECONDS}s"
  fi

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
      write_worker_log "$worker_log" "Claude review result after retry: LGTM"
      emit "review_done" "[#$num] LGTM on retry ✅"
      gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" > /dev/null 2>&1 || true

      set_worker "$num" "phase" "merging"
      gh pr merge "$pr_url" --squash --delete-branch 2>/dev/null || \
        gh pr merge "$pr_url" --squash --auto --delete-branch 2>/dev/null

      wlog "$num" "${C_GREEN}Merged after retry!"
      write_worker_log "$worker_log" "PR merged after retry"
      emit "pr_merged" "[#$num] Merged after retry"
      increment_global "completed"

      local wt_clean="$WORKTREE_DIR/$branch"
      [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
      gh issue edit "$num" --remove-label "agent-wip" > /dev/null 2>&1 || true
      remove_worker "$num"
      return 0
    fi
  fi

  # Give up — leave PR open for human
  wlog "$num" "${C_CORAL}Still needs work. Leaving PR open."
  write_worker_log "$worker_log" "Review still failing after retry; leaving PR open"
  emit "review_done" "[#$num] Still needs work after retry"
  gh pr comment "$pr_url" --body "🤖 **Still needs work:**

$review" > /dev/null 2>&1 || true

  local wt_clean="$WORKTREE_DIR/$branch"
  [ -d "$wt_clean" ] && git worktree remove "$wt_clean" --force 2>/dev/null
  remove_worker "$num"
  return 1
}

# ============================================================
# Dispatcher — manages concurrency, spawns workers
# ============================================================
init_run() {
  mkdir -p "$AGENTIFY_DIR" "$WORKERS_DIR" "$WORKTREE_DIR" "$LOGS_DIR"
  if [ -f "$STATE_FILE" ]; then
    local now tmp
    now=$(date +%s)
    tmp=$(mktemp)
    jq --argjson now "$now" \
      '{completed:"0", errors:"0"} + (if (.paused_until_epoch // 0) > $now then {pause_kind, pause_reason, paused_until, paused_until_epoch} else {} end)' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    echo '{"completed":"0","errors":"0"}' > "$STATE_FILE"
  fi
  : > "$EVENTS_FILE"
  # Clean stale worker state from previous runs
  rm -f "$WORKERS_DIR"/*.json "$WORKERS_DIR"/*.pid 2>/dev/null
}

recover_orphaned_wip_issues() {
  local source="${1:-runtime}"
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

    if is_issue_claimed "$num"; then
      continue
    fi

    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" 2>/dev/null || continue
    emit "requeued" "[#$num] Re-queued orphaned agent-wip issue ($source): $title"
  done
}

main_loop() {
  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "unknown")

  init_run
  set_state "repo" "$repo"
  recover_orphaned_wip_issues "startup"

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
    recover_orphaned_wip_issues "runtime"

    resume_pause_if_expired || true

    local pause_remaining
    pause_remaining=$(pause_remaining_seconds)
    if [ "$pause_remaining" -gt 0 ]; then
      local sleep_for
      sleep_for="$POLL_INTERVAL"
      if [ "$pause_remaining" -lt "$sleep_for" ]; then
        sleep_for="$pause_remaining"
      fi
      sleep "$sleep_for"
      continue
    fi

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
