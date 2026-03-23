# Testing Guide — Reproducing the Multi-Agent Notes Tests with Your Squad

This guide shows you exactly how to run every test, understand what it verifies, and extend the suite when you adapt this repo for your own team.

---

## Prerequisites

- Git 2.32+ (for `git notes merge -s` strategy support)
- PowerShell 7+ (`pwsh`)
- A clone of this repo with `squad-init.ps1` already run:
  ```bash
  git clone https://github.com/tamirdresher_microsoft/squad-git-notes-reference
  cd squad-git-notes-reference
  pwsh ./scripts/squad-init.ps1
  ```

---

## Quick run — all tests

```powershell
pwsh ./scripts/test-multi-agent.ps1
```

Expected output:
```
🧪 Multi-agent notes test suite

── Test 1: Different namespaces (Data vs Worf, same commit) ──
  ✅ PASS: Data pushed squad/data notes
  ✅ PASS: Worf pushed squad/worf notes (no conflict)
  ✅ PASS: Worf note readable from Data's clone
  ✅ PASS: Data note readable

── Test 2: Same namespace, sequential writes (append) ──
  ✅ PASS: Both notes present in squad/data (append semantics)

── Test 3: Simulated push conflict (race condition) ──
  ✅ PASS: Worf's push correctly detected as non-fast-forward
  ✅ PASS: Worf pushed successfully after conflict resolution
  ✅ PASS: Both research entries preserved after merge

── Test 4: Log traversal (reachability) ──
  ✅ PASS: Experimental note NOT visible from main (reachability works)
  ✅ PASS: Experimental note still accessible directly by SHA

═══ Results ═══
  Passed: 10
  Failed: 0
```

Exit code 0 = all pass. Exit code N = N tests failed.

---

## Keep temp dir (debug failed tests)

```powershell
pwsh ./scripts/test-multi-agent.ps1 -KeepTemp
```

This leaves the temp repo at `$env:TEMP\squad-notes-test-{random}\` with three directories:
```
remote.git/     ← the simulated origin
agent-data/     ← Data agent's clone
agent-worf/     ← Worf agent's clone
```

You can cd into them and run `git notes --ref=squad/research list` etc. to inspect state.

---

## What each test verifies

### Test 1 — Different namespaces (4 checks)

**Scenario**: Data writes to `refs/notes/squad/data`, Worf writes to `refs/notes/squad/worf`, both on the same commit at the same time.

**Setup**:
- One bare remote repo
- Two clones: `agent-data` and `agent-worf`
- Both write notes on the same commit SHA — but to **different namespaces**

**Checks**:
1. Data can push its notes without being blocked
2. Worf can push its notes **without conflict** — different namespaces are completely independent
3. Worf's note (`APPROVED`) is visible from Data's clone after fetching
4. Data's note (`JWT`) is readable

**Why it matters**: This is the core guarantee. The whole point of per-agent namespaces is that two agents never block each other. If this test fails, your git or refspec setup is broken.

**Reproducing manually**:
```bash
cd agent-data
git notes --ref=squad/data add -m '{"agent":"Data","decision":"JWT"}' HEAD
git push origin refs/notes/squad/data:refs/notes/squad/data

cd ../agent-worf
git notes --ref=squad/worf add -m '{"agent":"Worf","verdict":"APPROVED"}' HEAD
git push origin refs/notes/squad/worf:refs/notes/squad/worf
# Should succeed — no conflict
```

---

### Test 2 — Same namespace, sequential writes (1 check)

**Scenario**: Data writes two notes to its own namespace on the same commit, one after the other.

**Why this happens in production**: An agent does initial analysis, writes a note, then completes implementation and wants to add a second note to the same commit. We need both notes to be preserved.

**What `write-note.ps1` does**: Checks whether a note exists on the commit (`git notes show`). If yes → `git notes append`. If no → `git notes add`. This ensures notes accumulate as a log, not get replaced.

**Check**: After two writes, the note blob contains BOTH JSON entries.

**Reproducing manually**:
```bash
git notes --ref=squad/data add -m '{"type":"decision","decision":"First choice"}' HEAD
git notes --ref=squad/data append -m '{"type":"progress","note":"Done with it"}' HEAD
git notes --ref=squad/data show HEAD
# Should show both JSON objects on separate lines
```

---

### Test 3 — Push conflict / race condition (3 checks)

**Scenario**: Data and Worf both write to `refs/notes/squad/research` on the same commit, then both try to push. This is the "shared namespace" conflict scenario.

**This is the hardest scenario.** It simulates:
- Two agents running in parallel on the same commit
- Both finishing at roughly the same time
- Data's push lands first
- Worf's push is rejected (non-fast-forward)

**The protocol we're validating** — fetch-first-append:
1. Detect the rejected push
2. Force-fetch the namespace ref (overwrites Worf's local with Data's version)
3. Re-append Worf's note on top of the now-current remote state
4. Push — this is now a fast-forward (we're one commit ahead of remote)

**Checks**:
1. Worf's push correctly fails with a rejection error
2. After the conflict resolution, Worf can push successfully
3. After Worf's push, **both** Data's note AND Worf's note are visible from Data's clone

**Why fetch-first-append wins over `cat_sort_uniq` merge**:
- The refspec `+refs/notes/*:refs/notes/*` maps directly to local refs, not a tracking namespace (`refs/notes/remotes/origin/*`)
- There's no `refs/notes/remotes/origin/squad/research` to merge from
- Fetch-first: force-fetch overwrites local with remote, re-append adds our entry, push is always fast-forward
- Simple, predictable, no merge driver needed

**Reproducing manually**:
```bash
# Agent 1 (Data) writes and pushes
cd agent-data
git notes --ref=squad/research add -m '{"note":"Data research"}' HEAD
git push origin refs/notes/squad/research:refs/notes/squad/research

# Agent 2 (Worf) writes then push fails
cd ../agent-worf
git notes --ref=squad/research add -m '{"note":"Worf research"}' HEAD
git push origin refs/notes/squad/research:refs/notes/squad/research
# → rejected: non-fast-forward

# Worf resolves: force-fetch + re-append
git fetch origin refs/notes/squad/research:refs/notes/squad/research
git notes --ref=squad/research append -m '{"note":"Worf research"}' HEAD
git push origin refs/notes/squad/research:refs/notes/squad/research
# → success

# Both notes now on remote
cd ../agent-data
git fetch origin refs/notes/*:refs/notes/*
git notes --ref=squad/research show HEAD  # shows both notes
```

---

### Test 4 — Log traversal / reachability (2 checks)

**Scenario**: A note exists on a commit that is on a feature branch but NOT reachable from `main`. After the branch is abandoned (but not yet gc'd), what happens?

**This is the key correctness test.** It validates the "rejected-but-valuable" property — notes on rejected commits don't leak into the main timeline, but are still accessible directly.

**Setup**:
- Main branch has commits A → B
- Feature branch (not merged) has commits A → B → C → D
- Note is written on commit D (feature branch only)

**Checks**:
1. `git log main --notes=squad/data` does NOT show the note from D — D is not reachable from main
2. `git notes --ref=squad/data show <sha-of-D>` DOES show the note — it's still accessible by SHA

**Why this matters**: This is scenario 1 from the [demo repo](https://github.com/tamirdresher_microsoft/squad-git-notes-demo). A rejected PR's decisions are invisible from main but not lost — Ralph can still archive them to `state/research/` by traversing the closed branch.

**Reproducing manually**:
```bash
# Create a commit on a branch
git checkout -b feature/experiment
echo "x" >> code.txt && git add . && git commit -m "experimental"
SHA=$(git log -1 --format="%H")

# Write a note on it
git notes --ref=squad/data add -m '{"note":"too risky"}' $SHA

# Check from main — note should NOT appear
git checkout main
git log main --notes=squad/data  # no mention of "too risky"

# But direct SHA access still works
git notes --ref=squad/data show $SHA  # shows "too risky"
```

---

## Testing with your actual squad agents

### Scenario A: Teach an agent to write notes, verify in test

Add a new `write-note.ps1` call in your agent's workflow, then run the test suite to confirm it goes through the right namespace.

Example — adding a Picard agent:
1. Add `"picard"` to the `ValidateSet` in `write-note.ps1` line 15
2. Create `.squad/agents/picard/charter.md` with the notes protocol
3. Add a test sub-suite to `test-multi-agent.ps1`:
   ```powershell
   Suite "Test 5: Picard writes architecture note"
   $clonePicard = "$WorkDir/agent-picard"
   git clone -q $remote $clonePicard
   ...
   ```

### Scenario B: Test a real ralph-watch round locally

```powershell
# Point ralph-watch at your fork
pwsh ./scripts/ralph-watch.ps1 `
  -Repo "your-org/your-repo" `
  -Once -DryRun
```

`-DryRun` shows you what would happen without touching GitHub or notes. Remove `-DryRun` to run for real.

### Scenario C: Test promotion pipeline (notes → decisions.md)

```powershell
# Write a promotable note on HEAD
pwsh ./scripts/notes/write-note.ps1 `
  -Agent data -Type decision `
  -Content '{"decision":"Use dependency injection","reasoning":"Testability"}' `
  -Promote

# Push the note
git push origin refs/notes/*:refs/notes/*

# Simulate a PR merge by running promote directly
pwsh ./scripts/notes/promote.ps1 -Branch main -DryRun

# If DryRun output looks right, run for real
pwsh ./scripts/notes/promote.ps1 -Branch main
git show origin/squad/state:decisions.md  # your decision should be there
```

### Scenario D: Test archive pipeline (rejected notes → research/)

```powershell
# On a feature branch, write an archivable note
git checkout -b feature/experiment
git commit --allow-empty -m "experiment"
pwsh ./scripts/notes/write-note.ps1 `
  -Agent seven -Type research `
  -Content '{"topic":"Alternative approach","conclusion":"Too slow at scale"}' `
  -Archive
git push origin refs/notes/*:refs/notes/*

# Simulate branch rejection
pwsh ./scripts/notes/archive.ps1 `
  -ClosedBranch feature/experiment `
  -Reason "rejected" `
  -DryRun

# Check research archive
git show origin/squad/state:research/  # not yet
# Run for real:
pwsh ./scripts/notes/archive.ps1 -ClosedBranch feature/experiment -Reason "rejected"
git ls-tree -r origin/squad/state -- research/  # your archived note appears
```

---

## Test matrix

| Test | What breaks if it fails |
|------|------------------------|
| T1a: Data push succeeds | Notes not configured, push refspec missing |
| T1b: Worf push no conflict | Namespace isolation broken |
| T1c: Cross-clone read | Fetch refspec not configured |
| T1d: Data note readable | Basic notes git object store |
| T2: Append semantics | `write-note.ps1` uses `add` instead of `append` |
| T3a: Conflict detected | Git is silently accepting conflicting pushes |
| T3b: Resolution push | Fetch-first-append protocol broken |
| T3c: Both entries preserved | Resolution dropped one agent's data |
| T4a: Not in main log | Reachability filter not working (`git log main --notes`) |
| T4b: Direct SHA access | Notes GC'd too early, or not pushed |

---

## Adding new tests

The test file uses a simple helper pattern:

```powershell
Suite "Test N: Description"
# ... setup ...
if ($condition) { Pass "test name" } else { Fail "test name" "reason" }
```

`$passed` and `$failed` are script-scope counters. Exit code = `$failed`. Add your suite block before the `RESULTS` section at the bottom of `test-multi-agent.ps1`.

---

## CI integration (optional)

If you want the tests to run on every PR:

```yaml
# .github/workflows/notes-test.yml
name: Git Notes Protocol Tests
on: [push, pull_request]
jobs:
  notes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Run notes tests
        run: pwsh ./scripts/test-multi-agent.ps1
```

No GitHub token or external service needed — the test uses a fully local bare repo.
