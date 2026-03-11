Group the existing GitHub issues below into proposed epics for agent execution.

The output MUST be valid JSON with this exact top-level shape:

{
  "groups": [
    {
      "title": "short epic title",
      "summary": "one paragraph summary of the shared goal",
      "priority": "high|medium|low",
      "issue_numbers": [12, 13, 19],
      "rationale": "why these issues belong together",
      "execution_notes": "how to run these safely; call out sequencing risks",
      "waves": [[12], [13, 19]]
    }
  ],
  "ungrouped_issue_numbers": [21, 24],
  "notes": "brief planning note"
}

Hard rules:
- Only use issue numbers from the provided issue list.
- Only group actionable implementation issues. Do not include tracker or parent issues in `issue_numbers`.
- Never place the same issue in more than one group.
- Prefer 2-6 issues per group. Leave singletons ungrouped unless grouping adds real value.
- Group by shared user-facing outcome or subsystem, not by superficial label similarity.
- Optimize for safe parallel execution by agents.
- Use `waves` to express execution order.
- Be conservative about parallel work. If two issues might touch the same schema, source registry, or normalization layer, put them in different waves.
- Put blocking or prerequisite work in earlier waves.
- If you are not confident that issues can run in parallel, separate them into different waves.
- Do not invent missing requirements or merge unrelated cleanup into a group.

Repo context:
{{REPO_CONTEXT}}

Issues:
{{ISSUES_JSON}}
