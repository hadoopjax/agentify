#!/usr/bin/env bash
# agentify planner — epic breakdown via Claude + GPT-5.4 dialectic

EPICS_DIR="$AGENTIFY_DIR/epics"

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

dropped_group_digest() {
  local issues_json="$1"
  local claude_groups_json="$2"
  local gpt_critique_json="$3"

  python3 - "$issues_json" "$claude_groups_json" "$gpt_critique_json" <<'PY'
import json
import sys

issues = json.loads(sys.argv[1] or "[]")
claude = json.loads(sys.argv[2] or "{}")
gpt = json.loads(sys.argv[3] or "{}")

issue_meta = {issue["number"]: issue for issue in issues}
feedback = gpt.get("feedback")
if not isinstance(feedback, list):
    feedback = []

dropped = []
seen_issue_numbers = []
seen = set()

for item in feedback:
    if not isinstance(item, dict):
        continue
    index = item.get("group_index")
    if not isinstance(index, int):
        continue
    groups = claude.get("groups")
    if not isinstance(groups, list) or not (0 <= index < len(groups)):
        continue

    group = groups[index]
    raw_numbers = group.get("issue_numbers")
    issue_numbers = []
    if isinstance(raw_numbers, list):
        for value in raw_numbers:
            meta = issue_meta.get(value)
            labels = meta.get("labels", []) if isinstance(meta, dict) else []
            if isinstance(value, int) and isinstance(meta, dict) and "epic" not in labels and value not in issue_numbers:
                issue_numbers.append(value)
                if value not in seen:
                    seen.add(value)
                    seen_issue_numbers.append(value)

    dropped.append({
        "title": (group.get("title") or "").strip() or f"Dropped group {index}",
        "issue_numbers": issue_numbers,
        "reasons": [(item.get("comment") or "").strip()] if (item.get("comment") or "").strip() else []
    })

print(json.dumps({
    "dropped_groups": dropped,
    "issues": [issue_meta[num] for num in seen_issue_numbers if num in issue_meta]
}))
PY
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
  [ -d "$EPICS_DIR" ] || return 0

  for epic_file in "$EPICS_DIR"/*.json; do
    [ -f "$epic_file" ] || continue
    jq -r '
      select((.kind // "") == "existing-issues") |
      .proposals[]? |
      select((.status // "") != "rejected" and (.status // "") != "complete") |
      .issue_numbers[]?
    ' "$epic_file" 2>/dev/null
  done | awk '!seen[$0]++'
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
import sys

issues = json.loads(sys.argv[1] or "[]")
claude = json.loads(sys.argv[2] or "{}")
gpt = json.loads(sys.argv[3] or "{}")

valid = {issue["number"] for issue in issues}
issue_meta = {issue["number"]: issue for issue in issues}
claimed = set()
proposals = []
dropped_groups = []

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
          if isinstance(value, int) and value in allowed and value not in seen:
            # Existing-issue epics run one issue at a time within an epic.
            # This keeps cross-epic parallelism while avoiding same-subsystem conflicts.
            waves.append([value])
            seen.add(value)

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
                    labels = issue_meta.get(value, {}).get("labels", [])
                    if isinstance(value, int) and value in valid and "epic" not in labels and value not in issue_numbers:
                        issue_numbers.append(value)

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
            labels = issue_meta.get(value, {}).get("labels", [])
            if isinstance(value, int) and value in valid and "epic" not in labels and value not in claimed and value not in issue_numbers:
                issue_numbers.append(value)

        if len(issue_numbers) < 2:
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
        requested.extend(v for v in payload if isinstance(v, int) and v in valid and v not in claimed)

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
  mkdir -p "$EPICS_DIR"

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
    status: "pending",
    source: "gpt-5.4",
    issue_number: null
  }]' 2>/dev/null || echo "[]")

  proposals=$(echo "$proposals $gpt_additions" | jq -s 'add')

  # Apply GPT's feedback as annotations on Claude's issues
  local feedback
  feedback=$(echo "$gpt_critique" | jq -c '.feedback // []')

  # Build the epic file
  local epic_file="$EPICS_DIR/$epic_id.json"
  jq -nc \
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
    }' > "$epic_file"

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
  mkdir -p "$EPICS_DIR"

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

  local dropped_digest
  dropped_digest=$(dropped_group_digest "$issues_json" "$claude_groups" "$gpt_critique")

  local dropped_issue_count
  dropped_issue_count=$(echo "$dropped_digest" | jq '.issues | length')
  if [ "$dropped_issue_count" -ge 2 ]; then
    log "${C_YELLOW}GPT-5.4 salvaging dropped groups..."

    local salvage_template
    salvage_template=$(cat "$PROMPTS_DIR/group-existing-salvage.md")
    salvage_template="${salvage_template//\{\{ISSUES_JSON\}\}/$(echo "$dropped_digest" | jq -c '.issues')}"
    salvage_template="${salvage_template//\{\{DROPPED_GROUPS_JSON\}\}/$(echo "$dropped_digest" | jq -c '.dropped_groups')}"
    salvage_template="${salvage_template//\{\{REPO_CONTEXT\}\}/$(repo_context)}"

    local salvage_response salvage_json
    salvage_response=$(call_gpt "$salvage_template")
    salvage_json=$(echo "$salvage_response" | extract_json || true)
    [ -n "$salvage_json" ] || salvage_json='{"replacement_groups":[],"ungrouped_issue_numbers":[],"notes":""}'

    gpt_critique=$(jq -c \
      --argjson salvage "$salvage_json" \
      '.additional_groups = ((.additional_groups // []) + ($salvage.replacement_groups // [])) |
       .ungrouped_issue_numbers = ((.ungrouped_issue_numbers // []) + ($salvage.ungrouped_issue_numbers // [])) |
       .notes = ([.notes, ($salvage.notes // "")] | map(select(length > 0)) | join(" "))' \
      <<<"$gpt_critique")
  fi

  local normalized
  normalized=$(normalize_existing_group_plan "$issues_json" "$claude_groups" "$gpt_critique")

  local epic_file="$EPICS_DIR/$epic_id.json"
  jq -nc \
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
    }' > "$epic_file"

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
  local epic_id="$1" index="$2"
  local epic_file="$EPICS_DIR/$epic_id.json"

  [ ! -f "$epic_file" ] && { echo "Epic not found: $epic_id"; return 1; }

  local proposal
  proposal=$(jq -c ".proposals[$index]" "$epic_file")
  [ "$proposal" = "null" ] && { echo "Issue index $index not found"; return 1; }

  local status=$(echo "$proposal" | jq -r '.status')
  [ "$status" != "pending" ] && { echo "Issue already $status"; return 1; }

  local epic_kind
  epic_kind=$(jq -r '.kind // "planned-issues"' "$epic_file")

  if [ "$epic_kind" = "existing-issues" ]; then
    local title wave_numbers
    title=$(echo "$proposal" | jq -r '.title')
    wave_numbers=$(echo "$proposal" | jq -r '.waves[0][]?')
    [ -n "$wave_numbers" ] || { echo "Proposal has no execution wave"; return 1; }

    for num in $wave_numbers; do
      gh issue edit "$num" --add-label "agent" 2>/dev/null
    done

    local tmp=$(mktemp)
    jq --argjson i "$index" '
      .proposals[$i].status = "approved" |
      .proposals[$i].started_waves = 1 |
      .status = "active"
    ' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"

    log "${C_GREEN}Approved existing issue group: $title"
    emit "group_approved" "Approved existing issue group: $title"
    return 0
  fi

  local title=$(echo "$proposal" | jq -r '.title')
  local body=$(echo "$proposal" | jq -r '.body')

  local issue_url
  issue_url=$(gh issue create \
    --title "$title" \
    --body "$body

---
*Part of epic: $(jq -r '.title' "$epic_file")*" \
    --label "agent")

  local issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

  local tmp=$(mktemp)
  jq --argjson i "$index" --arg num "$issue_num" \
    '.proposals[$i].status = "approved" | .proposals[$i].issue_number = ($num | tonumber)' \
    "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"

  # Check if all pending are resolved — if so, mark epic active
  local pending=$(jq '[.proposals[] | select(.status == "pending")] | length' "$epic_file")
  if [ "$pending" -eq 0 ]; then
    local tmp2=$(mktemp)
    jq '.status = "active"' "$epic_file" > "$tmp2" && mv "$tmp2" "$epic_file"
  fi

  log "${C_GREEN}Approved: #$issue_num $title"
  emit "issue_approved" "Approved #$issue_num: $title (epic: $epic_id)"
}

reject_issue() {
  local epic_id="$1" index="$2"
  local epic_file="$EPICS_DIR/$epic_id.json"

  [ ! -f "$epic_file" ] && return 1

  local tmp=$(mktemp)
  jq --argjson i "$index" '.proposals[$i].status = "rejected"' \
    "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"

  # Check if all pending are resolved
  local pending=$(jq '[.proposals[] | select(.status == "pending")] | length' "$epic_file")
  if [ "$pending" -eq 0 ]; then
    local tmp2=$(mktemp)
    jq '.status = "active"' "$epic_file" > "$tmp2" && mv "$tmp2" "$epic_file"
  fi
}

approve_all() {
  local epic_id="$1"
  local epic_file="$EPICS_DIR/$epic_id.json"

  [ ! -f "$epic_file" ] && { echo "Epic not found: $epic_id"; return 1; }

  local count=$(jq '[.proposals[] | select(.status == "pending")] | length' "$epic_file")

  for ((i=0; i<$(jq '.proposals | length' "$epic_file"); i++)); do
    local status=$(jq -r ".proposals[$i].status" "$epic_file")
    [ "$status" = "pending" ] && approve_issue "$epic_id" "$i"
  done

  log "${C_GREEN}All $count issues approved and created"
}

advance_existing_issue_epics() {
  for epic_file in "$EPICS_DIR"/*.json; do
    [ -f "$epic_file" ] || continue

    local epic_kind
    epic_kind=$(jq -r '.kind // ""' "$epic_file")
    [ "$epic_kind" = "existing-issues" ] || continue

    local changed=0
    local proposals_len
    proposals_len=$(jq '.proposals | length' "$epic_file")

    for ((i=0; i<proposals_len; i++)); do
      local proposal_status
      proposal_status=$(jq -r ".proposals[$i].status" "$epic_file")
      [ "$proposal_status" = "approved" ] || continue

      local started total_waves
      started=$(jq -r ".proposals[$i].started_waves // 0" "$epic_file")
      total_waves=$(jq -r ".proposals[$i].waves | length" "$epic_file")
      [ "$started" -gt 0 ] || continue

      local current_wave_done=true
      local current_wave_numbers
      current_wave_numbers=$(jq -r ".proposals[$i].waves[$((started - 1))][]?" "$epic_file")

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
        next_wave_numbers=$(jq -r ".proposals[$i].waves[$started][]?" "$epic_file")
        for num in $next_wave_numbers; do
          gh issue edit "$num" --add-label "agent" 2>/dev/null
        done

        local tmp=$(mktemp)
        jq --argjson i "$i" '
          .proposals[$i].started_waves = ((.proposals[$i].started_waves // 0) + 1)
        ' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"
        changed=1

        local title
        title=$(jq -r ".proposals[$i].title" "$epic_file")
        emit "group_wave_started" "Started next wave for existing issue group: $title"
      else
        local all_closed=true
        local issue_nums
        issue_nums=$(jq -r ".proposals[$i].issue_numbers[]?" "$epic_file")
        for num in $issue_nums; do
          local state
          state=$(gh issue view "$num" --json state -q '.state' 2>/dev/null)
          if [ "$state" != "CLOSED" ]; then
            all_closed=false
            break
          fi
        done

        if [ "$all_closed" = true ]; then
          local tmp=$(mktemp)
          jq --argjson i "$i" '.proposals[$i].status = "complete"' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"
          changed=1

          local title
          title=$(jq -r ".proposals[$i].title" "$epic_file")
          emit "group_complete" "Existing issue group complete: $title"
        fi
      fi
    done

    if [ "$changed" -eq 1 ]; then
      local pending approved complete
      pending=$(jq '[.proposals[] | select(.status == "pending")] | length' "$epic_file")
      approved=$(jq '[.proposals[] | select(.status == "approved")] | length' "$epic_file")
      complete=$(jq '[.proposals[] | select(.status == "complete")] | length' "$epic_file")

      local tmp=$(mktemp)
      if [ "$pending" -eq 0 ] && [ "$approved" -eq 0 ] && [ "$complete" -gt 0 ]; then
        jq '.status = "complete"' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"
      elif [ "$approved" -gt 0 ] || [ "$complete" -gt 0 ]; then
        jq '.status = "active"' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"
      else
        rm -f "$tmp"
      fi
    fi
  done
}

check_epic_completion() {
  advance_existing_issue_epics

  for epic_file in "$EPICS_DIR"/*.json; do
    [ -f "$epic_file" ] || continue

    local status=$(jq -r '.status' "$epic_file")
    [ "$status" != "active" ] && continue

    local epic_kind
    epic_kind=$(jq -r '.kind // "planned-issues"' "$epic_file")
    [ "$epic_kind" = "existing-issues" ] && continue

    # Check if all approved issues are closed
    local all_done=true
    local issue_nums=$(jq -r '.proposals[] | select(.status == "approved") | .issue_number // empty' "$epic_file")

    for num in $issue_nums; do
      local state=$(gh issue view "$num" --json state -q '.state' 2>/dev/null)
      if [ "$state" != "CLOSED" ]; then
        all_done=false
        break
      fi
    done

    if [ "$all_done" = true ] && [ -n "$issue_nums" ]; then
      local title=$(jq -r '.title' "$epic_file")
      log "${C_GREEN}Epic complete: $title"
      emit "epic_complete" "Epic complete: $title"

      local tmp=$(mktemp)
      jq '.status = "complete"' "$epic_file" > "$tmp" && mv "$tmp" "$epic_file"
    fi
  done
}
