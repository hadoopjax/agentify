You are fixing review feedback on issue #{{NUM}}: {{TITLE}}

The code reviewer found issues with your changes. Here is their feedback:

---
{{REVIEW}}
---

{{REPO_CONTEXT}}

## Instructions

1. Read the review feedback carefully
2. Make the specific changes requested
3. Run tests to verify the fix
4. Do NOT re-implement the entire solution — just address the feedback

## Rules

- Do NOT run `git commit`, `git push`, or create PRs
- Only change what the review asks for — don't expand scope
- If the feedback is unclear, make your best judgment and keep it minimal
