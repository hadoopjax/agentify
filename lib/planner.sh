#!/usr/bin/env bash
# agentify planner — epic breakdown via Claude + GPT-5.4 dialectic

epic_list_json() {
  control_plane epic-list | jq -c '.epics // []'
}

epic_get_json() {
  control_plane epic-get "$1"
}

save_epic_json() {
  control_plane epic-save "$1" > /dev/null
}

proposal_list_json() {
  control_plane proposal-list | jq -c '.proposals // []'
}

save_proposal_json() {
  control_plane proposal-save "$1" > /dev/null
}

# Call GPT-5.4 via API (no codex, pure planning — no filesystem side effects)
call_gpt() {
  local prompt="$1"
  local response
  response=$(curl -s --connect-timeout 10 --max-time 180 https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg model "$CODEX_MODEL" --arg prompt "$prompt" '{
      model: $model,
      messages: [{"role": "user", "content": $prompt}],
      reasoning_effort: "high"
    }')")

  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    echo "OpenAI planning call failed: $(echo "$response" | jq -r '.error.message // "unknown error"')" >&2
    return 1
  fi

  echo "$response" | jq -er '.choices[0].message.content'
}

compact_issue_digest() {
  local issues_json="$1"
  echo "$issues_json" | jq -c '
    map({
      number,
      title,
      labels
    })
  '
}

extract_json() {
  python3 -c '
import json
import sys

text = sys.stdin.read()

for start, opener, closer in ((text.find("{"), "{", "}"), (text.find("["), "[", "]")):
    if start == -1:
        continue
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "\"":
                in_string = False
            continue
        if ch == "\"":
            in_string = True
        elif ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                candidate = text[start:i + 1]
                json.loads(candidate)
                sys.stdout.write(candidate)
                raise SystemExit(0)

raise SystemExit(1)
' 2>/dev/null
}

reserved_existing_issue_numbers() {
  epic_list_json | jq -r '
      select((.kind // "") == "existing-issues") |
      .proposals[]? |
      select((.status // "") != "rejected" and (.status // "") != "complete") |
      .issue_numbers[]?
    ' 2>/dev/null | awk '!seen[$0]++'
}

existing_group_candidates() {
  local issues_json
  issues_json=$(gh issue list --state open --limit 100 \
    --json number,title,body,labels,createdAt,updatedAt 2>/dev/null)

  local reserved
  reserved=$(reserved_existing_issue_numbers | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  [ -n "$reserved" ] || reserved="[]"

  echo "$issues_json" | jq -c --argjson reserved "$reserved" '
    map(. + {
      label_names: [.labels[]?.name],
      body: ((.body // "") | gsub("\r"; "") | .[0:280])
    })
    | map(. as $issue | select(
        ($issue.label_names | index("agent")) == null and
        ($issue.label_names | index("agent-wip")) == null and
        ($issue.label_names | index("agent-skip")) == null and
        ($issue.label_names | index("epic")) == null and
        ($reserved | index($issue.number)) == null
      ))
    | map({
        number,
        title,
        body,
        labels: .label_names,
        created_at: .createdAt,
        updated_at: .updatedAt
      })
  '
}

normalize_existing_group_plan() {
  local issues_json="$1"
  local claude_groups_json="$2"
  local gpt_critique_json="$3"

python3 - "$issues_json" "$claude_groups_json" "$gpt_critique_json" <<'PY'
import json
import re
import sys

def safe_json(payload, fallback):
    if not payload:
        return fallback
    try:
        return json.loads(payload)
    except Exception:
        return fallback


issues = safe_json(sys.argv[1], [])
claude = safe_json(sys.argv[2], {})
gpt = safe_json(sys.argv[3], {})

valid = {issue["number"] for issue in issues}
issue_meta = {issue["number"]: issue for issue in issues}
claimed = set()
proposals = []
dropped_groups = []


def parse_issue_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        raw = value.strip()
        if raw.startswith("#"):
            raw = raw[1:].strip()
        match = re.search(r"^\d+$", raw)
        if match:
            return int(match.group())
    return None

def as_priority(value):
    value = (value or "medium").lower()
    return value if value in {"high", "medium", "low"} else "medium"

def normalize_waves(issue_numbers, raw_waves):
    allowed = set(issue_numbers)
    seen = set()
    waves = []

    if isinstance(raw_waves, list):
        for wave in raw_waves:
          if not isinstance(wave, list):
            continue
          for value in wave:
            issue_number = parse_issue_number(value)
            if issue_number is None:
              continue
            if issue_number in allowed and issue_number not in seen:
              # Existing-issue epics run one issue at a time within an epic.
              # This keeps cross-epic parallelism while avoiding same-subsystem conflicts.
              waves.append([issue_number])
              seen.add(issue_number)

    for num in issue_numbers:
      if num not in seen:
        waves.append([num])

    return waves

feedback = gpt.get("feedback")
if not isinstance(feedback, list):
    feedback = []

feedback_by_index = {}
for item in feedback:
    if not isinstance(item, dict):
        continue
    index = item.get("group_index")
    comment = (item.get("comment") or "").strip()
    if isinstance(index, int) and comment:
        feedback_by_index.setdefault(index, []).append(comment)

def append_groups(groups, source):
    if not isinstance(groups, list):
        return

    for group_index, group in enumerate(groups):
        if not isinstance(group, dict):
            continue

        if source == "claude" and group_index in feedback_by_index:
            raw_numbers = group.get("issue_numbers")
            issue_numbers = []
            if isinstance(raw_numbers, list):
                for value in raw_numbers:
                    issue_number = parse_issue_number(value)
                    if issue_number is None:
                        continue
                    labels = issue_meta.get(issue_number, {}).get("labels", [])
                    if issue_number in valid and "epic" not in labels and issue_number not in issue_numbers:
                        issue_numbers.append(issue_number)

            dropped_groups.append({
                "title": (group.get("title") or "").strip() or f"Dropped group {group_index}",
                "issue_numbers": issue_numbers,
                "reasons": feedback_by_index[group_index],
                "source": source,
            })
            continue

        raw_numbers = group.get("issue_numbers")
        if not isinstance(raw_numbers, list):
            continue

        issue_numbers = []
        for value in raw_numbers:
            issue_number = parse_issue_number(value)
            if issue_number is None:
                continue
            labels = issue_meta.get(issue_number, {}).get("labels", [])
            if issue_number in valid and "epic" not in labels and issue_number not in claimed and issue_number not in issue_numbers:
                issue_numbers.append(issue_number)

        if len(issue_numbers) != 2:
            continue

        claimed.update(issue_numbers)
        proposals.append({
            "title": (group.get("title") or "").strip() or f"Epic for issues {'/'.join(str(n) for n in issue_numbers)}",
            "body": (group.get("summary") or "").strip(),
            "priority": as_priority(group.get("priority")),
            "status": "pending",
            "source": source,
            "issue_numbers": issue_numbers,
            "rationale": (group.get("rationale") or "").strip(),
            "execution_notes": (group.get("execution_notes") or "").strip(),
            "waves": normalize_waves(issue_numbers, group.get("waves")),
            "started_waves": 0
        })

append_groups(claude.get("groups"), "claude")
append_groups(gpt.get("additional_groups"), "gpt-5.4")

ungrouped = sorted(valid - claimed)
requested = []
for payload in (claude.get("ungrouped_issue_numbers"), gpt.get("ungrouped_issue_numbers")):
    if isinstance(payload, list):
        for value in payload:
            issue_number = parse_issue_number(value)
            if issue_number is None:
                continue
            if issue_number in valid and issue_number not in claimed:
                requested.append(issue_number)

for num in requested:
    if num not in ungrouped:
        ungrouped.append(num)

print(json.dumps({
    "proposals": proposals,
    "ungrouped_issue_numbers": sorted(set(ungrouped)),
    "feedback": feedback,
    "dropped_groups": dropped_groups,
    "claude_notes": claude.get("notes") or "",
    "gpt_notes": gpt.get("notes") or ""
}))
PY
}

plan_epic() {
  local description="$1"
  local epic_id=$(date +%s)

  log "${C_TEAL}Planning epic: $description"
  emit "plan_start" "Planning: $description"

  # -- Step 1: Claude proposes the breakdown --
  log "${C_CORAL}Claude proposing issues..."

  local plan_prompt
  ISSUE_NUM="" ISSUE_TITLE="" ISSUE_BODY="" ISSUE_DIFF="" REVIEW_TEXT=""
  local description_escaped="$description"

  # Build prompt manually (can't use render_prompt since vars are different)
  local plan_template
  plan_template=$(cat "$PROMPTS_DIR/plan.md")
  plan_template="${plan_template//\{\{DESCRIPTION\}\}/$description_escaped}"
  plan_template="${plan_template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"

  local claude_response
  claude_response=$(claude -p --model "$CLAUDE_MODEL" "$plan_template")

  local claude_plan
  claude_plan=$(echo "$claude_response" | extract_json || true)
  [ -n "$claude_plan" ] || claude_plan='{"issues":[],"notes":""}'

  local issue_count
  issue_count=$(echo "$claude_plan" | jq '.issues | length' 2>/dev/null || echo 0)
  log "${C_TEAL}Claude proposed $issue_count issues"
  emit "plan_claude" "Claude proposed $issue_count issues"

  # -- Step 2: GPT-5.4 critiques --
  log "${C_YELLOW}GPT-5.4 reviewing plan..."

  local critique_template
  critique_template=$(cat "$PROMPTS_DIR/plan-critique.md")
  critique_template="${critique_template//\{\{DESCRIPTION\}\}/$description_escaped}"
  critique_template="${critique_template//\{\{PLAN_JSON\}\}/$claude_plan}"
  critique_template="${critique_template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"

  local gpt_response
  gpt_response=$(call_gpt "$critique_template")

  local gpt_critique
  gpt_critique=$(echo "$gpt_response" | extract_json || true)
  [ -n "$gpt_critique" ] || gpt_critique='{"feedback":[],"additional_issues":[],"notes":""}'

  local additional_count
  additional_count=$(echo "$gpt_critique" | jq '.additional_issues | length' 2>/dev/null || echo 0)
  log "${C_YELLOW}GPT-5.4: $additional_count additional issues suggested"
  emit "plan_gpt" "GPT-5.4 added $additional_count issues, reviewed plan"

  # -- Step 3: Merge into epic --
  # Build proposals array: Claude's issues + GPT's additions
  local proposals="[]"

  # Add Claude's issues
  proposals=$(echo "$claude_plan" | jq -c '[.issues[] | {
    title: .title,
    body: .body,
    priority: .priority,
    validation_commands: (.validation_commands // []),
    required_checks: (.required_checks // []),
    files_of_interest: (.files_of_interest // []),
    status: "pending",
    source: "claude",
    issue_number: null
  }]' 2>/dev/null || echo "[]")

  # Add GPT's additional issues
  local gpt_additions
  gpt_additions=$(echo "$gpt_critique" | jq -c '[.additional_issues[]? | {
    title: .title,
    body: .body,
    priority: .priority,
    validation_commands: (.validation_commands // []),
    required_checks: (.required_checks // []),
    files_of_interest: (.files_of_interest // []),
    status: "pending",
    source: "gpt-5.4",
    issue_number: null
  }]' 2>/dev/null || echo "[]")

  proposals=$(echo "$proposals $gpt_additions" | jq -s 'add')

  # Apply GPT's feedback as annotations on Claude's issues
  local feedback
  feedback=$(echo "$gpt_critique" | jq -c '.feedback // []')

  # Build the epic file
  local epic_payload
  epic_payload=$(jq -nc \
    --arg id "$epic_id" \
    --arg title "$description" \
    --arg status "planning" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg claude_notes "$(echo "$claude_plan" | jq -r '.notes // ""')" \
    --arg gpt_notes "$(echo "$gpt_critique" | jq -r '.notes // ""')" \
    --argjson proposals "$proposals" \
    --argjson feedback "$feedback" \
    '{
      id: $id,
      title: $title,
      status: $status,
      created_at: $created,
      proposals: $proposals,
      feedback: $feedback,
      claude_notes: $claude_notes,
      gpt_notes: $gpt_notes
    }')
  save_epic_json "$epic_payload"

  local total=$(echo "$proposals" | jq 'length')
  log "${C_GREEN}Epic planned: $total proposed issues"
  emit "plan_done" "Epic '$description' — $total issues proposed"

  # Print summary
  printf "\n  ${C_BOLD}Epic: $description${C_RESET}\n"
  printf "  ${C_DIM}ID: $epic_id${C_RESET}\n\n"

  echo "$proposals" | jq -r '.[] | "  [\(.source)] \(.title)"'

  if [ "$(echo "$feedback" | jq 'length')" -gt 0 ]; then
    printf "\n  ${C_YELLOW}GPT-5.4 feedback:${C_RESET}\n"
    echo "$feedback" | jq -r '.[] | "  #\(.issue_index): \(.comment)"'
  fi

  printf "\n  ${C_DIM}Claude notes: $(echo "$claude_plan" | jq -r '.notes // "none"')${C_RESET}\n"
  printf "  ${C_DIM}GPT-5.4 notes: $(echo "$gpt_critique" | jq -r '.notes // "none"')${C_RESET}\n"
  printf "\n  Approve issues in the dashboard: ${C_TEAL}http://localhost:${DASHBOARD_PORT:-4242}${C_RESET}\n"
  printf "  Or: ${C_DIM}agentify approve $epic_id${C_RESET}\n\n"

  echo "$epic_id"
}

group_existing_issues() {
  local epic_id
  epic_id=$(date +%s)

  local issues_json
  issues_json=$(existing_group_candidates)

  local issue_count
  issue_count=$(echo "$issues_json" | jq 'length')
  if [ "$issue_count" -lt 2 ]; then
    echo "Need at least 2 eligible open issues to propose epic groupings."
    return 1
  fi

  log "${C_TEAL}Grouping $issue_count existing issues into epic proposals"
  emit "group_start" "Grouping $issue_count existing issues"

  local groups_template
  groups_template=$(cat "$PROMPTS_DIR/group-existing.md")
  groups_template="${groups_template//\{\{ISSUES_JSON\}\}/$issues_json}"
  groups_template="${groups_template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"

  log "${C_CORAL}Claude proposing issue groups..."
  local claude_response claude_groups
  claude_response=$(claude -p --model "$CLAUDE_MODEL" "$groups_template")
  claude_groups=$(echo "$claude_response" | extract_json || true)
  [ -n "$claude_groups" ] || claude_groups='{"groups":[],"ungrouped_issue_numbers":[],"notes":""}'

  local claude_count
  claude_count=$(echo "$claude_groups" | jq '.groups | length' 2>/dev/null || echo 0)
  emit "group_claude" "Claude proposed $claude_count epic groups"

  local critique_template
  critique_template=$(cat "$PROMPTS_DIR/group-existing-critique.md")
  local critique_issues
  critique_issues=$(compact_issue_digest "$issues_json")
  critique_template="${critique_template//\{\{ISSUES_JSON\}\}/$critique_issues}"
  local critique_groups
  critique_groups=$(echo "$claude_groups" | jq -c '{
    groups: [.groups[]? | {
      title,
      priority,
      issue_numbers,
      waves,
      execution_notes
    }],
    ungrouped_issue_numbers: (.ungrouped_issue_numbers // []),
    notes: (.notes // "")
  }')
  critique_template="${critique_template//\{\{GROUPS_JSON\}\}/$critique_groups}"
  critique_template="${critique_template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"

  log "${C_YELLOW}GPT-5.4 reviewing grouping..."
  local gpt_response gpt_critique
  gpt_response=$(call_gpt "$critique_template")
  gpt_critique=$(echo "$gpt_response" | extract_json || true)
  [ -n "$gpt_critique" ] || gpt_critique='{"feedback":[],"additional_groups":[],"ungrouped_issue_numbers":[],"notes":""}'

  local normalized
  normalized=$(normalize_existing_group_plan "$issues_json" "$claude_groups" "$gpt_critique")

  local epic_payload
  epic_payload=$(jq -nc \
    --arg id "$epic_id" \
    --arg title "Existing issue grouping $(date +%Y-%m-%d)" \
    --arg kind "existing-issues" \
    --arg status "planning" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson proposals "$(echo "$normalized" | jq '.proposals')" \
    --argjson feedback "$(echo "$normalized" | jq '.feedback')" \
    --argjson dropped_groups "$(echo "$normalized" | jq '.dropped_groups')" \
    --argjson ungrouped "$(echo "$normalized" | jq '.ungrouped_issue_numbers')" \
    --arg claude_notes "$(echo "$normalized" | jq -r '.claude_notes')" \
    --arg gpt_notes "$(echo "$normalized" | jq -r '.gpt_notes')" \
    '{
      id: $id,
      title: $title,
      kind: $kind,
      status: $status,
      created_at: $created,
      proposals: $proposals,
      feedback: $feedback,
      dropped_groups: $dropped_groups,
      ungrouped_issue_numbers: $ungrouped,
      claude_notes: $claude_notes,
      gpt_notes: $gpt_notes
    }')
  save_epic_json "$epic_payload"

  local total
  total=$(echo "$normalized" | jq '.proposals | length')
  local dropped_count
  dropped_count=$(echo "$normalized" | jq '.dropped_groups | length')
  local ungrouped_count
  ungrouped_count=$(echo "$normalized" | jq '.ungrouped_issue_numbers | length')
  emit "group_done" "Proposed $total epic groups from existing issues"

  printf "\n  ${C_BOLD}Existing issue grouping${C_RESET}\n"
  printf "  ${C_DIM}ID: $epic_id${C_RESET}\n\n"
  echo "$normalized" | jq -r '.proposals[] | "  [\(.source)] \(.title) — \(.issue_numbers | map("#" + tostring) | join(", "))"'
  if [ "$dropped_count" -gt 0 ]; then
    printf "\n  ${C_YELLOW}%s flagged groups were dropped by GPT review${C_RESET}\n" "$dropped_count"
    echo "$normalized" | jq -r '.dropped_groups[] | "  [dropped] \(.title) — \(.issue_numbers | map("#" + tostring) | join(", "))"'
  fi
  printf "\n  ${C_DIM}%s ungrouped issues remain${C_RESET}\n" "$ungrouped_count"
  printf "  Approve groups in the dashboard: ${C_TEAL}http://localhost:${DASHBOARD_PORT:-4242}${C_RESET}\n"
  printf "  Or: ${C_DIM}agentify approve $epic_id${C_RESET}\n\n"

  echo "$epic_id"
}

approve_issue() {
  control_plane approve-epic --repo "$(pwd)" "$1" "$2" > /dev/null
}

reject_issue() {
  control_plane reject-epic "$1" "$2" > /dev/null
}

approve_all() {
  control_plane approve-all --repo "$(pwd)" "$1" > /dev/null
  log "${C_GREEN}All pending issues approved and created"
}

advance_existing_issue_epics() {
  local epics_json
  epics_json=$(epic_list_json)
  for epic_id in $(echo "$epics_json" | jq -r '.[]?.id'); do
    local epic_json
    epic_json=$(echo "$epics_json" | jq -c --arg id "$epic_id" '.[] | select(.id == $id)')

    local epic_kind
    epic_kind=$(echo "$epic_json" | jq -r '.kind // ""')
    [ "$epic_kind" = "existing-issues" ] || continue

    local changed=0
    local proposals_len
    proposals_len=$(echo "$epic_json" | jq '.proposals | length')

    for ((i=0; i<proposals_len; i++)); do
      local proposal_status
      proposal_status=$(echo "$epic_json" | jq -r ".proposals[$i].status")
      [ "$proposal_status" = "approved" ] || continue

      local started total_waves
      started=$(echo "$epic_json" | jq -r ".proposals[$i].started_waves // 0")
      total_waves=$(echo "$epic_json" | jq -r ".proposals[$i].waves | length")

      # Fix: if approved but started_waves is 0, kick off the first wave
      if [ "$started" -eq 0 ] && [ "$total_waves" -gt 0 ]; then
        local first_wave_numbers
        first_wave_numbers=$(echo "$epic_json" | jq -r ".proposals[$i].waves[0][]?")
        for num in $first_wave_numbers; do
          gh issue edit "$num" --add-label "agent" > /dev/null 2>&1
        done
        epic_json=$(echo "$epic_json" | jq --argjson i "$i" '.proposals[$i].started_waves = 1')
        started=1
        changed=1
        local title
        title=$(echo "$epic_json" | jq -r ".proposals[$i].title")
        emit "group_wave_started" "Recovered stalled proposal — started first wave: $title"
      fi

      [ "$started" -gt 0 ] || continue

      local current_wave_done=true
      local current_wave_numbers
      current_wave_numbers=$(echo "$epic_json" | jq -r ".proposals[$i].waves[$((started - 1))][]?")

      for num in $current_wave_numbers; do
        local state
        state=$(gh issue view "$num" --json state -q '.state' 2>/dev/null)
        if [ "$state" != "CLOSED" ]; then
          current_wave_done=false
          break
        fi
      done

      [ "$current_wave_done" = true ] || continue

      if [ "$started" -lt "$total_waves" ]; then
        local next_wave_numbers
        next_wave_numbers=$(echo "$epic_json" | jq -r ".proposals[$i].waves[$started][]?")
        for num in $next_wave_numbers; do
          gh issue edit "$num" --add-label "agent" > /dev/null 2>&1
        done

        epic_json=$(echo "$epic_json" | jq --argjson i "$i" '
          .proposals[$i].started_waves = ((.proposals[$i].started_waves // 0) + 1)
        ')
        changed=1

        local title
        title=$(echo "$epic_json" | jq -r ".proposals[$i].title")
        emit "group_wave_started" "Started next wave for existing issue group: $title"
      else
        local all_closed=true
        local issue_nums
        issue_nums=$(echo "$epic_json" | jq -r ".proposals[$i].issue_numbers[]?")
        for num in $issue_nums; do
          local state
          state=$(gh issue view "$num" --json state -q '.state' 2>/dev/null)
          if [ "$state" != "CLOSED" ]; then
            all_closed=false
            break
          fi
        done

        if [ "$all_closed" = true ]; then
          epic_json=$(echo "$epic_json" | jq --argjson i "$i" '.proposals[$i].status = "complete"')
          changed=1

          local title
          title=$(echo "$epic_json" | jq -r ".proposals[$i].title")
          emit "group_complete" "Existing issue group complete: $title"
        fi
      fi
    done

    if [ "$changed" -eq 1 ]; then
      local pending approved complete
      pending=$(echo "$epic_json" | jq '[.proposals[] | select(.status == "pending")] | length')
      approved=$(echo "$epic_json" | jq '[.proposals[] | select(.status == "approved")] | length')
      complete=$(echo "$epic_json" | jq '[.proposals[] | select(.status == "complete")] | length')

      if [ "$pending" -eq 0 ] && [ "$approved" -eq 0 ] && [ "$complete" -gt 0 ]; then
        epic_json=$(echo "$epic_json" | jq '.status = "complete"')
      elif [ "$approved" -gt 0 ] || [ "$complete" -gt 0 ]; then
        epic_json=$(echo "$epic_json" | jq '.status = "active"')
      fi
      save_epic_json "$epic_json"
    fi
  done

  return 0
}

check_epic_completion() {
  advance_existing_issue_epics

  local epics_json
  epics_json=$(epic_list_json)
  for epic_id in $(echo "$epics_json" | jq -r '.[]?.id'); do
    local epic_json
    epic_json=$(echo "$epics_json" | jq -c --arg id "$epic_id" '.[] | select(.id == $id)')
    local status
    status=$(echo "$epic_json" | jq -r '.status')
    [ "$status" != "active" ] && continue

    local epic_kind
    epic_kind=$(echo "$epic_json" | jq -r '.kind // "planned-issues"')
    [ "$epic_kind" = "existing-issues" ] && continue

    # Check if all approved issues are closed
    local all_done=true
    local issue_nums
    issue_nums=$(echo "$epic_json" | jq -r '.proposals[] | select(.status == "approved") | .issue_number // empty')

    for num in $issue_nums; do
      local state=$(gh issue view "$num" --json state -q '.state' 2>/dev/null)
      if [ "$state" != "CLOSED" ]; then
        all_done=false
        break
      fi
    done

    if [ "$all_done" = true ] && [ -n "$issue_nums" ]; then
      local title
      title=$(echo "$epic_json" | jq -r '.title')
      log "${C_GREEN}Epic complete: $title"
      emit "epic_complete" "Epic complete: $title"
      epic_json=$(echo "$epic_json" | jq '.status = "complete"')
      save_epic_json "$epic_json"
    fi
  done

  return 0
}

propose_features() {
  [ -f "product_brief.md" ] || return 0

  local ideate_template="$PROMPTS_DIR/ideate.md"
  [ -f "$ideate_template" ] || return 0

  local codebase_summary
  codebase_summary=$(
    {
      echo "."
      find . -mindepth 1 -maxdepth 1 \
        \( -name ".git" -o -name ".agentify" -o -name "node_modules" \) -prune -o -print \
        | sort \
        | while read -r path; do
            local name
            name="${path#./}"

            if [ -d "$path" ]; then
              echo "|- $name/"
              find "$path" -mindepth 1 -maxdepth 1 -type f ! -name ".DS_Store" \
                | sort | head -n 5 \
                | while read -r file; do
                    echo "|  |- ${file#$path/}"
                  done
            else
              echo "|- $name"
            fi
          done
    } | head -n 50
  )

  local ideate_prompt
  ideate_prompt=$(cat "$ideate_template")
  ideate_prompt="${ideate_prompt//\{\{REPO_CONTEXT\}\}/$(repo_context)}"
  ideate_prompt="${ideate_prompt//\{\{CODEBASE_SUMMARY\}\}/$codebase_summary}"

  local claude_response
  claude_response=$(claude -p --model "$CLAUDE_MODEL" "$ideate_prompt")

  local ideation_json
  ideation_json=$(echo "$claude_response" | extract_json || true)
  [ -n "$ideation_json" ] || ideation_json='{"features":[],"notes":""}'

  local features
  features=$(echo "$ideation_json" | jq -c 'if (.features | type) == "array" then .features else [] end' 2>/dev/null || echo "[]")

  local feature_count
  feature_count=$(echo "$features" | jq 'length' 2>/dev/null || echo 0)

  local proposal_id
  proposal_id=$(date +%s)
  local proposal_payload
  proposal_payload=$(jq -nc \
    --argjson id "$proposal_id" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "pending" \
    --argjson features "$features" \
    '{
      id: $id,
      created_at: $created,
      status: $status,
      features: $features
    }')
  save_proposal_json "$proposal_payload"

  emit "ideation_done" "Proposed $feature_count new features"

  printf "\n  ${C_BOLD}Feature proposals${C_RESET}\n"
  printf "  ${C_DIM}ID: $proposal_id${C_RESET}\n\n"
  if [ "$feature_count" -gt 0 ]; then
    echo "$features" | jq -r '.[] | "  [\(.priority // "medium")] \(.title // "Untitled feature")"'
  else
    printf "  ${C_DIM}No features proposed${C_RESET}\n"
  fi
  printf "\n  ${C_DIM}Saved in state.db${C_RESET}\n\n"
}

check_and_propose_features() {
  [ -f "product_brief.md" ] || return 0

  local proposals_json
  proposals_json=$(proposal_list_json)
  if [ "$(echo "$proposals_json" | jq '[.[] | select(.status == "pending")] | length')" -gt 0 ]; then
    return 0
  fi

  propose_features
}

sequence_issues() {
  local issues_json="$1"
  local count
  count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

  # Skip if 3 or fewer issues — not worth an LLM call
  if [ "$count" -le 3 ]; then
    echo "$issues_json"
    return 0
  fi

  local template
  template=$(cat "$PROMPTS_DIR/sequence.md")
  template="${template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"
  template="${template//\{\{ISSUES_JSON\}\}/$issues_json}"

  local response
  response=$(claude -p --model "$CLAUDE_MODEL" "$template" 2>/dev/null || true)

  local ordered_json
  ordered_json=$(echo "$response" | extract_json || true)
  [ -n "$ordered_json" ] || { echo "$issues_json"; return 0; }

  # Reorder issues_json according to ordered_numbers
  python3 -c "
import json, sys
issues = json.loads(sys.argv[1])
order_data = json.loads(sys.argv[2])
ordered_nums = order_data.get('ordered_numbers', [])
by_num = {i['number']: i for i in issues}
result = []
for n in ordered_nums:
    if n in by_num:
        result.append(by_num.pop(n))
# Append any issues not mentioned
result.extend(by_num.values())
print(json.dumps(result))
" "$issues_json" "$ordered_json"
}
