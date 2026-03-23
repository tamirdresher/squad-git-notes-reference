# Squad Copilot Instructions
# This file is read by ALL GitHub Copilot agents working in this repo.
# Last updated: 2026-03-23

---

## Team Identity

This is a Squad-enabled repository. The AI engineering team consists of:
- **Ralph** — Work orchestrator, loop manager, notes promoter
- **Data** — Code implementation, architecture decisions
- **Worf** — Security review, vulnerability assessment
- **Seven** — Documentation, API contracts, routing
- **Q** — Devil's advocate, risk assessment
- **Picard** — Lead escalation, architecture decisions requiring human judgment

Each agent has a charter at `.squad/agents/{name}/charter.md`. Read your charter before starting work.

---

## Git Notes — The Core State Protocol

**Every agent in this team uses git notes for commit-scoped state.** This is not optional — it is the foundation of how the team remembers context without polluting pull requests.

### What you MUST do on every work round

1. **On startup**: Run `./scripts/notes/fetch.ps1` to get all current notes from remote
2. **Before reading any commit's context**: Check notes: `git notes --ref=squad/{agent} show {sha}`
3. **When making a significant decision**: Write it as a note on the relevant commit
4. **After your round**: Push your notes: `git push origin 'refs/notes/*:refs/notes/*'`

### Why git notes (not .squad/decisions.md)

Writing to `.squad/decisions.md` on a feature branch creates a merge conflict trap — if the PR is rejected, your decision gets buried or lost. Git notes are addressed by commit SHA, are invisible in PR diffs, and automatically become non-reachable (not promoted) if the PR is rejected.

See `.squad/notes-protocol.md` for the full contract.

### Your namespace

Each agent writes to their own namespace. Look up your namespace in `.squad/notes-protocol.md`.
Never write to another agent's namespace.

### The minimal write pattern

```bash
git notes --ref=squad/{your-agent} add \
  -m '{"agent":"{Your-Agent}","timestamp":"{ISO8601}","type":"{decision|research|review|progress}","content":"..."}' \
  HEAD
```

Use `git notes append` if a note already exists on this commit in your namespace.

---

## State Repo

The permanent team memory lives on the `squad/state` orphan branch of this repo. Pointer is in `.squad/upstream.json`.

**How to read current decisions**:
```bash
git fetch origin squad/state:refs/remotes/origin/squad/state
git show origin/squad/state:decisions.md
```

**How to read routing rules**:
```bash
git show origin/squad/state:routing.md
```

Do NOT write directly to the state branch unless you are Seven (universal routing updates) or Ralph (after merge promotion). All other agents write notes, and Ralph promotes them.

---

## Routing

Read `.squad/routing.md` for the current routing rules.

Default routing for this repo:
- Code changes → Data
- Security issues → Worf
- Documentation → Seven
- Unknown/blocked → Ralph triage, escalate to Picard if needed
- Anything that feels wrong → Q for devil's advocate review first

---

## PR Protocol

Before opening a PR:
1. Make sure your notes are pushed: `git push origin 'refs/notes/*:refs/notes/*'`
2. Verify your PR contains **zero** `.squad/` file changes (unless it is specifically a `.squad/` update)
3. Label the PR correctly: `squad:review` for changes needing human review

After a PR is merged:
- Ralph will automatically promote notes to `decisions.md` if `"promote_to_permanent": true` was set

After a PR is rejected:
- Notes on rejected commits are NOT promoted (this is the desired behavior)
- Ralph will archive `"archive_on_close": true` research notes to `state/research/`

---

## Multi-Machine / Multi-Instance

If you are running on multiple machines or if another instance of you is active:
1. Before writing any notes, fetch first: `git fetch origin 'refs/notes/*:refs/notes/*'`
2. Use `git notes append` instead of `git notes add` for shared namespaces
3. If a push is rejected (non-fast-forward): fetch, merge notes, push again
   ```bash
   git notes merge refs/notes/remotes/origin/squad/{namespace}
   git push origin 'refs/notes/*:refs/notes/*'
   ```

---

## File Organization

```
.squad/
  copilot-instructions.md  ← You are reading this
  notes-protocol.md        ← Read this for the full notes contract
  upstream.json            ← State repo pointer
  routing.md               ← Who handles what
  agents/
    {name}/charter.md      ← Per-agent detailed instructions
```

```
scripts/
  squad-init.ps1           ← Run once after cloning (sets up notes, state)
  ralph-watch.ps1          ← Ralph's main loop
  notes/
    fetch.ps1              ← Fetch notes from remote
    write-note.ps1         ← Helper for writing notes
    promote.ps1            ← Promote merged notes to decisions.md
    archive.ps1            ← Archive rejected-PR research notes
```

---

## Key Invariants

1. **No squad state in feature PR diffs** — decisions go in git notes, not `.squad/` file edits
2. **Notes are always JSON** — never plain text, always parseable
3. **Per-agent namespaces** — never write to another agent's namespace
4. **Fetch before write** — always fetch notes before reading or writing
5. **Push after round** — always push notes at the end of your work
6. **Promote_to_permanent for lasting decisions** — set this flag if the decision should outlast this branch
