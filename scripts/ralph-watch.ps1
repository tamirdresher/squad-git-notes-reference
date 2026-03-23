#!/usr/bin/env pwsh
# scripts/ralph-watch.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Ralph-watch — the local squad automation loop with git notes support.
#
# This is the script you run locally to:
#   • Triage open GitHub issues
#   • Spawn background agents to work on them
#   • After merges: promote notes → decisions.md
#   • After closes/rejects: archive notes → research/
#   • Sync notes with remote every round
#
# Usage:
#   ./scripts/ralph-watch.ps1                    # continuous loop
#   ./scripts/ralph-watch.ps1 -Once              # single round
#   ./scripts/ralph-watch.ps1 -DryRun            # see what would happen
#   ./scripts/ralph-watch.ps1 -SkipNotes         # disable notes sync (debugging)
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [int]    $PollIntervalSeconds = 120,
    [string] $Repo                = "tamirdresher_microsoft/squad-git-notes-reference",
    [string] $Branch              = "main",
    [string] $RepoPath            = ".",
    [switch] $Once,
    [switch] $DryRun,
    [switch] $SkipNotes
)

$ErrorActionPreference = "Continue"
$ScriptsRoot = $PSScriptRoot

function Log ([string]$msg, [string]$level = "INFO") {
    $colors = @{ INFO="Cyan"; WARN="Yellow"; ERR="Red"; OK="Green"; NOTES="Magenta" }
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [$level] $msg" -ForegroundColor ($colors[$level] ?? "White")
}

function Invoke-NotesSetup {
    if ($SkipNotes) { return }
    Log "Setting up notes fetch refspec..." NOTES
    & "$ScriptsRoot/notes/fetch.ps1" -Setup -RepoPath $RepoPath -Quiet
}

function Sync-Notes {
    param([string]$Direction = "fetch")
    if ($SkipNotes) { return }
    if ($Direction -eq "fetch") {
        Log "Syncing notes from remote..." NOTES
        & "$ScriptsRoot/notes/fetch.ps1" -RepoPath $RepoPath -Quiet
    } elseif ($Direction -eq "push") {
        Log "Pushing notes to remote..." NOTES
        git -C $RepoPath push origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "Notes push conflict — fetching and merging..." WARN
            & "$ScriptsRoot/notes/fetch.ps1" -Merge -RepoPath $RepoPath -Quiet
            git -C $RepoPath push origin "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
        }
    }
}

function Get-OpenIssues {
    $json = gh issue list --repo $Repo --state open --json "number,title,labels,assignees" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "Failed to fetch issues: $json" ERR
        return @()
    }
    return ($json | ConvertFrom-Json)
}

$WatermarkFile = Join-Path $RepoPath ".squad/ralph-pr-watermark.json"

function Get-PRWatermark {
    if (Test-Path $WatermarkFile) {
        $w = Get-Content $WatermarkFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($w.lastChecked) { return $w.lastChecked }
    }
    # First run — look back 7 days to catch any PRs closed during a long outage
    return (Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Set-PRWatermark {
    @{ lastChecked = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") } |
        ConvertTo-Json | Set-Content $WatermarkFile -Encoding UTF8
}

function Get-RecentlyMergedPRs {
    $since = Get-PRWatermark
    $json = gh pr list --repo $Repo --state merged --json "number,title,headRefName,mergedAt" `
             --search "merged:>$since" 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    return ($json | ConvertFrom-Json)
}

function Get-RecentlyClosedPRs {
    $since = Get-PRWatermark
    $json = gh pr list --repo $Repo --state closed --json "number,title,headRefName,closedAt" `
             --search "closed:>$since" 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    # Filter out merges — only unmerged closes (rejections)
    return ($json | ConvertFrom-Json | Where-Object { -not $_.mergedAt })
}

function Test-IsActionable ([object]$issue) {
    $blockedLabels = @("blocked","needs-design","human-required","wontfix")
    $inProgressLabels = @("in-progress","squad:copilot")
    $hasBlocked   = $issue.labels | Where-Object { $blockedLabels -contains $_.name }
    $hasProgress  = $issue.labels | Where-Object { $inProgressLabels -contains $_.name }
    if ($hasBlocked -or $hasProgress) { return $false }
    if ($issue.assignees -and $issue.assignees.Count -gt 0) { return $false }
    return $true
}

function Claim-Issue ([int]$Number) {
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    Log "Claiming issue #$Number..." OK
    gh issue edit $Number --repo $Repo --add-assignee "@me" 2>&1 | Out-Null
    gh issue comment $Number --repo $Repo --body "🔄 Claimed by **ralph-watch** at $ts" 2>&1 | Out-Null
}

function Write-RoundSummaryNote ([int]$round, [string[]]$actions) {
    if ($SkipNotes -or $actions.Count -eq 0) { return }
    $content = @{
        note    = "Round $round summary"
        actions = $actions
        round   = $round
    } | ConvertTo-Json -Compress
    & "$ScriptsRoot/notes/write-note.ps1" `
        -Agent ralph -Type progress -Content $content `
        -RepoPath $RepoPath -NoPush -Quiet
}

# ════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ════════════════════════════════════════════════════════════════════════════

Log "Ralph-watch starting. Repo: $Repo  Branch: $Branch  Interval: ${PollIntervalSeconds}s"
Log "Notes: $(if ($SkipNotes) {'DISABLED'} else {'ENABLED'})"

# One-time setup
Invoke-NotesSetup

$round = 0
do {
    $round++
    $roundActions = @()
    Log "═══ Round $round ═══" INFO

    # ── 1. Sync notes from remote ──────────────────────────────────────────
    Sync-Notes -Direction fetch

    # ── 2. Handle recently merged PRs: promote notes ───────────────────────
    $mergedPRs = Get-RecentlyMergedPRs
    foreach ($pr in $mergedPRs) {
        Log "PR #$($pr.number) merged ($($pr.headRefName)) — promoting notes..." OK
        if (-not $DryRun -and -not $SkipNotes) {
            & "$ScriptsRoot/notes/promote.ps1" -Branch $Branch -RepoPath $RepoPath -Quiet
        }
        $roundActions += "Promoted notes after PR #$($pr.number) merge"
    }

    # ── 3. Handle recently closed PRs: archive notes ──────────────────────
    $closedPRs = Get-RecentlyClosedPRs
    foreach ($pr in $closedPRs) {
        Log "PR #$($pr.number) closed/rejected ($($pr.headRefName)) — archiving notes..." WARN
        if (-not $DryRun -and -not $SkipNotes) {
            & "$ScriptsRoot/notes/archive.ps1" `
                -ClosedBranch $pr.headRefName -MainBranch $Branch `
                -RepoPath $RepoPath -Reason "pr-closed" -Quiet
        }
        $roundActions += "Archived notes from rejected PR #$($pr.number)"
    }

    # ── 4. Triage open issues ──────────────────────────────────────────────
    $issues     = Get-OpenIssues
    $actionable = $issues | Where-Object { Test-IsActionable $_ }

    Log "Issues: $($issues.Count) total, $($actionable.Count) actionable"

    foreach ($issue in $actionable) {
        Log "→ Issue #$($issue.number): $($issue.title)" OK
        if (-not $DryRun) {
            Claim-Issue -Number $issue.number
            # NOTE: In a real setup, you'd spawn a background Copilot agent here.
            # gh copilot run --issue $issue.number  (or equivalent)
            # For now we log the intent.
            Log "  [Would spawn agent for #$($issue.number)]" INFO
        }
        $roundActions += "Triaged issue #$($issue.number)"
    }

    # ── 5. Write round summary note ────────────────────────────────────────
    Write-RoundSummaryNote -round $round -actions $roundActions

    # ── 6. Persist PR watermark — survives restarts, covers any outage gap ─
    if (-not $DryRun) { Set-PRWatermark }

    # ── 7. Push all notes ──────────────────────────────────────────────────
    Sync-Notes -Direction push

    Log "Round $round complete. $(if ($Once) { 'Exiting (once mode).' } else { "Sleeping ${PollIntervalSeconds}s..." })"

    if (-not $Once) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }

} while (-not $Once)
