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
PAUSE_ON_GITHUB_RATE_LIMIT_SECONDS="${PAUSE_ON_GITHUB_RATE_LIMIT_SECONDS:-900}"
MANAGER_INTERVAL_SECONDS="${MANAGER_INTERVAL_SECONDS:-900}"
MANAGER_MODEL="${MANAGER_MODEL:-gpt-5.4}"
MANAGER_EFFORT="${MANAGER_EFFORT:-high}"
CODEX_PROGRESS_TIMEOUT_SECONDS="${CODEX_PROGRESS_TIMEOUT_SECONDS:-600}"
CODEX_ABSOLUTE_TIMEOUT_SECONDS="${CODEX_ABSOLUTE_TIMEOUT_SECONDS:-0}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
AGENTIFY_SELF_REPO="${AGENTIFY_SELF_REPO:-}"
AUTO_GROUP_COOLDOWN_SECONDS="${AUTO_GROUP_COOLDOWN_SECONDS:-600}"

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

worker_log_has_github_rate_limit_error() {
  local logfile="$1"
  [ -f "$logfile" ] || return 1
  grep -Eiq 'GraphQL: API rate limit|API rate limit already exceeded|secondary rate limit|rate limit exceeded for user ID|was submitted too quickly|abuse detection' "$logfile"
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

pause_dispatch_for_github_rate_limit() {
  local num="$1" title="$2" worker_log="$3"
  local reason until_iso
  reason="GitHub API rate limit while working on #$num $title"
  if set_pause_state "github" "$reason" "$PAUSE_ON_GITHUB_RATE_LIMIT_SECONDS"; then
    until_iso=$(jq -r '.paused_until // ""' "$STATE_FILE")
    emit "paused" "[#$num] Paused GitHub work until $until_iso after API rate limit"
  fi
  write_worker_log "$worker_log" "Global dispatch paused for $PAUSE_ON_GITHUB_RATE_LIMIT_SECONDS seconds due to GitHub API rate limiting"
}

ensure_label_exists() {
  local name="$1" description="$2" color="$3"
  gh label list 2>/dev/null | grep -q "^${name}[[:space:]]" && return 0
  gh label create "$name" --description "$description" --color "$color" > /dev/null 2>&1 || true
}

find_blocker_issue_number() {
  local signature="$1"
  gh issue list --state open --search "\"agentify-blocker:${signature}\" in:body" --limit 1 --json number -q '.[0].number // ""' 2>/dev/null || true
}

create_blocker_issue() {
  local signature="$1" title="$2" body="$3"
  ensure_label_exists "agent-blocker" "Systemic blocker discovered by agentify" "B60205"
  gh issue create --title "$title" --label "agent-blocker" --body "$body" 2>/dev/null
}

report_repo_blocker_if_needed() {
  local num="$1" issue_title="$2" worker_log="$3"
  [ -f "$worker_log" ] || return 0

  local signature blocker_title evidence existing_number body

  if grep -Eiq 'not runnable in this workspace because it hardcodes .*/Users/[^ ]+.*references a missing `?test_api\.py`?' "$worker_log"; then
    signature="repo-test-runner-nonportable"
    blocker_title="Fix non-portable backend test runner"
    evidence=$(grep -Ei 'backend/run_tests\.sh|not runnable in this workspace because it hardcodes|missing `?test_api\.py`?' "$worker_log" | tail -n 6)
    existing_number=$(find_blocker_issue_number "$signature")
    [ -n "$existing_number" ] && return 0

    body=$(cat <<EOF
Agentify detected a systemic repo blocker while working issue #$num: $issue_title.

The agent could complete targeted validation, but the repo's advertised backend test runner is not portable in this workspace.

Observed evidence:

\`\`\`
$evidence
\`\`\`

Expected:
- the documented backend test runner should be runnable from a normal repo checkout
- it should not hardcode another developer's home directory
- it should not reference missing test entrypoints

Discovered from:
- issue #$num

<!-- agentify-blocker:$signature -->
EOF
)

    if create_blocker_issue "$signature" "$blocker_title" "$body" > /dev/null; then
      emit "blocker_created" "[#$num] Created blocker issue: $blocker_title"
      write_worker_log "$worker_log" "Created blocker issue for signature $signature"
    fi
  fi
}

# -- Self-healing: report agentify internal errors to the agentify repo --
report_self_error() {
  local signature="$1" title="$2" detail="$3"
  local agentify_repo="${AGENTIFY_SELF_REPO:-}"
  [ -n "$agentify_repo" ] || return 0

  # Deduplicate: check if an open issue with this signature exists
  local existing
  existing=$(gh issue list --repo "$agentify_repo" --state open \
    --search "\"agentify-self-heal:${signature}\" in:body" --limit 1 \
    --json number -q '.[0].number // ""' 2>/dev/null || true)
  [ -z "$existing" ] || return 0

  local body
  body="Agentify detected an internal error that may need a fix.

**Signature:** \`$signature\`
**Detail:**
\`\`\`
$detail
\`\`\`

**Target repo:** $(jq -r '.repo // "unknown"' "$STATE_FILE" 2>/dev/null)
**Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

<!-- agentify-self-heal:$signature -->"

  gh issue create --repo "$agentify_repo" \
    --title "[self-heal] $title" \
    --body "$body" \
    --label "agent" > /dev/null 2>&1 && \
    emit "self_heal" "Created self-healing issue in agentify repo: $title" || true
}

# -- Per-worker state (no lock needed, one writer per file) --
worker_state_file() {
  local num="$1"
  echo "$WORKERS_DIR/$num.json"
}

worker_field() {
  local num="$1" key="$2"
  local wfile
  wfile=$(worker_state_file "$num")
  [ -f "$wfile" ] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$wfile" 2>/dev/null
}

sanitize_pr_url() {
  local raw="${1:-}"
  printf '%s\n' "$raw" | tr '\r' '\n' | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | tail -n 1 || true
}

worker_issue_ref() {
  local num="$1" issue_ref
  issue_ref=$(worker_field "$num" "issue")
  if [ -n "$issue_ref" ]; then
    printf '%s\n' "$issue_ref"
    return 0
  fi
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$num"
    return 0
  fi
  return 1
}

set_worker() {
  local num="$1" key="$2" val="$3"
  local wfile
  wfile=$(worker_state_file "$num")
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
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      rm -f "$pidfile"
    fi
  done
}

is_issue_claimed() {
  local num="$1"
  [ -f "$WORKERS_DIR/$num.pid" ] && kill -0 "$(cat "$WORKERS_DIR/$num.pid")" 2>/dev/null
}

# -- Repo context & prompt rendering --
repo_context() {
  if [ -f "product_brief.md" ]; then
    echo "## Product Brief"
    echo ""
    cat "product_brief.md"
    echo ""
  fi
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

managed_branch_name() {
  local branch="$1"
  printf 'agentify/manage/%s\n' "${branch//\//__}"
}

ensure_worktree_from_ref() {
  local wt_path="$1" branch="$2" start_ref="$3" local_target="${4:-false}"
  local managed_branch
  managed_branch=$(managed_branch_name "$branch")

  if [ "$local_target" = "true" ]; then
    if git worktree add -q "$wt_path" "$branch" > /dev/null 2>&1; then
      printf '%s\n' "$wt_path"
      return 0
    fi
  else
    if git worktree add -q -b "$branch" "$wt_path" "$start_ref" > /dev/null 2>&1; then
      printf '%s\n' "$wt_path"
      return 0
    fi
  fi

  git worktree add -q -B "$managed_branch" "$wt_path" "$start_ref" > /dev/null 2>&1 || return 1
  printf '%s\n' "$wt_path"
}

create_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  local base_ref="" remote_ref=""

  if [ -d "$wt_path" ] && git -C "$wt_path" rev-parse --verify HEAD > /dev/null 2>&1; then
    echo "$wt_path"
    return 0
  fi

  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git worktree prune 2>/dev/null || true
  git fetch origin -q > /dev/null 2>&1

  if git rev-parse --verify "$branch" > /dev/null 2>&1; then
    ensure_worktree_from_ref "$wt_path" "$branch" "$branch" "true" || return 1
    return 0
  fi

  remote_ref="origin/$branch"
  if git rev-parse --verify "$remote_ref" > /dev/null 2>&1; then
    ensure_worktree_from_ref "$wt_path" "$branch" "$remote_ref" || return 1
    return 0
  fi

  base_ref=$(default_base_ref)
  [ -n "$base_ref" ] || return 1

  git rev-parse --verify "$base_ref" > /dev/null 2>&1 || return 1
  ensure_worktree_from_ref "$wt_path" "$branch" "$base_ref" || return 1
}

cleanup_worktree() {
  local branch="$1"
  local wt_path="$WORKTREE_DIR/$branch"
  local managed_branch
  managed_branch=$(managed_branch_name "$branch")
  [ -d "$wt_path" ] && git worktree remove "$wt_path" --force 2>/dev/null
  git branch -D "$branch" -q > /dev/null 2>&1 || true
  git branch -D "$managed_branch" -q > /dev/null 2>&1 || true
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

complete_worker_success() {
  local num="$1" branch="$2" worker_log="$3" merged_msg="$4" event_msg="$5"
  local issue_ref
  wlog "$num" "${C_GREEN}${merged_msg}"
  write_worker_log "$worker_log" "$event_msg"
  emit "pr_merged" "[#$num] $event_msg"
  increment_global "completed"
  issue_ref=$(worker_issue_ref "$num" || true)
  [ -z "$issue_ref" ] || gh issue edit "$issue_ref" --remove-label "agent-wip" --remove-label "agent" > /dev/null 2>&1 || true
  cleanup_worktree "$branch"
  remove_worker "$num"
  return 0
}

mark_worker_resumable_failure() {
  local num="$1" phase="$2" message="$3" worker_log="$4"
  set_worker "$num" "phase" "$phase"
  set_worker "$num" "last_error" "$message"
  write_worker_log "$worker_log" "$message"
  emit "error" "[#$num] $message"
  increment_global "errors"

  # Track per-worker retry count + timestamp for backoff
  local wfile
  wfile=$(worker_state_file "$num")
  if [ -f "$wfile" ]; then
    local retries
    retries=$(jq -r '.retries // 0' "$wfile" 2>/dev/null || echo 0)
    retries=$((retries + 1))
    local now
    now=$(date +%s)
    local tmp=$(mktemp)
    jq --argjson r "$retries" --argjson t "$now" '.retries = $r | .failed_at = $t' "$wfile" > "$tmp" && mv "$tmp" "$wfile"
    if [ "$retries" -ge 2 ]; then
      write_worker_log "$worker_log" "Blocked after $retries consecutive failures — auto-triaging"
      emit "blocked" "[#$num] Blocked after $retries retries: $message — triggering auto-triage"
      set_worker "$num" "phase" "merge_blocked"
      set_worker "$num" "last_error" "Blocked after $retries retries: $message"
      # Auto-triage: immediately spawn manager to diagnose and fix
      manage_issue "$num" &
      echo "$!" > "$WORKERS_DIR/$num.pid"
    fi
  fi

  # Self-heal: report persistent failures to the agentify repo
  local total_errors
  total_errors=$(jq -r '.errors // "0"' "$STATE_FILE" 2>/dev/null || echo "0")
  if [ "$total_errors" -ge 10 ] && [ $(( total_errors % 25 )) -eq 0 ]; then
    report_self_error "high-error-rate-${total_errors}" \
      "High error rate: $total_errors errors in current run" \
      "Phase: $phase\nIssue: #$num\nLatest: $message\nTotal errors: $total_errors"
  fi

  return 1
}

mark_worker_blocked_for_human() {
  local num="$1" phase="$2" message="$3" worker_log="$4"
  local issue_ref
  set_worker "$num" "phase" "$phase"
  set_worker "$num" "last_error" "$message"
  write_worker_log "$worker_log" "$message"
  emit "$phase" "[#$num] $message"
  issue_ref=$(worker_issue_ref "$num" || true)
  [ -z "$issue_ref" ] || gh issue edit "$issue_ref" --remove-label "agent-wip" > /dev/null 2>&1 || true
  return 1
}

infer_issue_ref_for_pr() {
  local branch="$1" body="$2" explicit_issue="${3:-}" issue_ref=""
  if [ -n "$explicit_issue" ]; then
    printf '%s\n' "$explicit_issue"
    return 0
  fi

  if [[ "$branch" =~ ^agent/issue-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  issue_ref=$(printf '%s\n' "$body" | perl -ne 'if (/(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)/) { print $1; exit 0 }')
  [ -z "$issue_ref" ] || printf '%s\n' "$issue_ref"
}

adopt_pr_for_management() {
  local pr_ref="$1" explicit_issue="${2:-}"
  local pr_json pr_number title branch pr_url worker_id worker_log issue_ref

  pr_json=$(gh pr view "$pr_ref" --json number,title,url,state,mergeStateStatus,headRefName,body 2>/dev/null) || return 1
  pr_number=$(echo "$pr_json" | jq -r '.number')
  title=$(echo "$pr_json" | jq -r '.title // ""')
  branch=$(echo "$pr_json" | jq -r '.headRefName // ""')
  pr_url=$(echo "$pr_json" | jq -r '.url // ""')
  issue_ref=$(infer_issue_ref_for_pr "$branch" "$(echo "$pr_json" | jq -r '.body // ""')" "$explicit_issue" || true)
  worker_id="pr-$pr_number"
  worker_log=$(worker_log_file "$worker_id")

  set_worker "$worker_id" "issue" "$issue_ref"
  set_worker "$worker_id" "title" "$title"
  set_worker "$worker_id" "branch" "$branch"
  set_worker "$worker_id" "pr_url" "$pr_url"
  set_worker "$worker_id" "pr_number" "$pr_number"
  set_worker "$worker_id" "subject_type" "pr"
  set_worker "$worker_id" "phase" "merge_blocked"
  set_worker "$worker_id" "log_file" "$worker_log"
  write_worker_log "$worker_log" "Adopted existing PR #$pr_number for manager on branch $branch"
  emit "manage_adopted" "[#$worker_id] Adopted PR #$pr_number for manager"
  printf '%s\n' "$worker_id"
}

prepare_branch_for_handoff() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5"

  if worktree_has_uncommitted_changes "$wt_path"; then
    if ! (cd "$wt_path" && git add -A && git commit -q -m "fix: #$num $title") >> "$worker_log" 2>&1; then
      mark_worker_resumable_failure "$num" "coding" "Commit failed after coding pass" "$worker_log"
      return 1
    fi
  else
    write_worker_log "$worker_log" "Reusing existing local commit(s) ahead of base"
  fi

  set_worker "$num" "phase" "pushing"
  if ! (cd "$wt_path" && git push -u origin HEAD -q) >> "$worker_log" 2>&1; then
    if worker_log_has_github_rate_limit_error "$worker_log"; then
      pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
    fi
    mark_worker_resumable_failure "$num" "pushing" "Push failed for $branch" "$worker_log"
    return 1
  fi

  wlog "$num" "${C_TEAL}Changes pushed"
  write_worker_log "$worker_log" "Changes committed and pushed on $branch"
  emit "coding_done" "[#$num] Changes pushed to $branch"
  return 0
}

ensure_pr_for_branch() {
  local num="$1" title="$2" branch="$3" worker_log="$4"
  local pr_url

  set_worker "$num" "phase" "pr"
  pr_url=$(existing_pr_url_for_branch "$branch")
  if [ -z "$pr_url" ]; then
    if ! pr_url=$(gh pr create \
      --title "fix: $title" \
      --body "Closes #$num

---
*agentify — Codex coded, Claude reviewed.*" \
      --head "$branch" 2>> "$worker_log"); then
      if worker_log_has_github_rate_limit_error "$worker_log"; then
        pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
      fi
      mark_worker_resumable_failure "$num" "pr" "PR creation failed for $branch" "$worker_log"
      return 1
    fi
  else
    write_worker_log "$worker_log" "Reusing existing PR $pr_url"
  fi

  pr_url=$(sanitize_pr_url "$pr_url")
  if [ -z "$pr_url" ]; then
    mark_worker_resumable_failure "$num" "pr" "Unable to determine PR URL for $branch" "$worker_log"
    return 1
  fi

  set_worker "$num" "pr_url" "$pr_url"
  wlog "$num" "PR: $pr_url" >&2
  write_worker_log "$worker_log" "Opened PR $pr_url"
  emit "pr_created" "[#$num] $pr_url"
  printf '%s\n' "$pr_url"
  return 0
}

pr_status_json() {
  local pr_url="$1" worker_log="${2:-}"
  local output
  if ! output=$(gh pr view "$pr_url" --json state,mergeStateStatus,url,headRefName 2>> "${worker_log:-/dev/null}"); then
    return 1
  fi
  printf '%s\n' "$output"
}

refresh_branch_from_base() {
  local wt_path="$1" worker_log="$2"
  local base_ref
  base_ref=$(default_base_ref)
  [ -n "$base_ref" ] || return 1

  if ! (cd "$wt_path" && git fetch origin -q && git rebase "$base_ref") >> "$worker_log" 2>&1; then
    (cd "$wt_path" && git rebase --abort) >> "$worker_log" 2>&1 || true
    return 1
  fi

  (cd "$wt_path" && git push --force-with-lease -q) >> "$worker_log" 2>&1
}

run_merge_phase() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5" pr_url="$6"
  local pr_json pr_state merge_state

  set_worker "$num" "phase" "merging"
  set_worker "$num" "pr_url" "$pr_url"

  if ! pr_json=$(pr_status_json "$pr_url" "$worker_log"); then
    if worker_log_has_github_rate_limit_error "$worker_log"; then
      pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
    fi
    mark_worker_resumable_failure "$num" "merging" "Unable to inspect PR state for $pr_url" "$worker_log"
    return 1
  fi

  pr_state=$(echo "$pr_json" | jq -r '.state // ""')
  merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // ""')

  if [ "$pr_state" = "MERGED" ]; then
    complete_worker_success "$num" "$branch" "$worker_log" "Merged!" "Merged"
    return 0
  fi

  if [ "$merge_state" = "DIRTY" ]; then
    write_worker_log "$worker_log" "PR $pr_url is DIRTY; attempting branch refresh from base"
    if refresh_branch_from_base "$wt_path" "$worker_log"; then
      sleep 2
      if pr_json=$(pr_status_json "$pr_url" "$worker_log"); then
        merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // ""')
        pr_state=$(echo "$pr_json" | jq -r '.state // ""')
      fi
    fi
  fi

  if [ "$pr_state" = "MERGED" ]; then
    complete_worker_success "$num" "$branch" "$worker_log" "Merged!" "Merged"
    return 0
  fi

  if [ "$merge_state" = "DIRTY" ]; then
    gh pr comment "$pr_url" --body "🤖 Merge blocked automatically: branch is dirty against base. Leaving PR open for a human." > /dev/null 2>&1 || true
    mark_worker_blocked_for_human "$num" "merge_blocked" "Merge blocked for $pr_url (dirty against base)" "$worker_log"
    return 1
  fi

  if (gh pr merge "$pr_url" --squash --delete-branch || gh pr merge "$pr_url" --squash --auto --delete-branch) >> "$worker_log" 2>&1; then
    complete_worker_success "$num" "$branch" "$worker_log" "Merged!" "Merged"
    return 0
  fi

  if worker_log_has_github_rate_limit_error "$worker_log"; then
    pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
  fi

  if pr_json=$(pr_status_json "$pr_url" "$worker_log"); then
    pr_state=$(echo "$pr_json" | jq -r '.state // ""')
    merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // ""')
    if [ "$pr_state" = "MERGED" ]; then
      complete_worker_success "$num" "$branch" "$worker_log" "Merged!" "Merged"
      return 0
    fi
    if [ "$merge_state" = "DIRTY" ]; then
      gh pr comment "$pr_url" --body "🤖 Merge blocked automatically: branch is dirty against base. Leaving PR open for a human." > /dev/null 2>&1 || true
      mark_worker_blocked_for_human "$num" "merge_blocked" "Merge blocked for $pr_url (dirty against base)" "$worker_log"
      return 1
    fi
  fi

  mark_worker_resumable_failure "$num" "merging" "Merge failed for $pr_url" "$worker_log"
  return 1
}

run_retry_phase() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5" pr_url="$6" review_text="$7"
  local codex_status=0 review review_prompt

  set_worker "$num" "phase" "retrying"
  set_worker "$num" "pr_url" "$pr_url"
  set_worker "$num" "review_feedback" "$review_text"
  emit "retry" "[#$num] Retrying with review feedback"

  REVIEW_TEXT="$review_text"
  write_worker_log "$worker_log" "Starting Codex retry pass with ${CODEX_PROGRESS_TIMEOUT_SECONDS}s inactivity watchdog"
  if run_codex_with_watchdog "$wt_path" "$(render_prompt "retry.md")" "$worker_log"; then
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
  elif [ "$codex_status" -ne 0 ]; then
    write_worker_log "$worker_log" "Codex retry pass failed"
  fi

  report_repo_blocker_if_needed "$num" "$title" "$worker_log"
  if [ "$codex_status" -ne 0 ]; then
    if worker_log_has_quota_error "$worker_log"; then
      pause_dispatch_for_quota "$num" "$title" "$worker_log"
    fi
    mark_worker_resumable_failure "$num" "retrying" "Retry coding pass failed" "$worker_log"
    return 1
  fi

  if worktree_has_uncommitted_changes "$wt_path"; then
    if ! (cd "$wt_path" && git add -A && git commit -q -m "fix: address review on #$num") >> "$worker_log" 2>&1; then
      mark_worker_resumable_failure "$num" "retrying" "Commit failed after retry on #$num" "$worker_log"
      return 1
    fi
  fi

  if ! prepare_branch_for_handoff "$num" "$title" "$branch" "$wt_path" "$worker_log"; then
    return 1
  fi

  set_worker "$num" "phase" "reviewing"
  ISSUE_DIFF=$(gh pr diff "$pr_url" 2>> "$worker_log") || ISSUE_DIFF=""
  review_prompt=$(render_prompt "review.md")
  review=$(claude -p --model "$CLAUDE_MODEL" "$review_prompt")

  if echo "$review" | grep -q "LGTM"; then
    wlog "$num" "${C_GREEN}LGTM on retry ✓"
    write_worker_log "$worker_log" "Claude review result after retry: LGTM"
    emit "review_done" "[#$num] LGTM on retry ✅"
    gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" > /dev/null 2>&1 || true
    run_merge_phase "$num" "$title" "$branch" "$wt_path" "$worker_log" "$pr_url"
    return $?
  fi

  wlog "$num" "${C_CORAL}Still needs work. Leaving PR open."
  write_worker_log "$worker_log" "Review still failing after retry; leaving PR open"
  emit "review_done" "[#$num] Still needs work after retry"
  gh pr comment "$pr_url" --body "🤖 **Still needs work:**

$review" > /dev/null 2>&1 || true
  mark_worker_blocked_for_human "$num" "human_review" "Review still failing after retry for $pr_url" "$worker_log"
  return 1
}

run_review_phase() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5" pr_url="$6"
  local review_prompt review

  set_worker "$num" "phase" "reviewing"
  set_worker "$num" "pr_url" "$pr_url"
  wlog "$num" "${C_CORAL}Claude reviewing..."
  write_worker_log "$worker_log" "Claude review started"
  emit "review_start" "[#$num] Claude reviewing"

  if ! ISSUE_DIFF=$(gh pr diff "$pr_url" 2>> "$worker_log"); then
    if worker_log_has_github_rate_limit_error "$worker_log"; then
      pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
    fi
    mark_worker_resumable_failure "$num" "reviewing" "Unable to load PR diff for $pr_url" "$worker_log"
    return 1
  fi

  review_prompt=$(render_prompt "review.md")
  review=$(claude -p --model "$CLAUDE_MODEL" "$review_prompt")

  if echo "$review" | grep -q "LGTM"; then
    wlog "$num" "${C_GREEN}LGTM ✓"
    write_worker_log "$worker_log" "Claude review result: LGTM"
    emit "review_done" "[#$num] LGTM ✅"
    gh pr comment "$pr_url" --body "🤖 **Claude: LGTM** ✅" > /dev/null 2>&1 || true
    run_merge_phase "$num" "$title" "$branch" "$wt_path" "$worker_log" "$pr_url"
    return $?
  fi

  wlog "$num" "${C_CORAL}Changes requested — retrying"
  write_worker_log "$worker_log" "Claude requested changes; retrying"
  emit "review_done" "[#$num] Changes requested"
  gh pr comment "$pr_url" --body "🤖 **Review:**

$review" > /dev/null 2>&1 || true
  run_retry_phase "$num" "$title" "$branch" "$wt_path" "$worker_log" "$pr_url" "$review"
}

run_ci_phase() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5" pr_url="$6"

  set_worker "$num" "phase" "ci"
  set_worker "$num" "pr_url" "$pr_url"
  sleep 5
  if ! wait_for_ci "$pr_url" "$num"; then
    write_worker_log "$worker_log" "CI failed for $pr_url"
    emit "ci_failed" "[#$num] CI failed"
    gh pr comment "$pr_url" --body "🤖 CI failed. Leaving PR open." > /dev/null 2>&1 || true
    mark_worker_blocked_for_human "$num" "ci_failed" "CI failed for $pr_url" "$worker_log"
    return 1
  fi

  emit "ci_passed" "[#$num] CI passed"
  write_worker_log "$worker_log" "CI passed"
  run_review_phase "$num" "$title" "$branch" "$wt_path" "$worker_log" "$pr_url"
}

run_post_coding_pipeline() {
  local num="$1" title="$2" branch="$3" wt_path="$4" worker_log="$5"
  local pr_url

  if ! prepare_branch_for_handoff "$num" "$title" "$branch" "$wt_path" "$worker_log"; then
    return 1
  fi

  if ! pr_url=$(ensure_pr_for_branch "$num" "$title" "$branch" "$worker_log"); then
    return 1
  fi

  run_ci_phase "$num" "$title" "$branch" "$wt_path" "$worker_log" "$pr_url"
}

resume_worker() {
  local num="$1"
  local phase title branch worker_log wt_path pr_url issue_json body review_text

  phase=$(worker_field "$num" "phase")
  title=$(worker_field "$num" "title")
  branch=$(worker_field "$num" "branch")
  worker_log=$(worker_field "$num" "log_file")
  pr_url=$(sanitize_pr_url "$(worker_field "$num" "pr_url")")
  review_text=$(worker_field "$num" "review_feedback")

  [ -n "$worker_log" ] || worker_log=$(worker_log_file "$num")
  [ -n "$phase" ] || phase="coding"

  if [ "$phase" = "managing" ]; then
    phase=$(worker_field "$num" "manager_previous_phase")
    [ -n "$phase" ] || phase="merge_blocked"
    set_worker "$num" "phase" "$phase"
  fi

  if [ "$phase" = "merge_blocked" ] || [ "$phase" = "human_review" ] || [ "$phase" = "ci_failed" ] || [ "$phase" = "awaiting_human_conflict_resolution" ]; then
    return 0
  fi

  issue_json=$(gh issue view "$num" --json number,title,body 2>/dev/null || echo '{}')
  ISSUE_NUM="$num"
  ISSUE_TITLE="$(echo "$issue_json" | jq -r '.title // empty')"
  ISSUE_BODY="$(echo "$issue_json" | jq -r '.body // ""')"
  [ -n "$ISSUE_TITLE" ] || ISSUE_TITLE="$title"

  wt_path=$(create_worktree "$branch") || {
    mark_worker_resumable_failure "$num" "$phase" "Worktree setup failed while resuming $phase" "$worker_log"
    return 1
  }
  set_worker "$num" "worktree" "$wt_path"

  if [ "$phase" = "coding" ] && ! worktree_has_uncommitted_changes "$wt_path" && [ "$(worktree_unique_commit_count "$wt_path")" -eq 0 ]; then
    work_issue "$issue_json"
    return $?
  fi

  case "$phase" in
    coding|pushing|pr)
      emit "coding_resume" "[#$num] Resuming from preserved local commit(s)"
      run_post_coding_pipeline "$num" "$ISSUE_TITLE" "$branch" "$wt_path" "$worker_log"
      ;;
    ci)
      [ -n "$pr_url" ] || pr_url=$(sanitize_pr_url "$(existing_pr_url_for_branch "$branch")")
      [ -n "$pr_url" ] && set_worker "$num" "pr_url" "$pr_url"
      [ -n "$pr_url" ] || {
        mark_worker_resumable_failure "$num" "pr" "Missing PR while resuming CI for $branch" "$worker_log"
        return 1
      }
      run_ci_phase "$num" "$ISSUE_TITLE" "$branch" "$wt_path" "$worker_log" "$pr_url"
      ;;
    reviewing)
      [ -n "$pr_url" ] || pr_url=$(sanitize_pr_url "$(existing_pr_url_for_branch "$branch")")
      [ -n "$pr_url" ] && set_worker "$num" "pr_url" "$pr_url"
      [ -n "$pr_url" ] || {
        mark_worker_resumable_failure "$num" "pr" "Missing PR while resuming review for $branch" "$worker_log"
        return 1
      }
      run_review_phase "$num" "$ISSUE_TITLE" "$branch" "$wt_path" "$worker_log" "$pr_url"
      ;;
    retrying)
      [ -n "$pr_url" ] || pr_url=$(sanitize_pr_url "$(existing_pr_url_for_branch "$branch")")
      [ -n "$pr_url" ] && set_worker "$num" "pr_url" "$pr_url"
      [ -n "$pr_url" ] || {
        mark_worker_resumable_failure "$num" "pr" "Missing PR while resuming retry for $branch" "$worker_log"
        return 1
      }
      run_retry_phase "$num" "$ISSUE_TITLE" "$branch" "$wt_path" "$worker_log" "$pr_url" "$review_text"
      ;;
    merging)
      [ -n "$pr_url" ] || pr_url=$(sanitize_pr_url "$(existing_pr_url_for_branch "$branch")")
      [ -n "$pr_url" ] && set_worker "$num" "pr_url" "$pr_url"
      [ -n "$pr_url" ] || {
        mark_worker_resumable_failure "$num" "pr" "Missing PR while resuming merge for $branch" "$worker_log"
        return 1
      }
      run_merge_phase "$num" "$ISSUE_TITLE" "$branch" "$wt_path" "$worker_log" "$pr_url"
      ;;
    *)
      work_issue "$issue_json"
      ;;
  esac
}

manager_phase_eligible() {
  case "$1" in
    merge_blocked|human_review|ci_failed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

manager_backoff_elapsed() {
  local num="$1" now last next_after
  now=$(date +%s)
  last=$(worker_field "$num" "manager_last_attempt_epoch")
  next_after=$(worker_field "$num" "manager_next_attempt_epoch")

  [ -n "$next_after" ] && [ "$next_after" -gt "$now" ] && return 1
  [ -z "$last" ] && return 0
  [ $((now - last)) -ge "$MANAGER_INTERVAL_SECONDS" ]
}

manage_issue() {
  local num="$1"
  local wfile title branch worker_log result_json status reason next_phase pr_url now next_after previous_phase issue_ref pr_ref
  wfile=$(worker_state_file "$num")
  [ -f "$wfile" ] || return 1

  title=$(worker_field "$num" "title")
  branch=$(worker_field "$num" "branch")
  worker_log=$(worker_field "$num" "log_file")
  previous_phase=$(worker_field "$num" "phase")
  if [ -z "$previous_phase" ] || [ "$previous_phase" = "managing" ]; then
    previous_phase=$(worker_field "$num" "manager_previous_phase")
  fi
  [ -n "$previous_phase" ] || previous_phase="merge_blocked"
  [ -n "$worker_log" ] || worker_log=$(worker_log_file "$num")

  set_worker "$num" "manager_previous_phase" "$previous_phase"
  set_worker "$num" "phase" "managing"
  set_worker "$num" "manager_model" "$MANAGER_MODEL"
  set_worker "$num" "manager_effort" "$MANAGER_EFFORT"
  now=$(date +%s)
  set_worker "$num" "manager_last_attempt_epoch" "$now"
  set_worker "$num" "manager_status" "running"
  write_worker_log "$worker_log" "Manager agent started"
  emit "manage_start" "[#$num] Manager agent running"

  issue_ref=$(worker_issue_ref "$num" || true)
  pr_ref=$(worker_field "$num" "pr_url")
  [ -n "$pr_ref" ] || pr_ref=$(worker_field "$num" "pr_number")

  local manage_args=(
    "$SCRIPT_DIR/manage.mjs"
    --worker-key "$num"
    --repo "$(pwd)"
    --agentify-dir "$AGENTIFY_DIR"
    --default-next-phase "$previous_phase"
    --prompt "$PROMPTS_DIR/manage.md"
  )
  [ -z "$issue_ref" ] || manage_args+=(--issue "$issue_ref")
  [ -z "$pr_ref" ] || manage_args+=(--pr "$pr_ref")

  if ! result_json=$(node "${manage_args[@]}" 2>> "$worker_log"); then
    if worker_log_has_github_rate_limit_error "$worker_log"; then
      pause_dispatch_for_github_rate_limit "$num" "$title" "$worker_log"
    fi
    set_worker "$num" "manager_status" "failed"
    mark_worker_resumable_failure "$num" "$previous_phase" "Manager agent failed for issue #$num" "$worker_log"
    return 1
  fi

  status=$(echo "$result_json" | jq -r '.status // "no_action"')
  reason=$(echo "$result_json" | jq -r '.reason // ""')
  next_phase=$(echo "$result_json" | jq -r --arg previous_phase "$previous_phase" '.next_phase // $previous_phase')
  pr_url=$(echo "$result_json" | jq -r '.snapshot.pr.url // .snapshot.pr_url // empty')
  [ -n "$pr_url" ] && set_worker "$num" "pr_url" "$pr_url"
  set_worker "$num" "manager_status" "$status"
  [ -n "$reason" ] && set_worker "$num" "last_error" "$reason"

  case "$status" in
    resolved)
      if [ -n "$pr_url" ] && gh pr view "$pr_url" --json state -q '.state' 2>> "$worker_log" | grep -qx "MERGED"; then
        complete_worker_success "$num" "$branch" "$worker_log" "Managed resolution complete" "Merged via manager"
        return 0
      fi
      set_worker "$num" "phase" "merging"
      write_worker_log "$worker_log" "Manager reported resolved but PR is not merged yet; leaving in merging"
      return 0
      ;;
    blocked)
      mark_worker_blocked_for_human "$num" "$next_phase" "$reason" "$worker_log"
      return 1
      ;;
    retry_later)
      next_after=$((now + MANAGER_INTERVAL_SECONDS))
      set_worker "$num" "phase" "$next_phase"
      set_worker "$num" "manager_next_attempt_epoch" "$next_after"
      write_worker_log "$worker_log" "Manager deferred follow-up until $(epoch_to_iso "$next_after")"
      emit "manage_deferred" "[#$num] Manager deferred further action"
      return 0
      ;;
    *)
      set_worker "$num" "phase" "$next_phase"
      next_after=$((now + MANAGER_INTERVAL_SECONDS))
      set_worker "$num" "manager_next_attempt_epoch" "$next_after"
      write_worker_log "$worker_log" "Manager finished with no action: $reason"
      emit "manage_done" "[#$num] Manager finished without action"
      return 0
      ;;
  esac
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
  report_repo_blocker_if_needed "$num" "$title" "$worker_log"

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

  run_post_coding_pipeline "$num" "$title" "$branch" "$wt_path" "$worker_log"
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
      '.completed = (.completed // "0")
       | .errors = (.errors // "0")
       | if (.paused_until_epoch // 0) > $now then .
         else del(.pause_kind, .pause_reason, .paused_until, .paused_until_epoch)
         end' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    echo '{"completed":"0","errors":"0"}' > "$STATE_FILE"
  fi
  [ -f "$EVENTS_FILE" ] || touch "$EVENTS_FILE"
  # Clean stale worker state from previous runs
  rm -f "$WORKERS_DIR"/*.pid 2>/dev/null
  # Prune stale worktrees from previous runs
  git worktree prune 2>/dev/null || true
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

    local wfile
    wfile=$(worker_state_file "$num")
    if [ -f "$wfile" ]; then
      # Worker state exists — check if the process is actually alive
      local pidfile="${wfile%.json}.pid"
      if [ -f "$pidfile" ]; then
        local wpid
        wpid=$(cat "$pidfile" 2>/dev/null || echo "0")
        if kill -0 "$wpid" 2>/dev/null; then
          continue  # Process alive, skip
        fi
        # Dead process — clean up stale files
        rm -f "$pidfile"
      fi
      rm -f "$wfile"
    fi

    gh issue edit "$num" --remove-label "agent-wip" --add-label "agent" 2>/dev/null || continue
    emit "requeued" "[#$num] Re-queued orphaned agent-wip issue ($source): $title"
  done
}

resume_orphaned_workers() {
  local slots="${1:-0}"
  [ "$slots" -le 0 ] && return 0

  for wfile in "$WORKERS_DIR"/*.json; do
    [ -f "$wfile" ] || continue

    local num phase title
    num=$(basename "$wfile" .json)
    phase=$(jq -r '.phase // "coding"' "$wfile" 2>/dev/null || echo "coding")
    title=$(jq -r '.title // ""' "$wfile" 2>/dev/null || echo "")

    is_issue_claimed "$num" && continue
    case "$phase" in
      merge_blocked|human_review|ci_failed|awaiting_human_conflict_resolution)
        continue
        ;;
    esac

    # Exponential backoff: don't resume if failed recently
    # retry 1 = wait 120s, retry 2+ = escalates to manager anyway
    local failed_at retries
    failed_at=$(jq -r '.failed_at // 0' "$wfile" 2>/dev/null || echo 0)
    retries=$(jq -r '.retries // 0' "$wfile" 2>/dev/null || echo 0)
    if [ "$failed_at" -gt 0 ] && [ "$retries" -gt 0 ]; then
      local now backoff_seconds
      now=$(date +%s)
      backoff_seconds=$((120 * retries))
      if [ $((now - failed_at)) -lt "$backoff_seconds" ]; then
        continue
      fi
    fi

    log "${C_YELLOW}Resuming worker for #$num: ${title:-issue $num} (${phase})"
    resume_worker "$num" &
    echo "$!" > "$WORKERS_DIR/$num.pid"
    slots=$((slots - 1))
    [ "$slots" -le 0 ] && break
  done

  return 0
}

spawn_management_workers() {
  local slots="${1:-0}"
  [ "$slots" -le 0 ] && return 0

  for wfile in "$WORKERS_DIR"/*.json; do
    [ -f "$wfile" ] || continue

    local num phase title
    num=$(basename "$wfile" .json)
    phase=$(jq -r '.phase // "coding"' "$wfile" 2>/dev/null || echo "coding")
    title=$(jq -r '.title // ""' "$wfile" 2>/dev/null || echo "")

    manager_phase_eligible "$phase" || continue
    manager_backoff_elapsed "$num" || continue
    is_issue_claimed "$num" && continue

    log "${C_YELLOW}Manager taking #$num: ${title:-issue $num} (${phase})"
    manage_issue "$num" &
    echo "$!" > "$WORKERS_DIR/$num.pid"
    slots=$((slots - 1))
    [ "$slots" -le 0 ] && break
  done

  return 0
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
  if [ -f "product_brief.md" ]; then
    printf "  ${C_DIM}├─${C_RESET} product brief: ${C_GREEN}loaded${C_RESET}\n"
  fi
  if [ -n "${AGENTIFY_SELF_REPO:-}" ]; then
    printf "  ${C_DIM}├─${C_RESET} self-heal repo: ${C_BOLD}$AGENTIFY_SELF_REPO${C_RESET}\n"
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
    local active
    active=$(active_worker_count)
    local slots
    slots=$((MAX_CONCURRENT - active))
    if [ "$slots" -gt 0 ]; then
      spawn_management_workers "$slots"
      active=$(active_worker_count)
      slots=$((MAX_CONCURRENT - active))
    fi
    if [ "$slots" -gt 0 ]; then
      resume_orphaned_workers "$slots"
      active=$(active_worker_count)
      slots=$((MAX_CONCURRENT - active))
    fi
    recover_orphaned_wip_issues "runtime"

    # Advance epics every cycle (detect completed issues, start next waves)
    if [ -d "$AGENTIFY_DIR/epics" ]; then
      source "$SCRIPT_DIR/planner.sh" 2>/dev/null
      check_epic_completion 2>/dev/null || true
    fi

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
    active=$(active_worker_count)
    slots=$((MAX_CONCURRENT - active))

    if [ "$slots" -gt 0 ]; then
      # Pick issues (only those labeled 'agent', not 'agent-wip')
      local issues_json
      issues_json=$(gh issue list --label agent --state open --limit 25 --json number,title,body 2>/dev/null)

      # LLM-driven sequencing: order by priority, then take what we need
      source "$SCRIPT_DIR/planner.sh" 2>/dev/null
      issues_json=$(sequence_issues "$issues_json" 2>/dev/null || echo "$issues_json")

      # Take only what we have slots for
      issues_json=$(echo "$issues_json" | jq -c ".[0:$slots]" 2>/dev/null || echo "$issues_json")
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
        if [ -d "$AGENTIFY_DIR/epics" ]; then
          source "$SCRIPT_DIR/planner.sh" 2>/dev/null
          check_epic_completion
        fi

        # Auto-group: when idle, check for ungrouped issues and propose epics
        if [ -z "${_last_auto_group_epoch:-}" ]; then
          _last_auto_group_epoch=0
        fi
        local _now_epoch
        _now_epoch=$(date +%s)
        local _auto_group_cooldown=${AUTO_GROUP_COOLDOWN_SECONDS:-600}
        if [ $((_now_epoch - _last_auto_group_epoch)) -ge "$_auto_group_cooldown" ]; then
          source "$SCRIPT_DIR/planner.sh" 2>/dev/null
          local _candidates
          _candidates=$(existing_group_candidates 2>/dev/null || echo "[]")
          local _candidate_count
          _candidate_count=$(echo "$_candidates" | jq 'length' 2>/dev/null || echo 0)
          if [ "$_candidate_count" -ge 2 ]; then
            log "${C_TEAL}Auto-grouping $_candidate_count ungrouped issues..."
            group_existing_issues 2>/dev/null || true
          fi
          _last_auto_group_epoch=$_now_epoch
        fi

        # Auto-ideate: when idle, propose features if no pending proposals exist
        if [ -z "${_last_ideation_epoch:-}" ]; then
          _last_ideation_epoch=0
        fi
        local _ideation_cooldown=${AUTO_IDEATION_COOLDOWN_SECONDS:-1800}
        if [ $((_now_epoch - _last_ideation_epoch)) -ge "$_ideation_cooldown" ]; then
          source "$SCRIPT_DIR/planner.sh" 2>/dev/null
          if [ -f "product_brief.md" ]; then
            log "${C_TEAL}Checking for feature proposals..."
            check_and_propose_features 2>/dev/null || true
          fi
          _last_ideation_epoch=$_now_epoch
        fi

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
