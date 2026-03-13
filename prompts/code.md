You are working on a git repo. Your task is to fix issue #{{NUM}}.

**Title:** {{TITLE}}

**Description:**
{{BODY}}

{{REPO_CONTEXT}}

## Instructions

1. Read the codebase to understand the project structure and conventions
2. Make the necessary code changes to resolve the issue
3. Run the issue's declared validation commands if they are provided
4. If no declared validation commands exist, run the most relevant existing tests you can identify
5. If validation fails, fix the issue before finishing

## Rules

- Do NOT run `git commit`, `git push`, or create PRs — the automation handles that
- Do NOT modify CI/CD configs, workflows, or build pipelines unless the issue specifically asks for it
- Do NOT add dependencies unless absolutely necessary
- Match the existing code style — indentation, naming, patterns
- Keep changes minimal and focused on the issue
