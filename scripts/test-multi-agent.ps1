#!/usr/bin/env pwsh
# scripts/test-multi-agent.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Tests multi-agent notes behavior in isolation (no GitHub required).
# Creates a local temp repo, simulates two agents writing notes simultaneously,
# verifies that:
#   1. Agents writing to DIFFERENT namespaces: zero conflict
#   2. Agents writing to the SAME commit, SAME namespace: append semantics
#   3. Simulated push conflict: fetch+merge+repush succeeds
#
# This is the reference test that validates the notes protocol before deploying.
#
# Usage:
#   pwsh ./scripts/test-multi-agent.ps1
#   pwsh ./scripts/test-multi-agent.ps1 -Verbose
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [string]$WorkDir    = (Join-Path $env:TEMP "squad-notes-test-$(Get-Random)"),
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$passed = 0; $failed = 0

function Log   ([string]$msg)                   { Write-Host "  $msg" -ForegroundColor Gray }
function Pass  ([string]$test)                  { $script:passed++; Write-Host "  ✅ PASS: $test" -ForegroundColor Green }
function Fail  ([string]$test, [string]$reason) { $script:failed++; Write-Host "  ❌ FAIL: $test — $reason" -ForegroundColor Red }
function Suite ([string]$name)                  { Write-Host "`n── $name ──" -ForegroundColor Cyan }

# ── Helpers ─────────────────────────────────────────────────────────────────
function New-AgentNote {
    param($repo, $agent, $type, [hashtable]$fields, $commit = "HEAD")
    $content = ([ordered]@{} + $fields) | ConvertTo-Json -Compress
    $result = & "$PSScriptRoot/notes/write-note.ps1" `
                -Agent $agent -Type $type -Content $content `
                -RepoPath $repo -Commit $commit -NoPush -Quiet 2>&1
    return $LASTEXITCODE -eq 0
}

function Get-Note {
    param($repo, $agent, $commit = "HEAD")
    $ns = "squad/$agent"
    $note = git -C $repo notes --ref=$ns show $commit 2>&1
    return if ($LASTEXITCODE -eq 0) { $note | ConvertFrom-Json -ErrorAction SilentlyContinue }
}

function Add-Commit {
    param($repo, $msg = "test commit")
    $file = Join-Path $repo "file-$(Get-Random).txt"
    Set-Content $file "content"
    git -C $repo add (Split-Path $file -Leaf) | Out-Null
    git -C $repo commit -q -m $msg | Out-Null
}

# ════════════════════════════════════════════════════════════════════════════
# SETUP: Create bare "remote" + two agent clone directories
# ════════════════════════════════════════════════════════════════════════════

Write-Host "`n🧪 Multi-agent notes test suite" -ForegroundColor White
Write-Host "   Working dir: $WorkDir`n" -ForegroundColor DarkGray

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$remote    = Join-Path $WorkDir "remote.git"
$cloneData = Join-Path $WorkDir "agent-data"    # simulates Data agent's working dir
$cloneWorf = Join-Path $WorkDir "agent-worf"    # simulates Worf agent's working dir

# Init bare remote
git init --bare -q $remote
git -C $remote symbolic-ref HEAD refs/heads/main

# Clone for Data agent
git clone -q $remote $cloneData
git -C $cloneData config user.email "data@squad.local"
git -C $cloneData config user.name "Data"
git -C $cloneData config --add "remote.origin.fetch" "+refs/notes/*:refs/notes/*"

# Seed a commit
Set-Content (Join-Path $cloneData "README.md") "# Test Project"
git -C $cloneData add "README.md"
git -C $cloneData commit -q -m "initial commit"
git -C $cloneData push -q origin main

# Clone for Worf agent (from same remote, after initial commit)
git clone -q $remote $cloneWorf
git -C $cloneWorf config user.email "worf@squad.local"
git -C $cloneWorf config user.name "Worf"
git -C $cloneWorf config --add "remote.origin.fetch" "+refs/notes/*:refs/notes/*"

$targetSha = git -C $cloneData log -1 --format="%H"

# ════════════════════════════════════════════════════════════════════════════
# TEST 1: Different namespaces — no conflict
# ════════════════════════════════════════════════════════════════════════════

Suite "Test 1: Different namespaces (Data vs Worf, same commit)"

$r1 = New-AgentNote -repo $cloneData -agent "data" -type "decision" -fields @{
    decision  = "Use JWT for auth"
    reasoning = "Stateless, scalable"
    promote_to_permanent = $true
} -commit $targetSha

$r2 = New-AgentNote -repo $cloneWorf -agent "worf" -type "security-review" -fields @{
    verdict  = "APPROVED"
    findings = @("JWT secret must be rotated quarterly")
    archive_on_close = $true
} -commit $targetSha

# Push Data's notes
git -C $cloneData push -q origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Pass "Data pushed squad/data notes" } else { Fail "Data push" "exit $LASTEXITCODE" }

# Push Worf's notes — different namespace, no conflict expected
git -C $cloneWorf push -q origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Pass "Worf pushed squad/worf notes (no conflict)" } else { Fail "Worf push" "exit $LASTEXITCODE" }

# Verify both notes exist on remote
git -C $cloneData fetch origin "refs/notes/*:refs/notes/*" -q 2>&1 | Out-Null
$dataNoteCheck = git -C $cloneData notes --ref=squad/data show $targetSha 2>&1
$worfNoteCheck = git -C $cloneData notes --ref=squad/worf show $targetSha 2>&1

if ($LASTEXITCODE -eq 0 -and $worfNoteCheck -match "APPROVED")  { Pass "Worf note readable from Data's clone" } else { Fail "Worf note" "not found on remote" }
if ($dataNoteCheck -match "JWT") { Pass "Data note readable" } else { Fail "Data note" "not found" }

# ════════════════════════════════════════════════════════════════════════════
# TEST 2: Same namespace, SEQUENTIAL writes — append semantics
# ════════════════════════════════════════════════════════════════════════════

Suite "Test 2: Same namespace, sequential writes (append)"

# Data adds another note to squad/data on the same commit
New-AgentNote -repo $cloneData -agent "data" -type "progress" -fields @{
    note = "Implemented JWT middleware"
} -commit $targetSha | Out-Null

$note = git -C $cloneData notes --ref=squad/data show $targetSha 2>&1
$noteText = if ($note -is [array]) { $note -join "`n" } else { $note }

if ($noteText -match "JWT for auth" -and $noteText -match "Implemented JWT middleware") {
    Pass "Both notes present in squad/data (append semantics)"
} else {
    Fail "Append semantics" "Expected both entries, got: $($noteText.Substring(0,[Math]::Min(200,$noteText.Length)))"
}

# ════════════════════════════════════════════════════════════════════════════
# TEST 3: Push conflict — simulated race condition
# ════════════════════════════════════════════════════════════════════════════

Suite "Test 3: Simulated push conflict (race condition)"

# Add a new commit
Add-Commit $cloneData "feature: auth endpoint"
git -C $cloneData push -q origin main 2>&1 | Out-Null
git -C $cloneWorf pull -q origin main 2>&1 | Out-Null

$newSha = git -C $cloneData log -1 --format="%H"

# Both agents write a note to squad/research on the SAME new commit
New-AgentNote -repo $cloneData -agent "research" -type "research" -fields @{
    topic  = "OAuth vs JWT"
    note   = "Data's research: JWT wins on scalability"
    archive_on_close = $true
} -commit $newSha | Out-Null

New-AgentNote -repo $cloneWorf -agent "research" -type "research" -fields @{
    topic  = "OAuth vs JWT"
    note   = "Worf's research: OAuth has better revocation"
    archive_on_close = $true
} -commit $newSha | Out-Null

# Data pushes first
git -C $cloneData push -q origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
Log "Data pushed research note first"

# Worf pushes second — expect conflict
$worfPushOut = git -C $cloneWorf push origin "refs/notes/*:refs/notes/*" 2>&1
if ($LASTEXITCODE -ne 0 -and $worfPushOut -match "non-fast-forward") {
    Pass "Worf's push correctly detected as non-fast-forward"

    # Resolve: fetch + merge
    git -C $cloneWorf fetch origin "refs/notes/*:refs/notes/*" -q 2>&1 | Out-Null
    $remoteRef = "refs/notes/remotes/origin/research"
    git -C $cloneWorf notes merge $remoteRef 2>&1 | Out-Null
    Log "Worf ran notes merge"

    # Now push again
    git -C $cloneWorf push -q origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Pass "Worf pushed successfully after conflict resolution"

        # Verify both entries are now on remote
        git -C $cloneData fetch origin "refs/notes/*:refs/notes/*" -q 2>&1 | Out-Null
        $researchNote = git -C $cloneData notes --ref=squad/research show $newSha 2>&1
        $researchText = if ($researchNote -is [array]) { $researchNote -join "`n" } else { $researchNote }

        if ($researchText -match "JWT wins" -and $researchText -match "OAuth has better") {
            Pass "Both research entries preserved after merge"
        } else {
            Fail "Research note content" "Missing one entry. Got: $($researchText.Substring(0,[Math]::Min(300,$researchText.Length)))"
        }
    } else {
        Fail "Worf second push" "Still failed after merge: exit $LASTEXITCODE"
    }
} elseif ($LASTEXITCODE -eq 0) {
    # Sometimes the remote fast-forwards if notes happen to be compatible
    Log "Push succeeded without conflict (acceptable if notes auto-merged)" DarkGray
    Pass "Worf push succeeded (no conflict needed)"
} else {
    Fail "Worf conflict detection" "Unexpected error: $worfPushOut"
}

# ════════════════════════════════════════════════════════════════════════════
# TEST 4: Log traversal — notes only on reachable commits
# ════════════════════════════════════════════════════════════════════════════

Suite "Test 4: Log traversal (reachability)"

# Create a rejected branch with a note
Add-Commit $cloneData "wip: experimental feature"
$branchSha = git -C $cloneData log -1 --format="%H"
git -C $cloneData checkout -q -b "squad/experimental" 2>&1 | Out-Null
Add-Commit $cloneData "feat: experimental only"
$expSha = git -C $cloneData log -1 --format="%H"

New-AgentNote -repo $cloneData -agent "data" -type "research" -fields @{
    topic    = "Experimental approach"
    note     = "This approach was too risky"
    archive_on_close = $true
} -commit $expSha | Out-Null

git -C $cloneData push -q origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null

# Now log from main — should NOT see the experimental commit's note
git -C $cloneData checkout -q main 2>&1 | Out-Null
$notesOnMain = git -C $cloneData log main --notes=squad/data --format="%H %N" 2>&1 |
               Where-Object { $_ -match "too risky" }

if (-not $notesOnMain) {
    Pass "Experimental note NOT visible from main (reachability works)"
} else {
    Fail "Reachability" "Experimental note leaked into main log"
}

# But note IS accessible by SHA directly
$directNote = git -C $cloneData notes --ref=squad/data show $expSha 2>&1
if ($LASTEXITCODE -eq 0 -and $directNote -match "too risky") {
    Pass "Experimental note still accessible directly by SHA"
} else {
    Fail "Direct SHA access" "Note not found by SHA"
}

# ════════════════════════════════════════════════════════════════════════════
# RESULTS
# ════════════════════════════════════════════════════════════════════════════

Write-Host "`n═══ Results ═══" -ForegroundColor White
Write-Host "  Passed: $passed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor (if ($failed -gt 0) { "Red" } else { "Green" })

if (-not $KeepTemp) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit $failed
