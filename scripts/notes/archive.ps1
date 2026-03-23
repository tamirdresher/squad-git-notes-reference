#!/usr/bin/env pwsh
# scripts/notes/archive.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Archive research notes from a closed/rejected branch into squad/state:research/.
# Called by ralph-watch when a PR is rejected or a branch is closed.
#
# Algorithm:
# 1. List all commits on $ClosedBranch NOT reachable from $MainBranch
# 2. For each note where archive_on_close == true
# 3. Archive to squad/state:research/{date}-{agent}-{sha}.json
# 4. Push state branch
#
# Usage:
#   ./scripts/notes/archive.ps1 -ClosedBranch feature/auth-v2 -Reason rejected
#   ./scripts/notes/archive.ps1 -ClosedBranch feature/auth-v2 -DryRun
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClosedBranch,

    [string]$MainBranch = "main",
    [string]$RepoPath   = ".",
    [string]$Remote     = "origin",
    [string]$Reason     = "closed",
    [switch]$DryRun,
    [switch]$Quiet
)

function Log ([string]$msg, [string]$color = "White") {
    if (-not $Quiet) { Write-Host "[notes/archive]$(if($DryRun){' [DRY-RUN]'}) $msg" -ForegroundColor $color }
}

# Safely split a string containing one or more concatenated JSON objects.
function Split-JsonObjects ([string]$text) {
    $results = [System.Collections.Generic.List[string]]::new()
    $depth = 0; $start = -1; $inString = $false; $esc = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($esc)                          { $esc = $false; continue }
        if ($c -eq '\' -and $inString)     { $esc = $true;  continue }
        if ($c -eq '"')                    { $inString = !$inString; continue }
        if ($inString)                     { continue }
        if ($c -eq '{')                    { if ($depth -eq 0) { $start = $i }; $depth++ }
        elseif ($c -eq '}')               { $depth--; if ($depth -eq 0 -and $start -ge 0) { $results.Add($text.Substring($start, $i - $start + 1)); $start = -1 } }
    }
    return $results
}

$repo = Resolve-Path $RepoPath

# ── Fetch notes and branches ──────────────────────────────────────────────────
Log "Fetching notes and refs..."
git -C $repo fetch $Remote "refs/notes/*:refs/notes/*" 2>&1 | Out-Null
git -C $repo fetch $Remote 2>&1 | Out-Null

# ── Find commits on closed branch NOT on main ────────────────────────────────
Log "Finding commits exclusive to $ClosedBranch..."

# Commits on closed branch but not reachable from main
$exclusiveCommits = git -C $repo log "$Remote/$ClosedBranch" --not "$Remote/$MainBranch" --format="%H" 2>&1 |
                    Where-Object { $_ -match "^[0-9a-f]{40}" }

if (-not $exclusiveCommits) {
    Log "No exclusive commits found on $ClosedBranch. Nothing to archive." DarkGray
    return
}

Log "Found $($exclusiveCommits.Count) exclusive commit(s) on $ClosedBranch" Green

# ── Find archivable notes ────────────────────────────────────────────────────
$namespaces = git -C $repo for-each-ref "refs/notes/squad/" --format="%(refname:short)" 2>&1 |
              Where-Object { $_ -ne "" }

$archivable = [System.Collections.Generic.List[object]]::new()

foreach ($sha in $exclusiveCommits) {
    foreach ($ns in $namespaces) {
        $note = git -C $repo notes --ref=$ns show $sha 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $note) { continue }

        try {
            $noteText = if ($note -is [array]) { $note -join "`n" } else { $note }
            $entries  = (Split-JsonObjects $noteText) |
                        ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null } } |
                        Where-Object { $_ -ne $null }

            foreach ($entry in $entries) {
                if ($entry.archive_on_close -eq $true) {
                    $archivable.Add(@{
                        Sha       = $sha
                        Namespace = $ns
                        Entry     = $entry
                        Raw       = ($entry | ConvertTo-Json -Depth 10)
                    })
                }
            }
        } catch {
            Log "  Warning: could not parse note on $($sha.Substring(0,8)) in $ns" DarkYellow
        }
    }
}

Log "Found $($archivable.Count) archivable note(s)" Green

if ($archivable.Count -eq 0) {
    Log "No notes marked archive_on_close=true on $ClosedBranch." DarkGray
    return
}

# ── Archive to state branch ────────────────────────────────────────────────
if (-not $DryRun) {
    $tmpDir = Join-Path $env:TEMP "squad-state-archive-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        # Worktree guard: prune any dangling worktrees left by a prior killed run
        git -C $repo worktree prune 2>&1 | Out-Null

        git -C $repo worktree add -q $tmpDir "squad/state" 2>&1 | Out-Null

        $researchDir = Join-Path $tmpDir "research"
        New-Item -ItemType Directory -Path $researchDir -Force | Out-Null

        $date = Get-Date -Format "yyyyMMdd"
        foreach ($item in $archivable) {
            $shortSha = $item.Sha.Substring(0,8)
            $agent    = $item.Entry.agent ?? "unknown"
            $topic    = ($item.Entry.topic ?? $item.Entry.type ?? "research") -replace '\s+', '-'
            $filename = "$date-$($agent.ToLower())-$shortSha-$topic.json"
            $filepath = Join-Path $researchDir $filename

            $archiveEntry = @{
                archived_at     = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                archived_by     = "Ralph"
                reason          = $Reason
                source_branch   = $ClosedBranch
                source_commit   = $item.Sha
                source_namespace= $item.Namespace
                note            = $item.Entry
            }

            # Dedup guard: skip if this SHA+namespace was already archived on a prior retry
            if (Test-Path $filepath) {
                Log "  Skipping duplicate: $filename (already archived)" DarkGray
                continue
            }
            $archiveEntry | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8

            Log "  Archived: $filename" Green
            git -C $tmpDir add "research/$filename"
        }

        git -C $tmpDir commit -q -m "chore(state): archive $($archivable.Count) note(s) from $ClosedBranch ($Reason)"

        $pushOut = git -C $tmpDir push $Remote "squad/state" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "State branch push failed: $pushOut" Red
            Write-Warning "[archive] Push failed — entries committed locally. Will fast-forward push next round."
        } else {
            Log "State branch updated with $($archivable.Count) archived note(s)." Green
        }

    } finally {
        git -C $repo worktree remove $tmpDir --force 2>&1 | Out-Null
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Log "DRY RUN — would archive $($archivable.Count) note(s):"
    foreach ($item in $archivable) {
        Log "  $($item.Sha.Substring(0,8)) [$($item.Namespace)] $(($item.Entry.topic ?? $item.Entry.type))" DarkGray
    }
}
