#!/usr/bin/env node

import fs from "fs";
import path from "path";
import process from "process";
import { spawnSync } from "child_process";
import OpenAI from "openai";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) continue;
    args[key.slice(2)] = argv[i + 1];
    i += 1;
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const issueNumber = String(args.issue || "").trim();
const explicitPrRef = String(args.pr || "").trim();
const workerKey = String(
  args["worker-key"]
  || issueNumber
  || (explicitPrRef ? `pr-${extractNumberSuffix(explicitPrRef) || explicitPrRef.replaceAll("/", "-")}` : ""),
).trim();
const repoDir = path.resolve(args.repo || process.cwd());
const agentifyDir = path.resolve(args.agentifyDir || path.join(repoDir, ".agentify"));
const defaultNextPhase = String(args["default-next-phase"] || "merge_blocked").trim() || "merge_blocked";
const workerFile = path.join(agentifyDir, "workers", `${workerKey}.json`);
const workerLog = path.join(agentifyDir, "logs", `${workerKey}.log`);
const managePromptFile = path.resolve(args.prompt || path.join(path.dirname(new URL(import.meta.url).pathname), "..", "prompts", "manage.md"));

if (!workerKey || (!issueNumber && !explicitPrRef)) {
  console.error("Missing --issue or --pr");
  process.exit(1);
}

const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const MODEL = process.env.MANAGER_MODEL || "gpt-5.4";
const EFFORT = process.env.MANAGER_EFFORT || "high";
const CODEX_MODEL = process.env.CODEX_MODEL || "gpt-5.4";
const CODEX_EFFORT = process.env.CODEX_EFFORT || "high";
const CODEX_CONFLICT_TIMEOUT_MS = Number(process.env.CODEX_CONFLICT_TIMEOUT_MS || 20 * 60 * 1000);
const MANAGER_RESPONSE_TIMEOUT_MS = Number(process.env.MANAGER_RESPONSE_TIMEOUT_MS || 3 * 60 * 1000);
const TEMP_ROOT = process.env.TMPDIR || "/tmp";

function extractNumberSuffix(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  const match = text.match(/(\d+)(?!.*\d)/);
  return match ? match[1] : "";
}

function gh(argsList, options = {}) {
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: process.env.GIT_CONFIG_GLOBAL || "/dev/null",
  };
  const result = spawnSync("gh", argsList, {
    cwd: repoDir,
    env,
    encoding: "utf8",
    ...options,
  });
  if (result.error) throw result.error;
  return result;
}

async function createManagerResponse(request) {
  return client.responses.create(
    request,
    { timeout: MANAGER_RESPONSE_TIMEOUT_MS },
  );
}

function git(argsList, options = {}) {
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: process.env.GIT_CONFIG_GLOBAL || "/dev/null",
  };
  const result = spawnSync("git", argsList, {
    cwd: repoDir,
    env,
    encoding: "utf8",
    ...options,
  });
  if (result.error) throw result.error;
  return result;
}

function readJson(filePath, fallback = {}) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function readText(filePath, fallback = "") {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return fallback;
  }
}

function repoContext() {
  return readText(path.join(repoDir, ".agentify", "agents.md"), "").trim();
}

function resolveWorker() {
  return readJson(workerFile, {});
}

function activePrRef(worker = resolveWorker()) {
  return explicitPrRef || worker.pr_url || worker.pr_number || "";
}

function tailLines(filePath, limit = 120) {
  const text = readText(filePath, "");
  if (!text) return "";
  return text.trimEnd().split("\n").slice(-limit).join("\n");
}

function defaultBaseRef() {
  const originHead = git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]);
  if (originHead.status === 0 && originHead.stdout.trim()) {
    return originHead.stdout.trim();
  }
  const repoView = gh(["repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"]);
  if (repoView.status === 0 && repoView.stdout.trim()) {
    return `origin/${repoView.stdout.trim()}`;
  }
  const current = git(["branch", "--show-current"]);
  return current.stdout.trim() || "origin/master";
}

function worktreeUsable(worktreePath) {
  if (!worktreePath || !fs.existsSync(worktreePath)) return false;
  const ok = git(["-C", worktreePath, "rev-parse", "--verify", "HEAD"]);
  return ok.status === 0;
}

function managedBranchName(branch) {
  return `agentify/manage/${branch.replaceAll("/", "__")}`;
}

function ensureWorktreeFromRef(candidate, branch, startRef, { localTarget = false } = {}) {
  const managedBranch = managedBranchName(branch);
  const directAdd = localTarget
    ? git(["worktree", "add", "-q", candidate, branch])
    : git(["worktree", "add", "-q", "-b", branch, candidate, startRef]);
  if (directAdd.status === 0) return true;

  const managedAdd = git(["worktree", "add", "-q", "-B", managedBranch, candidate, startRef]);
  return managedAdd.status === 0;
}

function ensureWorktree(branch, preferredPath) {
  const fallbackPath = preferredPath || path.join(agentifyDir, "worktrees", branch);
  const repairPath = path.join(agentifyDir, "worktrees-repair", branch.replaceAll("/", "__"));

  for (const candidate of [preferredPath, fallbackPath, repairPath]) {
    if (worktreeUsable(candidate)) return candidate;
  }

  git(["fetch", "origin", "-q"]);
  git(["worktree", "prune", "-v"]);

  const candidates = [];
  if (!fs.existsSync(fallbackPath)) candidates.push(fallbackPath);
  if (!fs.existsSync(repairPath)) candidates.push(repairPath);

  for (const candidate of candidates) {
    fs.mkdirSync(path.dirname(candidate), { recursive: true });

    if (ensureWorktreeFromRef(candidate, branch, branch, { localTarget: true })) return candidate;

    const remoteRef = `origin/${branch}`;
    if (ensureWorktreeFromRef(candidate, branch, remoteRef)) return candidate;

    const baseRef = defaultBaseRef();
    if (ensureWorktreeFromRef(candidate, branch, baseRef)) return candidate;
  }

  throw new Error(`Unable to ensure worktree for ${branch}`);
}

function gitPathExists(worktreePath, relPath) {
  const res = git(["-C", worktreePath, "rev-parse", "--git-path", relPath]);
  return res.status === 0 && fs.existsSync(res.stdout.trim());
}

function rebaseInProgress(worktreePath) {
  return gitPathExists(worktreePath, "rebase-merge") || gitPathExists(worktreePath, "rebase-apply");
}

function conflictedFiles(worktreePath) {
  const res = git(["-C", worktreePath, "diff", "--name-only", "--diff-filter=U"]);
  if (res.status !== 0) return [];
  return res.stdout.split("\n").map(v => v.trim()).filter(Boolean);
}

function pushBranch(worktreePath, targetBranch) {
  const push = git([
    "-C",
    worktreePath,
    "push",
    "--force-with-lease=refs/heads/" + targetBranch,
    "origin",
    "HEAD:refs/heads/" + targetBranch,
    "-q",
  ]);
  return {
    ok: push.status === 0,
    stderr: push.stderr || push.stdout || "",
  };
}

function removePath(targetPath) {
  if (!targetPath) return;
  try {
    fs.rmSync(targetPath, { recursive: true, force: true });
  } catch {
    // Best effort cleanup for temp artifacts.
  }
}

function conflictSetsEqual(left, right) {
  const a = [...new Set(left || [])].sort();
  const b = [...new Set(right || [])].sort();
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

function codexFailureDetails(result) {
  return [
    result.stderr?.trim(),
    result.stdout?.trim(),
    result.lastMessage?.trim(),
    result.error?.trim(),
  ].filter(Boolean).join("\n\n").trim();
}

function buildConflictResolutionPrompt({ issue, pr, branch, baseRef, worktreePath, conflicts, attempt }) {
  const context = repoContext();
  const subjectLine = issue
    ? `You are resolving a git rebase conflict for issue #${issue.number}: ${issue.title}.`
    : pr
      ? `You are resolving a git rebase conflict for pull request #${pr.number}: ${pr.title}.`
      : `You are resolving a git rebase conflict for branch \`${branch}\`.`;
  const lines = [
    subjectLine,
    "",
    "Task:",
    `- Keep the existing feature intent on branch \`${branch}\``,
    `- Reconcile it with the current base branch \`${baseRef}\``,
    "- Resolve only the active merge conflicts from the in-progress rebase",
    "- Do not broaden scope or make unrelated edits",
    "- Preserve existing work; do not discard the branch changes",
    "",
    `Rebase attempt: ${attempt}`,
    pr?.url ? `PR: ${pr.url}` : "",
    issue?.body ? `Issue description:\n${issue.body}` : "",
    !issue?.body && pr?.body ? `PR description:\n${pr.body}` : "",
    context ? `Repo-specific context:\n${context}` : "",
    "Conflicted files:",
    ...conflicts.map(file => `- ${file}`),
    "",
    "Instructions:",
    "1. Inspect the conflicting files and resolve the merge markers carefully.",
    "2. Keep changes minimal and targeted to the conflict.",
    "3. Run focused tests or validation relevant to the conflicted area if available.",
    "4. Stage the resolved files with git add.",
    "5. Do not run git commit, git push, or open PRs.",
  ].filter(Boolean);
  return lines.join("\n");
}

function runCodexConflictResolution(input) {
  const prompt = buildConflictResolutionPrompt(input);
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: process.env.GIT_CONFIG_GLOBAL || "/dev/null",
  };
  const tempDir = fs.mkdtempSync(path.join(TEMP_ROOT, "agentify-manage-"));
  const lastMessagePath = path.join(tempDir, "codex-last-message.txt");

  try {
    const result = spawnSync(
      "codex",
      [
        // This Codex CLI build currently falls back to read-only in exec mode
        // unless the nested run uses bypass mode.
        "--dangerously-bypass-approvals-and-sandbox",
        "exec",
        "--model",
        CODEX_MODEL,
        "-c",
        `model_reasoning_effort="${CODEX_EFFORT}"`,
        "--ephemeral",
        "--color",
        "never",
        "--output-last-message",
        lastMessagePath,
        "-",
      ],
      {
        cwd: input.worktreePath,
        env,
        encoding: "utf8",
        timeout: CODEX_CONFLICT_TIMEOUT_MS,
        input: prompt,
      },
    );

    return {
      ok: result.status === 0 && !result.error,
      status: result.status,
      signal: result.signal || "",
      stdout: result.stdout || "",
      stderr: result.stderr || "",
      lastMessage: readText(lastMessagePath, ""),
      error: result.error ? String(result.error) : "",
    };
  } finally {
    removePath(tempDir);
  }
}

function recentIssueEvents() {
  const eventsPath = path.join(agentifyDir, "events.jsonl");
  const identifiers = [
    issueNumber ? `#${issueNumber}` : "",
    workerKey ? `#${workerKey}` : "",
    explicitPrRef ? `PR #${extractNumberSuffix(explicitPrRef)}` : "",
  ].filter(Boolean);
  const lines = readText(eventsPath, "")
    .split("\n")
    .filter(Boolean)
    .map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .filter(ev => typeof ev.msg === "string" && identifiers.some(identifier => ev.msg.includes(identifier)));
  return lines.slice(-12);
}

function getIssueSnapshot() {
  if (!issueNumber) return null;
  const result = gh(["issue", "view", issueNumber, "--json", "number,title,body,state,labels,url"]);
  if (result.status !== 0) {
    throw new Error(result.stderr || `Unable to inspect issue #${issueNumber}`);
  }
  return JSON.parse(result.stdout);
}

function getPrSnapshot(prRef, branch) {
  let pr = null;
  if (prRef) {
    const view = gh(["pr", "view", prRef, "--json", "number,title,body,url,state,mergeStateStatus,headRefName,baseRefName,isDraft,reviewDecision,comments,statusCheckRollup"]);
    if (view.status === 0 && view.stdout.trim()) {
      pr = JSON.parse(view.stdout);
    }
  }
  if (!pr && branch) {
    const list = gh(["pr", "list", "--head", branch, "--state", "open", "--limit", "1", "--json", "number,title,url,state,mergeStateStatus,headRefName,baseRefName,isDraft,reviewDecision"]);
    if (list.status === 0 && list.stdout.trim()) {
      const rows = JSON.parse(list.stdout);
      pr = rows[0] || null;
    }
  }
  return pr;
}

function branchDivergence(branch, worktreePath) {
  if (!branch) return null;
  const baseRef = defaultBaseRef();
  const ensuredPath = ensureWorktree(branch, worktreePath);
  const result = git(["-C", ensuredPath, "rev-list", "--left-right", "--count", `${baseRef}...HEAD`]);
  if (result.status !== 0) return null;
  const [behind, ahead] = result.stdout.trim().split(/\s+/).map(v => Number(v || 0));
  return { base_ref: baseRef, ahead, behind, worktree: ensuredPath };
}

function collectSnapshot() {
  const worker = resolveWorker();
  const issue = getIssueSnapshot();
  const branchHint = worker.branch || (issue?.number ? `agent/issue-${issue.number}` : "");
  const worktreePath = worker.worktree ? path.resolve(repoDir, worker.worktree) : null;
  const pr = getPrSnapshot(activePrRef(worker), branchHint);
  const branch = worker.branch || pr?.headRefName || branchHint;
  return {
    issue,
    worker,
    pr,
    branch_state: branchDivergence(branch, worktreePath),
    recent_events: recentIssueEvents(),
    worker_log_tail: tailLines(workerLog, 120),
  };
}

function ghJson(argsList, fallback = null) {
  const result = gh(argsList);
  if (result.status !== 0 || !result.stdout.trim()) return fallback;
  try {
    return JSON.parse(result.stdout);
  } catch {
    return fallback;
  }
}

function resolveIssueRef(issueRef) {
  const resolved = String(issueRef || issueNumber).trim();
  if (!resolved) throw new Error("Missing issue reference");
  return resolved;
}

function resolveBranchRef(branch) {
  const worker = resolveWorker();
  if (branch) return String(branch).trim();
  if (worker.branch) return String(worker.branch).trim();
  const pr = getPrSnapshot(activePrRef(worker), "");
  if (pr?.headRefName) return String(pr.headRefName).trim();
  if (issueNumber) return `agent/issue-${issueNumber}`;
  throw new Error("Missing branch reference");
}

function resolvePrRef(prRef) {
  const resolved = String(prRef || activePrRef()).trim();
  if (!resolved) throw new Error("Missing PR reference");
  return resolved;
}

function resolveWorktreePath(branch) {
  const worker = resolveWorker();
  const preferredPath = worker.worktree ? path.resolve(repoDir, worker.worktree) : null;
  return ensureWorktree(resolveBranchRef(branch), preferredPath);
}

function getIssueDetails(issueRef) {
  const ref = resolveIssueRef(issueRef);
  const issue = ghJson(["issue", "view", ref, "--json", "number,title,body,state,labels,assignees,author,url,comments,closed,closedAt,createdAt,updatedAt,milestone,projectItems"], {});
  return issue || {};
}

function listIssueComments(issueRef) {
  const ref = resolveIssueRef(issueRef);
  const issue = ghJson(["issue", "view", ref, "--json", "comments"], { comments: [] });
  return { issue: ref, comments: issue.comments || [] };
}

function commentOnIssue(issueRef, body) {
  const ref = resolveIssueRef(issueRef);
  const result = gh(["issue", "comment", ref, "--body", body]);
  return { ok: result.status === 0, issue: ref, stderr: result.stderr || result.stdout || "" };
}

function editIssue(issueRef, title, body) {
  const ref = resolveIssueRef(issueRef);
  const args = ["issue", "edit", ref];
  if (title) args.push("--title", title);
  if (body) args.push("--body", body);
  if (args.length === 3) return { ok: false, issue: ref, error: "No title/body changes requested" };
  const result = gh(args);
  return { ok: result.status === 0, issue: ref, stderr: result.stderr || result.stdout || "" };
}

function addIssueLabels(issueRef, labels) {
  const ref = resolveIssueRef(issueRef);
  const names = (labels || []).filter(Boolean);
  if (names.length === 0) return { ok: false, issue: ref, error: "No labels provided" };
  const result = gh(["issue", "edit", ref, "--add-label", names.join(",")]);
  return { ok: result.status === 0, issue: ref, labels: names, stderr: result.stderr || result.stdout || "" };
}

function removeIssueLabels(issueRef, labels) {
  const ref = resolveIssueRef(issueRef);
  const names = (labels || []).filter(Boolean);
  if (names.length === 0) return { ok: false, issue: ref, error: "No labels provided" };
  const result = gh(["issue", "edit", ref, "--remove-label", names.join(",")]);
  return { ok: result.status === 0, issue: ref, labels: names, stderr: result.stderr || result.stdout || "" };
}

function closeIssue(issueRef, reason = "") {
  const ref = resolveIssueRef(issueRef);
  const args = ["issue", "close", ref];
  if (reason) args.push("--comment", reason);
  const result = gh(args);
  return { ok: result.status === 0, issue: ref, stderr: result.stderr || result.stdout || "" };
}

function reopenIssue(issueRef) {
  const ref = resolveIssueRef(issueRef);
  const result = gh(["issue", "reopen", ref]);
  return { ok: result.status === 0, issue: ref, stderr: result.stderr || result.stdout || "" };
}

function getPullRequestDetails(prRef) {
  const ref = resolvePrRef(prRef);
  return ghJson(["pr", "view", ref, "--json", "number,title,body,url,state,mergeStateStatus,headRefName,headRefOid,baseRefName,isDraft,reviewDecision,comments,reviews,commits,files,labels,assignees,author,statusCheckRollup,createdAt,updatedAt"], {}) || {};
}

function listPullRequestComments(prRef) {
  const ref = resolvePrRef(prRef);
  const pr = ghJson(["pr", "view", ref, "--json", "comments"], { comments: [] });
  return { pr: ref, comments: pr.comments || [] };
}

function listPullRequestReviews(prRef) {
  const ref = resolvePrRef(prRef);
  const pr = ghJson(["pr", "view", ref, "--json", "reviews"], { reviews: [] });
  return { pr: ref, reviews: pr.reviews || [] };
}

function listPullRequestFiles(prRef) {
  const ref = resolvePrRef(prRef);
  const result = gh(["pr", "diff", ref, "--name-only"]);
  const files = result.status === 0
    ? result.stdout.split("\n").map(v => v.trim()).filter(Boolean)
    : [];
  return { pr: ref, files, stderr: result.stderr || result.stdout || "" };
}

function getPullRequestChecks(prRef) {
  const ref = resolvePrRef(prRef);
  const pr = ghJson(["pr", "view", ref, "--json", "statusCheckRollup,mergeStateStatus"], { statusCheckRollup: [] });
  return {
    pr: ref,
    merge_state_status: pr.mergeStateStatus || "",
    checks: pr.statusCheckRollup || [],
  };
}

function updatePullRequest(prRef, title, body, base) {
  const ref = resolvePrRef(prRef);
  const args = ["pr", "edit", ref];
  if (title) args.push("--title", title);
  if (body) args.push("--body", body);
  if (base) args.push("--base", base);
  if (args.length === 3) return { ok: false, pr: ref, error: "No PR changes requested" };
  const result = gh(args);
  return { ok: result.status === 0, pr: ref, stderr: result.stderr || result.stdout || "" };
}

function requestPullRequestReviewers(prRef, reviewers, teamReviewers) {
  const ref = resolvePrRef(prRef);
  const args = ["pr", "edit", ref];
  const users = (reviewers || []).filter(Boolean);
  const teams = (teamReviewers || []).filter(Boolean);
  if (users.length > 0) args.push("--add-reviewer", users.join(","));
  if (teams.length > 0) args.push("--add-reviewer", teams.join(","));
  if (args.length === 3) return { ok: false, pr: ref, error: "No reviewers provided" };
  const result = gh(args);
  return { ok: result.status === 0, pr: ref, reviewers: users, team_reviewers: teams, stderr: result.stderr || result.stdout || "" };
}

function closePullRequest(prRef, comment = "") {
  const ref = resolvePrRef(prRef);
  const args = ["pr", "close", ref];
  if (comment) args.push("--comment", comment);
  const result = gh(args);
  return { ok: result.status === 0, pr: ref, stderr: result.stderr || result.stdout || "" };
}

function reopenPullRequest(prRef) {
  const ref = resolvePrRef(prRef);
  const result = gh(["pr", "reopen", ref]);
  return { ok: result.status === 0, pr: ref, stderr: result.stderr || result.stdout || "" };
}

function listBranchPullRequests(branch) {
  const branchRef = resolveBranchRef(branch);
  const prs = ghJson(["pr", "list", "--head", branchRef, "--state", "all", "--limit", "20", "--json", "number,title,url,state,mergeStateStatus,isDraft,headRefName,baseRefName,updatedAt"], []);
  return { branch: branchRef, pull_requests: prs || [] };
}

function getBranchStatus(branch) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  const baseRef = defaultBaseRef();
  const aheadBehind = git(["-C", worktreePath, "rev-list", "--left-right", "--count", `${baseRef}...HEAD`]);
  const [behind, ahead] = aheadBehind.status === 0
    ? aheadBehind.stdout.trim().split(/\s+/).map(v => Number(v || 0))
    : [0, 0];
  const head = git(["-C", worktreePath, "rev-parse", "HEAD"]);
  return {
    branch: branchRef,
    base_ref: baseRef,
    ahead,
    behind,
    head_sha: head.status === 0 ? head.stdout.trim() : "",
    worktree: worktreePath,
    pull_requests: listBranchPullRequests(branchRef).pull_requests,
  };
}

function getWorktreeStatus(branch) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  const status = git(["-C", worktreePath, "status", "--short", "--branch"]);
  const untracked = git(["-C", worktreePath, "ls-files", "--others", "--exclude-standard"]);
  return {
    branch: branchRef,
    worktree: worktreePath,
    status: status.stdout || "",
    rebase_in_progress: rebaseInProgress(worktreePath),
    conflicted_files: conflictedFiles(worktreePath),
    untracked_files: untracked.status === 0 ? untracked.stdout.split("\n").map(v => v.trim()).filter(Boolean) : [],
  };
}

function readWorktreeFile(branch, filePath, maxLines = 200) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  const absolute = path.resolve(worktreePath, filePath);
  if (!absolute.startsWith(`${worktreePath}${path.sep}`) && absolute !== worktreePath) {
    return { ok: false, branch: branchRef, error: "Path escapes worktree" };
  }
  const text = readText(absolute, "");
  return {
    ok: Boolean(text),
    branch: branchRef,
    worktree: worktreePath,
    file_path: filePath,
    content: text ? text.split("\n").slice(0, Math.max(1, maxLines)).join("\n") : "",
  };
}

function listConflictedWorktreeFiles(branch) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  return {
    branch: branchRef,
    worktree: worktreePath,
    conflicted_files: conflictedFiles(worktreePath),
    rebase_in_progress: rebaseInProgress(worktreePath),
  };
}

function abortRebase(branch) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  const result = git(["-C", worktreePath, "rebase", "--abort"]);
  return {
    ok: result.status === 0,
    branch: branchRef,
    worktree: worktreePath,
    stderr: result.stderr || result.stdout || "",
  };
}

function continueRebase(branch, addAll = false) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  if (addAll) git(["-C", worktreePath, "add", "-A"]);
  const result = git(["-c", "core.editor=true", "-C", worktreePath, "rebase", "--continue"]);
  return {
    ok: result.status === 0,
    branch: branchRef,
    worktree: worktreePath,
    rebase_in_progress: rebaseInProgress(worktreePath),
    conflicted_files: conflictedFiles(worktreePath),
    stderr: result.stderr || result.stdout || "",
  };
}

function pushPreservedBranch(branch) {
  const branchRef = resolveBranchRef(branch);
  const worktreePath = resolveWorktreePath(branchRef);
  const push = pushBranch(worktreePath, branchRef);
  return {
    ...push,
    branch: branchRef,
    worktree: worktreePath,
  };
}

function rebaseBranchOntoBase(branch) {
  const worker = readJson(workerFile, {});
  const worktreePath = ensureWorktree(branch, worker.worktree ? path.resolve(repoDir, worker.worktree) : null);
  const baseRef = defaultBaseRef();
  const fetch = git(["fetch", "origin", "-q"]);
  if (fetch.status !== 0) {
    return { ok: false, action: "fetch", stderr: fetch.stderr };
  }
  const rebase = git(["-C", worktreePath, "rebase", baseRef]);
  if (rebase.status !== 0) {
    const conflicts = conflictedFiles(worktreePath);
    if (rebaseInProgress(worktreePath) || conflicts.length > 0) {
      return {
        ok: false,
        action: "rebase_conflict",
        stderr: rebase.stderr || rebase.stdout,
        base_ref: baseRef,
        worktree: worktreePath,
        conflicted_files: conflicts,
      };
    }
    git(["-C", worktreePath, "rebase", "--abort"]);
    return { ok: false, action: "rebase", stderr: rebase.stderr || rebase.stdout, base_ref: baseRef };
  }
  const push = pushBranch(worktreePath, branch);
  if (!push.ok) {
    return { ok: false, action: "push", stderr: push.stderr, base_ref: baseRef, worktree: worktreePath };
  }
  return { ok: true, branch, base_ref: baseRef, worktree: worktreePath };
}

function resolveRebaseConflicts(branch) {
  const worker = resolveWorker();
  const issue = getIssueSnapshot();
  const worktreePath = ensureWorktree(branch, worker.worktree ? path.resolve(repoDir, worker.worktree) : null);
  const baseRef = defaultBaseRef();
  const pr = getPrSnapshot(activePrRef(worker), branch);
  let attempt = 0;

  if (!rebaseInProgress(worktreePath)) {
    const start = git(["-C", worktreePath, "rebase", baseRef]);
    if (start.status !== 0 && !rebaseInProgress(worktreePath) && conflictedFiles(worktreePath).length === 0) {
      return {
        ok: false,
        action: "rebase",
        stderr: start.stderr || start.stdout,
        base_ref: baseRef,
        worktree: worktreePath,
      };
    }
  }

  while (rebaseInProgress(worktreePath) && attempt < 3) {
    attempt += 1;
    const conflicts = conflictedFiles(worktreePath);
    if (conflicts.length === 0) {
      const cont = git(["-c", "core.editor=true", "-C", worktreePath, "rebase", "--continue"]);
      if (cont.status === 0) continue;
      if (!rebaseInProgress(worktreePath)) {
        return {
          ok: false,
          action: "rebase_continue",
          stderr: cont.stderr || cont.stdout,
          base_ref: baseRef,
          worktree: worktreePath,
        };
      }
      continue;
    }

    const codexResult = runCodexConflictResolution({
      issue,
      pr,
      branch,
      baseRef,
      worktreePath,
      conflicts,
      attempt,
    });

    const remainingConflicts = conflictedFiles(worktreePath);
    const rebaseStillActive = rebaseInProgress(worktreePath);

    if (remainingConflicts.length === 0) {
      if (!rebaseStillActive) break;
      git(["-C", worktreePath, "add", "-A"]);
      const cont = git(["-c", "core.editor=true", "-C", worktreePath, "rebase", "--continue"]);
      if (cont.status === 0) continue;
      if (!rebaseInProgress(worktreePath)) break;
      continue;
    }

    if (!codexResult.ok && !conflictSetsEqual(conflicts, remainingConflicts)) {
      continue;
    }

    if (remainingConflicts.length > 0) {
      git(["-C", worktreePath, "rebase", "--abort"]);
      return {
        ok: false,
        action: codexResult.ok ? "unresolved_conflicts" : "codex_conflict_resolution",
        stderr: codexResult.ok
          ? `Conflicts remain after Codex resolution: ${remainingConflicts.join(", ")}`
          : codexFailureDetails(codexResult) || `Conflicts remain after Codex resolution: ${remainingConflicts.join(", ")}`,
        base_ref: baseRef,
        worktree: worktreePath,
        conflicted_files: remainingConflicts,
      };
    }
  }

  if (rebaseInProgress(worktreePath)) {
    const remainingConflicts = conflictedFiles(worktreePath);
    git(["-C", worktreePath, "rebase", "--abort"]);
    return {
      ok: false,
      action: "rebase_conflict",
      stderr: remainingConflicts.length > 0
        ? `Rebase still conflicted after ${attempt} attempt(s): ${remainingConflicts.join(", ")}`
        : `Rebase still in progress after ${attempt} attempt(s)`,
      base_ref: baseRef,
      worktree: worktreePath,
      conflicted_files: remainingConflicts,
    };
  }

  const push = pushBranch(worktreePath, branch);
  if (!push.ok) {
    return { ok: false, action: "push", stderr: push.stderr, base_ref: baseRef, worktree: worktreePath };
  }

  return {
    ok: true,
    branch,
    base_ref: baseRef,
    worktree: worktreePath,
    attempts: attempt,
  };
}

function mergePullRequest(prUrl) {
  const merge = gh(["pr", "merge", prUrl, "--squash", "--delete-branch"]);
  if (merge.status === 0) {
    return { ok: true, mode: "merge" };
  }
  const auto = gh(["pr", "merge", prUrl, "--squash", "--auto", "--delete-branch"]);
  if (auto.status === 0) {
    return { ok: true, mode: "auto" };
  }
  return {
    ok: false,
    merge_stderr: merge.stderr || merge.stdout,
    auto_stderr: auto.stderr || auto.stdout,
  };
}

function commentOnPullRequest(prUrl, body) {
  const result = gh(["pr", "comment", prUrl, "--body", body]);
  return {
    ok: result.status === 0,
    stderr: result.stderr || "",
  };
}

const prompt = readText(managePromptFile, "");

function tool(name, description, properties = {}, required = []) {
  return {
    type: "function",
    name,
    description,
    parameters: {
      type: "object",
      properties,
      required,
      additionalProperties: false,
    },
  };
}

const tools = [
  tool("refresh_snapshot", "Refresh the current issue, PR, branch, and worker snapshot."),
  tool("get_issue_details", "Load the latest GitHub issue details, labels, assignees, and comments for the managed issue or another issue.", {
    issue_ref: { type: "string" },
  }),
  tool("list_issue_comments", "List issue comments for the managed issue or another issue.", {
    issue_ref: { type: "string" },
  }),
  tool("comment_on_issue", "Add a comment to an issue.", {
    issue_ref: { type: "string" },
    body: { type: "string" },
  }, ["body"]),
  tool("edit_issue", "Update an issue title and/or body.", {
    issue_ref: { type: "string" },
    title: { type: "string" },
    body: { type: "string" },
  }),
  tool("add_issue_labels", "Add one or more labels to an issue.", {
    issue_ref: { type: "string" },
    labels: { type: "array", items: { type: "string" } },
  }, ["labels"]),
  tool("remove_issue_labels", "Remove one or more labels from an issue.", {
    issue_ref: { type: "string" },
    labels: { type: "array", items: { type: "string" } },
  }, ["labels"]),
  tool("close_issue", "Close an issue, optionally leaving a closing comment.", {
    issue_ref: { type: "string" },
    reason: { type: "string" },
  }),
  tool("reopen_issue", "Reopen a closed issue.", {
    issue_ref: { type: "string" },
  }),
  tool("get_pull_request_details", "Load the latest PR details including body, reviews, labels, files, checks, and mergeability.", {
    pr_ref: { type: "string" },
  }),
  tool("list_pull_request_comments", "List pull request conversation comments.", {
    pr_ref: { type: "string" },
  }),
  tool("list_pull_request_reviews", "List pull request review events.", {
    pr_ref: { type: "string" },
  }),
  tool("list_pull_request_files", "List the files changed in a pull request.", {
    pr_ref: { type: "string" },
  }),
  tool("get_pull_request_checks", "Inspect PR status checks and merge state.", {
    pr_ref: { type: "string" },
  }),
  tool("update_pull_request", "Update pull request title, body, and/or base branch.", {
    pr_ref: { type: "string" },
    title: { type: "string" },
    body: { type: "string" },
    base: { type: "string" },
  }),
  tool("request_pull_request_reviewers", "Request PR reviewers or team reviewers.", {
    pr_ref: { type: "string" },
    reviewers: { type: "array", items: { type: "string" } },
    team_reviewers: { type: "array", items: { type: "string" } },
  }),
  tool("comment_on_pull_request", "Leave a concise human-facing comment on the existing PR.", {
    pr_url: { type: "string" },
    body: { type: "string" },
  }, ["pr_url", "body"]),
  tool("close_pull_request", "Close a pull request, optionally leaving a comment.", {
    pr_ref: { type: "string" },
    comment: { type: "string" },
  }),
  tool("reopen_pull_request", "Reopen a closed pull request.", {
    pr_ref: { type: "string" },
  }),
  tool("list_branch_pull_requests", "List pull requests associated with a branch.", {
    branch: { type: "string" },
  }),
  tool("get_branch_status", "Inspect branch ahead/behind counts, head SHA, worktree path, and associated PRs.", {
    branch: { type: "string" },
  }),
  tool("get_worktree_status", "Inspect the local worktree status, untracked files, and active conflicts for a branch.", {
    branch: { type: "string" },
  }),
  tool("read_worktree_file", "Read a file from the managed worktree for inspection.", {
    branch: { type: "string" },
    file_path: { type: "string" },
    max_lines: { type: "integer" },
  }, ["file_path"]),
  tool("list_conflicted_worktree_files", "List currently conflicted files in the worktree and whether a rebase is active.", {
    branch: { type: "string" },
  }),
  tool("abort_rebase", "Abort an in-progress rebase in the managed worktree.", {
    branch: { type: "string" },
  }),
  tool("continue_rebase", "Continue an in-progress rebase in the managed worktree, optionally staging all changes first.", {
    branch: { type: "string" },
    add_all: { type: "boolean" },
  }),
  tool("push_preserved_branch", "Force-with-lease push the preserved branch after local reconciliation.", {
    branch: { type: "string" },
  }),
  tool("rebase_branch_onto_base", "Fetch the current base branch, rebase the issue branch onto it once, and force-with-lease push the result.", {
    branch: { type: "string" },
  }, ["branch"]),
  tool("resolve_rebase_conflicts", "Use Codex inside the issue worktree to resolve active rebase conflicts, continue the rebase, and push the preserved branch if successful.", {
    branch: { type: "string" },
  }, ["branch"]),
  tool("merge_pull_request", "Merge the existing pull request using squash merge, or enable auto-merge if that is the only safe path.", {
    pr_url: { type: "string" },
  }, ["pr_url"]),
  tool("finish_management", "Finish the management run with the final outcome.", {
    status: { type: "string", enum: ["resolved", "blocked", "retry_later", "no_action"] },
    reason: { type: "string" },
    next_phase: { type: "string" },
  }, ["status", "reason", "next_phase"]),
];

async function main() {
  let snapshot = collectSnapshot();
  let finalResult = null;
  let response = await createManagerResponse({
    model: MODEL,
    reasoning: { effort: EFFORT },
    background: false,
    store: true,
    tools,
    input: [
      { role: "system", content: prompt },
      {
        role: "user",
        content: JSON.stringify({
          objective: "Resolve this orchestration anomaly safely.",
          snapshot,
        }),
      },
    ],
  });

  while (true) {
    const toolCalls = (response.output || []).filter(item => item.type === "function_call");
    if (toolCalls.length === 0) break;

    const outputs = [];
    for (const call of toolCalls) {
      const argsObj = call.arguments ? JSON.parse(call.arguments) : {};
      let result;
      try {
        switch (call.name) {
          case "refresh_snapshot":
            snapshot = collectSnapshot();
            result = snapshot;
            break;
          case "get_issue_details":
            result = getIssueDetails(argsObj.issue_ref);
            break;
          case "list_issue_comments":
            result = listIssueComments(argsObj.issue_ref);
            break;
          case "comment_on_issue":
            result = commentOnIssue(argsObj.issue_ref, argsObj.body);
            break;
          case "edit_issue":
            result = editIssue(argsObj.issue_ref, argsObj.title, argsObj.body);
            break;
          case "add_issue_labels":
            result = addIssueLabels(argsObj.issue_ref, argsObj.labels);
            break;
          case "remove_issue_labels":
            result = removeIssueLabels(argsObj.issue_ref, argsObj.labels);
            break;
          case "close_issue":
            result = closeIssue(argsObj.issue_ref, argsObj.reason);
            break;
          case "reopen_issue":
            result = reopenIssue(argsObj.issue_ref);
            break;
          case "get_pull_request_details":
            result = getPullRequestDetails(argsObj.pr_ref);
            break;
          case "list_pull_request_comments":
            result = listPullRequestComments(argsObj.pr_ref);
            break;
          case "list_pull_request_reviews":
            result = listPullRequestReviews(argsObj.pr_ref);
            break;
          case "list_pull_request_files":
            result = listPullRequestFiles(argsObj.pr_ref);
            break;
          case "get_pull_request_checks":
            result = getPullRequestChecks(argsObj.pr_ref);
            break;
          case "update_pull_request":
            result = updatePullRequest(argsObj.pr_ref, argsObj.title, argsObj.body, argsObj.base);
            break;
          case "request_pull_request_reviewers":
            result = requestPullRequestReviewers(argsObj.pr_ref, argsObj.reviewers, argsObj.team_reviewers);
            break;
          case "rebase_branch_onto_base":
            result = rebaseBranchOntoBase(argsObj.branch);
            break;
          case "resolve_rebase_conflicts":
            result = resolveRebaseConflicts(argsObj.branch);
            break;
          case "merge_pull_request":
            result = mergePullRequest(argsObj.pr_url);
            break;
          case "comment_on_pull_request":
            result = commentOnPullRequest(argsObj.pr_url, argsObj.body);
            break;
          case "close_pull_request":
            result = closePullRequest(argsObj.pr_ref, argsObj.comment);
            break;
          case "reopen_pull_request":
            result = reopenPullRequest(argsObj.pr_ref);
            break;
          case "list_branch_pull_requests":
            result = listBranchPullRequests(argsObj.branch);
            break;
          case "get_branch_status":
            result = getBranchStatus(argsObj.branch);
            break;
          case "get_worktree_status":
            result = getWorktreeStatus(argsObj.branch);
            break;
          case "read_worktree_file":
            result = readWorktreeFile(argsObj.branch, argsObj.file_path, argsObj.max_lines);
            break;
          case "list_conflicted_worktree_files":
            result = listConflictedWorktreeFiles(argsObj.branch);
            break;
          case "abort_rebase":
            result = abortRebase(argsObj.branch);
            break;
          case "continue_rebase":
            result = continueRebase(argsObj.branch, argsObj.add_all);
            break;
          case "push_preserved_branch":
            result = pushPreservedBranch(argsObj.branch);
            break;
          case "finish_management":
            finalResult = argsObj;
            result = { ok: true };
            break;
          default:
            result = { ok: false, error: `Unknown tool: ${call.name}` };
        }
      } catch (error) {
        result = { ok: false, error: error?.stack || String(error) };
      }
      outputs.push({
        type: "function_call_output",
        call_id: call.call_id,
        output: JSON.stringify(result),
      });
    }

    if (finalResult) break;
    response = await createManagerResponse({
      model: MODEL,
      reasoning: { effort: EFFORT },
      previous_response_id: response.id,
      input: outputs,
      tools,
    });
  }

  if (!finalResult) {
    finalResult = {
      status: "no_action",
      reason: response.output_text || "Manager stopped without a final action.",
      next_phase: defaultNextPhase,
    };
  }

  const finalSnapshot = collectSnapshot();
  const payload = {
    ...finalResult,
    snapshot: finalSnapshot,
  };
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

main().catch(error => {
  process.stderr.write(`${error.stack || String(error)}\n`);
  process.exit(1);
});
