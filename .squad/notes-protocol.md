# Squad Notes Protocol
# The contract all agents must follow when using git notes for state management.
# Version: 1.0 (2026-03-23)
# Referenced by: all agent charters, ralph-watch.ps1, copilot-instructions.md

---

## Overview

Squad state lives in two layers. This document defines the **git notes layer** — the thin commit-scoped layer that
attaches agent context to commits without ever appearing in PRs or diffs.

The **permanent state layer** (decisions.md, routing.md, agent histories) lives on the `squad/state` orphan branch.
See `.squad/upstream.json` for that pointer.

---

## Namespaces

Each agent writes to its own namespace to prevent conflicts:

| Namespace | Owner | Purpose |
|-----------|-------|---------|
| `refs/notes/squad/data` | Data | Architecture decisions, implementation choices |
| `refs/notes/squad/worf` | Worf | Security reviews, vulnerability assessments |
| `refs/notes/squad/seven` | Seven | Documentation quality notes, API contract decisions |
| `refs/notes/squad/ralph` | Ralph | Work-round progress, task-state annotations |
| `refs/notes/squad/q` | Q | Devil's advocate findings, risk assessments |
| `refs/notes/squad/research` | Any agent | Research notes that should survive branch deletion |
| `refs/notes/squad/review` | Any agent | Code review context (mirrors Gerrit's pattern) |

**Rule**: Only write to your own namespace. Never write to another agent's namespace.

---

## Note JSON Schema

All notes MUST be valid JSON. Minimum required fields:

```json
{
  "agent": "Data",
  "timestamp": "2026-03-23T14:00:00Z",
  "type": "decision | research | review | progress | security",
  "content": "..."
}
```

Full schema for decision notes:
```json
{
  "agent": "Data",
  "timestamp": "2026-03-23T14:00:00Z",
  "type": "decision",
  "decision": "Use JWT RS256 for auth middleware",
  "reasoning": "Existing pattern in codebase — auth.go:47-89 already has a JWT parser.",
  "alternatives_considered": ["HS256", "session tokens", "API keys"],
  "confidence": "high | medium | low",
  "promote_to_permanent": false
}
```

Set `"promote_to_permanent": true` to signal Ralph to copy this to `decisions.md` after the PR merges.

Full schema for research notes:
```json
{
  "agent": "Data",
  "timestamp": "2026-03-23T14:00:00Z",
  "type": "research",
  "topic": "JWT vs session tokens",
  "findings": { ... },
  "effort_hours": 2.5,
  "archive_on_close": true
}
```

Set `"archive_on_close": true` to signal Ralph to archive this to `state/research/` even if the PR is rejected.

---

## When to Use Git Notes vs State Repo

Use **git notes** (`refs/notes/squad/*`) for:
- "Why did we make THIS choice on THIS specific commit"
- Decisions that should travel with the code change that caused them
- Research scoped to a feature investigation
- Security review sign-offs for a specific commit
- Agent-to-agent context that only matters for the current feature

Use the **state repo** (`squad/state` branch) for:
- Universal routing rules, conventions, team agreements
- Long-lived decisions that future agents should always have access to
- Research archives (promoted from notes after PR close)
- Agent history/context that persists across features

When in doubt: **notes first, promote to state repo later**. Ralph handles the promotion automatically.

---

## Write Commands

```bash
# Write a decision note
git notes --ref=squad/data add \
  -m '{"agent":"Data","timestamp":"...","type":"decision","decision":"...","reasoning":"..."}' \
  HEAD

# Append to an existing note (use when multiple items for the same commit)
git notes --ref=squad/data append \
  -m '{"agent":"Data","timestamp":"...","type":"decision","decision":"..."}' \
  HEAD

# Read your note back
git notes --ref=squad/data show HEAD

# List all commits with notes in your namespace
git notes --ref=squad/data list
```

Or use the helper script:
```powershell
./scripts/notes/write-note.ps1 -Agent data -Type decision \
  -Content '{"decision":"Use JWT","reasoning":"..."}' \
  [-Commit HEAD] [-Promote] [-Archive]
```

---

## Push Notes

**CRITICAL**: Notes are NOT pushed by default. Always push explicitly:

```bash
git push origin 'refs/notes/*:refs/notes/*'
```

Or configure once to auto-push (not standard git behavior, requires explicit push step in workflows):
```bash
git config --add remote.origin.push 'refs/notes/*:refs/notes/*'
```

Ralph-watch pushes notes automatically at the end of each work round.

---

## Fetch Notes (Setup Required)

**CRITICAL**: Notes are NOT fetched by default. Every developer and every machine needs this once:

```bash
git config --add remote.origin.fetch 'refs/notes/*:refs/notes/*'
git fetch origin 'refs/notes/*:refs/notes/*'
```

Or run:
```powershell
./scripts/notes/fetch.ps1 -Setup
```

Ralph-watch runs this on every startup.

---

## Conflict Handling

**Rule 1**: Per-agent namespaces prevent 99% of conflicts. If only one agent writes to `refs/notes/squad/data`, there are no write conflicts.

**Rule 2**: If the same agent runs on two machines and both try to annotate the same commit:
1. First push wins (git will reject the second as non-fast-forward)
2. Losing machine should: `git fetch origin 'refs/notes/*:refs/notes/*'`, then append with `git notes append`

**Rule 3**: For `squad/research` and `squad/review` (shared namespaces), always use `git notes append` not `git notes add`.

**Rule 4**: If a push conflict occurs on notes, run:
```bash
git fetch origin 'refs/notes/*:refs/notes/*'
git notes merge refs/notes/remotes/origin/squad/data
git push origin 'refs/notes/*:refs/notes/*'
```

---

## Ralph's Promotion Rules

After every PR merge, Ralph:
1. Fetches all notes from remote
2. Traverses commits reachable from `main` that have notes
3. For each note where `"promote_to_permanent": true` → appends to `state/decisions.md`
4. Pushes state branch

After every PR close/rejection, Ralph:
1. Lists all notes in `squad/research` on the closed branch's commits
2. For each note where `"archive_on_close": true` → archives to `state/research/`
3. Pushes state branch
4. Logs SHA so notes can be expired later (after 90 days)

---

## New Developer Setup

When someone joins the project or clones fresh:

```powershell
# One-time setup — adds notes refspec and fetches existing notes
./scripts/notes/fetch.ps1 -Setup
```

This is the "developer clones fresh and doesn't know to fetch notes" UX problem. The `fetch.ps1 -Setup` call is the fix — it should be part of any `README.md` onboarding section.
