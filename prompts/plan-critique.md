You are reviewing a technical plan created by another AI. The plan breaks a feature into issues for AI coding agents to implement.

## Feature / Epic

{{DESCRIPTION}}

## Proposed Plan

{{PLAN_JSON}}

{{REPO_CONTEXT}}

## Your Job

Review the plan critically. Consider:
1. Are any issues too large? Should any be split?
2. Are dependencies in the right order?
3. Is anything missing that would be needed for a complete implementation?
4. Are there security, performance, or edge case considerations not covered?
5. Would any issues be difficult for an AI coder to implement without more context?

## Output Format

Respond with ONLY valid JSON, no markdown fencing:

{"feedback":[{"issue_index":0,"comment":"..."}],"additional_issues":[{"title":"...","body":"...","priority":1}],"notes":"Overall assessment"}
