#!/usr/bin/env bash
# agentify planner — epic breakdown via Claude + GPT-5.4 dialectic

EPICS_DIR="$AGENTIFY_DIR/epics"

# Call GPT-5.4 via API (no codex, pure planning — no filesystem side effects)
call_gpt() {
  local prompt="$1"
  curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg model "$CODEX_MODEL" --arg prompt "$prompt" '{
      model: $model,
      messages: [{"role": "user", "content": $prompt}],
      reasoning_effort: "high"
    }')" | jq -r '.choices[0].message.content'
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

  # Extract JSON from response (Claude might wrap it in markdown)
  local claude_plan
  claude_plan=$(echo "$claude_response" | sed -n '/^{/,/^}/p' | head -1)
  if [ -z "$claude_plan" ]; then
    claude_plan=$(echo "$claude_response" | jq -c '.' 2>/dev/null || echo "$claude_response")
  fi

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
  gpt_critique=$(echo "$gpt_response" | sed -n '/^{/,/^}/p' | head -1)
  if [ -z "$gpt_critique" ]; then
    gpt_critique=$(echo "$gpt_response" | jq -c '.' 2>/dev/null || echo '{"feedback":[],"additional_issues":[],"notes":""}')
  fi

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

approve_issue() {
  local epic_id="$1" index="$2"
  local epic_file="$EPICS_DIR/$epic_id.json"

  [ ! -f "$epic_file" ] && { echo "Epic not found: $epic_id"; return 1; }

  local proposal
  proposal=$(jq -c ".proposals[$index]" "$epic_file")
  [ "$proposal" = "null" ] && { echo "Issue index $index not found"; return 1; }

  local status=$(echo "$proposal" | jq -r '.status')
  [ "$status" != "pending" ] && { echo "Issue already $status"; return 1; }

  local title=$(echo "$proposal" | jq -r '.title')
  local body=$(echo "$proposal" | jq -r '.body')

  # Create GitHub issue
  local issue_url
  issue_url=$(gh issue create \
    --title "$title" \
    --body "$body

---
*Part of epic: $(jq -r '.title' "$epic_file")*" \
    --label "agent")

  local issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

  # Update epic file
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

check_epic_completion() {
  for epic_file in "$EPICS_DIR"/*.json; do
    [ -f "$epic_file" ] || continue

    local status=$(jq -r '.status' "$epic_file")
    [ "$status" != "active" ] && continue

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
