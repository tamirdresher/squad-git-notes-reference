# Squad Git Notes Reference

> **Companion repo for** [Part 7b: Building on Unstable Ground — Git Notes and the Two-Layer State Pattern](https://tamirdresher.github.io)

This repository is a **fully working Squad setup** with git notes baked into every agent, Ralph-watch loop, and state management flow. Fork it to start a Squad-enabled project with the two-layer state pattern from day one.

---

## What's in here

| Layer | Mechanism | Lives in |
|---|---|---|
| **Ephemeral** (agent working notes) | `refs/notes/squad/*` | git object store |
| **Permanent** (accepted decisions) | `squad/state:decisions.md` | orphan branch |
| **Research archive** (rejected-but-valuable) | `squad/state:research/` | orphan branch |

Agents write ephemeral notes while working. Ralph promotes valuable ones to the permanent layer after merges — and archives research from rejected branches so nothing is lost.

---

## Quick start

```bash
git clone https://github.com/tamirdresher_microsoft/squad-git-notes-reference
cd squad-git-notes-reference
pwsh ./scripts/squad-init.ps1
```

`squad-init.ps1` does exactly four things:
1. Adds the notes fetch refspec to `.git/config`
2. Fetches all `refs/notes/*` from origin
3. Creates the `squad/state` orphan branch (if it doesn't exist)
4. Writes a seed note to verify the pipeline works

Run the test suite to verify multi-agent behavior:

```bash
pwsh ./scripts/test-multi-agent.ps1
```

All 4 tests should pass (different namespaces, append semantics, conflict resolution, reachability).

---

## Running Ralph-watch

```bash
# One round (great for testing)
pwsh ./scripts/ralph-watch.ps1 -Once

# Continuous loop (every 2 minutes)
pwsh ./scripts/ralph-watch.ps1

# See what would happen without doing anything
pwsh ./scripts/ralph-watch.ps1 -DryRun -Once
```

Each round:
1. Fetch fresh notes from remote
2. Detect recently merged PRs → promote `promote_to_permanent` notes to `decisions.md`
3. Detect recently closed/rejected PRs → archive `archive_on_close` notes to `research/`
4. Triage open issues → claim and route to agents
5. Write a round-summary note
6. Push all notes to remote

> **Note**: `ralph-watch.ps1` is the local experiment loop. When things stabilize, the same logic moves to the `squad watch` CLI command. Think of ralph-watch as the local proving ground before production.

---

## How agents write notes

```bash
# Data records an architecture decision
pwsh ./scripts/notes/write-note.ps1 \
  -Agent data -Type decision \
  -Content '{"decision":"Use JWT for auth","reasoning":"Stateless, horizontally scalable"}' \
  -Promote   # → decisions.md after merge

# Worf records a security review
pwsh ./scripts/notes/write-note.ps1 \
  -Agent worf -Type security-review \
  -Content '{"verdict":"APPROVED","findings":["Rotate JWT secret quarterly"]}' \
  -Archive   # → research/ if PR is rejected

# Seven records a universal truth
pwsh ./scripts/notes/write-note.ps1 \
  -Agent seven -Type research \
  -Content '{"topic":"Auth","conclusion":"JWT has no server-side revocation — plan accordingly"}' \
  -Promote   # universal truths always go to decisions.md
```

The helper: fetches before writing, appends to existing notes, retries push conflicts automatically.

---

## Namespace ownership

| Agent | Namespace | What goes there |
|---|---|---|
| Data | `refs/notes/squad/data` | Architecture decisions, API contracts |
| Worf | `refs/notes/squad/worf` | Security reviews, risk assessments |
| Seven | `refs/notes/squad/seven` | Universal truths, known constraints |
| Ralph | `refs/notes/squad/ralph` | Progress, round summaries |
| Q | `refs/notes/squad/q` | Counter-arguments, devil's advocate flags |
| Shared | `refs/notes/squad/research` | Cross-agent research (always append) |
| Shared | `refs/notes/squad/review` | Cross-agent code review (always append) |

---

## Note JSON schema

```json
{
  "agent": "Data",
  "timestamp": "2026-03-23T14:00:00Z",
  "type": "decision | research | review | security-review | progress | api-contract",
  "promote_to_permanent": false,
  "archive_on_close": false,
  "...type-specific fields..."
}
```

- **`promote_to_permanent: true`** → Ralph appends to `squad/state:decisions.md` after merge
- **`archive_on_close: true`** → Ralph saves to `squad/state:research/` when branch closes without merging

---

## Multi-agent conflict handling

```
1. Always fetch before writing:  git fetch origin refs/notes/*:refs/notes/*
2. Use append, not add:          git notes --ref=squad/research append ...
3. On push rejection (non-fast-forward):
   a. Fetch remote notes
   b. Run: git notes merge refs/notes/remotes/origin/research
   c. Repush
```

`write-note.ps1` handles all three steps automatically. `test-multi-agent.ps1` validates the whole flow.

---

## Reading notes

```bash
# Fetch first (notes are NOT fetched by git pull by default)
git fetch origin refs/notes/*:refs/notes/*

# All notes on main
git log main --notes=squad/data --notes=squad/worf --format="%h %s%n%N"

# Notes on a specific commit
git notes --ref=squad/data show <sha>

# Research archive
git show origin/squad/state:decisions.md
git ls-tree -r origin/squad/state -- research/
```

---

## File structure

```
.
├── .squad/
│   ├── copilot-instructions.md   ← read by all GitHub Copilot agents
│   ├── notes-protocol.md         ← the notes protocol contract
│   ├── routing.md                ← issue routing rules
│   ├── upstream.json             ← state branch config
│   └── agents/
│       ├── data/charter.md
│       ├── worf/charter.md
│       ├── seven/charter.md
│       ├── ralph/charter.md
│       └── q/charter.md
├── scripts/
│   ├── squad-init.ps1            ← one-time setup (run after clone)
│   ├── ralph-watch.ps1           ← main automation loop
│   ├── test-multi-agent.ps1      ← validates multi-agent conflict handling
│   └── notes/
│       ├── fetch.ps1             ← fetch notes + setup refspec
│       ├── write-note.ps1        ← agent helper (validates + writes + pushes)
│       ├── promote.ps1           ← after merge: notes → decisions.md
│       └── archive.ps1           ← after close: notes → research/
└── src/
    └── ...                       ← your project code here
```

---

## Related

- **Demo repo**: [squad-git-notes-demo](https://github.com/tamirdresher_microsoft/squad-git-notes-demo) — four runnable scenarios illustrating why notes beats branches for state
- **Git worktrees post**: [Working with Git Worktrees](https://tamirdresher.github.io) — used here by `promote.ps1` and `archive.ps1` to update the state branch without disrupting your working tree
- **Blog series**: [Scaling AI — Part 7b](https://tamirdresher.github.io)
