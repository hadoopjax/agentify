Review this proposed grouping of existing GitHub issues into epics.

Return valid JSON with this exact top-level shape:

{
  "feedback": [
    {
      "group_index": 0,
      "comment": "what is wrong or risky"
    }
  ],
  "additional_groups": [
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
  "notes": "brief critique summary"
}

Hard rules:
- Only propose additional groups for issues that are currently ungrouped or clearly missing from the proposal.
- Only group actionable implementation issues. Do not include tracker or parent issues in `issue_numbers`.
- Do not duplicate issue numbers already used in an existing group unless your feedback explicitly says the original grouping is wrong.
- Do not suggest overlapping groups.
- Focus on parallel safety, dependency mistakes, oversized groups, and unrelated issues being bundled together.
- If there is no useful additional group, return an empty `additional_groups` array.
- `waves` must reflect safe execution order. When in doubt, use more waves, not fewer.

Repo context:
{{REPO_CONTEXT}}

Issues:
{{ISSUES_JSON}}

Current grouping proposal:
{{GROUPS_JSON}}
