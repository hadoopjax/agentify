The earlier grouping proposal had some unsafe groups. Propose safer replacement groups only for the dropped issues below.

Return valid JSON with this exact top-level shape:

{
  "replacement_groups": [
    {
      "title": "short epic title",
      "summary": "one paragraph summary",
      "priority": "high|medium|low",
      "issue_numbers": [31, 33],
      "rationale": "why these belong together",
      "execution_notes": "how to execute safely",
      "waves": [[31], [33]]
    }
  ],
  "ungrouped_issue_numbers": [40],
  "notes": "brief salvage summary"
}

Hard rules:
- Only use issue numbers from the provided dropped-issue list.
- Only group actionable implementation issues. Do not include tracker or parent issues in `issue_numbers`.
- Prefer smaller, cleaner groups over broad thematic bundles.
- If an issue does not clearly belong in a safe replacement group, leave it ungrouped.
- `waves` must be conservative and dependency-aware.
- Do not suggest overlapping groups.

Repo context:
{{REPO_CONTEXT}}

Dropped groups and reasons:
{{DROPPED_GROUPS_JSON}}

Dropped issues:
{{ISSUES_JSON}}
