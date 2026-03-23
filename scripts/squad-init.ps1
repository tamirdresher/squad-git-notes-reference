#!/usr/bin/env pwsh
# scripts/squad-init.ps1
# ─────────────────────────────────────────────────────────────────────────────
# One-time setup for the squad git-notes flow in this repo.
# Run once after cloning to configure notes refspecs and create the state branch.
#
# Usage:
#   git clone https://github.com/tamirdresher_microsoft/squad-git-notes-reference
#   cd squad-git-notes-reference
#   pwsh ./scripts/squad-init.ps1
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [string]$Remote  = "origin",
    [string]$Repo    = ".",
    [switch]$DryRun,
    [switch]$SkipStateInit  # skip creating squad/state branch (use if it already exists)
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

function Log ([string]$msg, [string]$color = "Cyan") {
    Write-Host "[squad-init] $msg" -ForegroundColor $color
}
function Step ([string]$msg) {
    Write-Host "`n── $msg" -ForegroundColor White
}

# ═══ 1. Configure notes fetch refspec ════════════════════════════════════════
Step "1/5  Notes fetch refspec"
$existing = git -C $Repo config --get-all "remote.$Remote.fetch" 2>&1 |
            Where-Object { $_ -match "refs/notes" }

if ($existing) {
    Log "  refspec already configured: $existing" Green
} else {
    if (-not $DryRun) {
        git -C $Repo config --add "remote.$Remote.fetch" "+refs/notes/*:refs/notes/*"
        Log "  Added: +refs/notes/*:refs/notes/*" Green
    } else {
        Log "  [DRY-RUN] Would add notes refspec" DarkYellow
    }
}

# ═══ 2. Fetch existing notes ═════════════════════════════════════════════════
Step "2/5  Fetch existing notes"
if (-not $DryRun) {
    git -C $Repo fetch $Remote "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
    $nsCount = (git -C $Repo for-each-ref "refs/notes/squad/" --format="%(refname)" 2>&1 |
                Where-Object { $_ -ne "" }).Count
    Log "  Found $nsCount squad note namespace(s)" Green
} else {
    Log "  [DRY-RUN] Would fetch notes" DarkYellow
}

# ═══ 3. Create squad/state orphan branch ════════════════════════════════════
Step "3/5  squad/state branch"

if ($SkipStateInit) {
    Log "  Skipping state branch init (SkipStateInit)" DarkGray
} else {
    $stateExists = git -C $Repo ls-remote $Remote "refs/heads/squad/state" 2>&1
    if ($stateExists -match "squad/state") {
        Log "  squad/state already exists on remote — fetching..." Green
        git -C $Repo fetch $Remote "squad/state:refs/remotes/$Remote/squad/state" 2>&1 | Out-Null
    } else {
        Log "  Creating squad/state orphan branch..."
        if (-not $DryRun) {
            # Create in a temp worktree
            $tmpDir = Join-Path $env:TEMP "squad-state-init-$(Get-Random)"
            git -C $Repo worktree add -q --orphan $tmpDir 2>&1 | Out-Null

            # Seed files
            $decisionsContent = @"
# Squad Decisions

_This file is auto-maintained by Ralph's promotion loop._
_Entries are added when PRs merge with `promote_to_permanent: true` notes._

---

"@
            $routingContent = @"
# Squad Routing

All issues are routed to the appropriate agent based on labels/title.
See `.squad/routing.md` in the main branch for the current rules.
"@
            Set-Content -Path "$tmpDir/decisions.md"        -Value $decisionsContent -Encoding UTF8
            Set-Content -Path "$tmpDir/routing.md"          -Value $routingContent   -Encoding UTF8
            New-Item    -ItemType Directory -Path "$tmpDir/research" -Force | Out-Null
            Set-Content -Path "$tmpDir/research/.gitkeep"   -Value "" -Encoding UTF8

            git -C $tmpDir add "."
            git -C $tmpDir commit -q -m "chore(state): initialize squad/state branch"
            git -C $tmpDir push $Remote "HEAD:squad/state" 2>&1 | Out-Null

            git -C $Repo worktree remove $tmpDir --force 2>&1 | Out-Null
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

            Log "  squad/state created and pushed" Green
        } else {
            Log "  [DRY-RUN] Would create squad/state orphan branch" DarkYellow
        }
    }
}

# ═══ 4. Write a seed note to verify everything works ════════════════════════
Step "4/5  Write seed note"
if (-not $DryRun) {
    $seedContent = @{
        note      = "squad-init: notes pipeline verified"
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        repo      = (git -C $Repo remote get-url $Remote 2>&1)
    } | ConvertTo-Json -Compress

    & "$here/notes/write-note.ps1" `
        -Agent ralph -Type progress -Content $seedContent `
        -RepoPath $Repo -NoPush -Quiet

    git -C $Repo push $Remote "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
    Log "  Seed note written and pushed" Green
} else {
    Log "  [DRY-RUN] Would write seed note" DarkYellow
}

# ═══ 5. Verify ════════════════════════════════════════════════════════════════
Step "5/5  Verify"
$namespaces = git -C $Repo for-each-ref "refs/notes/squad/" --format="%(refname:short)" 2>&1 |
              Where-Object { $_ -ne "" }
Log "  Active namespaces: $($namespaces -join ', ')" Green

$stateRef = git -C $Repo ls-remote $Remote "refs/heads/squad/state" 2>&1
if ($stateRef -match "squad/state") {
    Log "  squad/state: OK" Green
} else {
    Log "  squad/state: NOT FOUND (check errors above)" Yellow
}

Write-Host "`n✅  Squad init complete! You can now run:" -ForegroundColor Green
Write-Host "    pwsh ./scripts/ralph-watch.ps1 -Once  " -ForegroundColor DarkGray
Write-Host "    pwsh ./scripts/test-multi-agent.ps1   " -ForegroundColor DarkGray
