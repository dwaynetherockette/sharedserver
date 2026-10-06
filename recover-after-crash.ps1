$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

$Remote    = "origin"
$Branch    = "main"
$WorldPath = "world"
$LockFile  = "HOSTING_LOCK.json"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "Git is not installed or is not on PATH." }
if (-not (Test-Path ".git")) { Fail "This folder is not a Git repository." }

Write-Host "Fetching remote state..."
& git fetch $Remote $Branch
if ($LASTEXITCODE -ne 0) { Fail "Could not contact GitHub. Recovery cannot safely continue." }

$counts = (& git rev-list --left-right --count "$Remote/$Branch...HEAD").Trim() -split "\s+"
if ($LASTEXITCODE -ne 0 -or $counts.Count -lt 2) { Fail "Could not compare local and remote history." }
$remoteAhead = [int]$counts[0]
$localAhead  = [int]$counts[1]

# Easy case: shutdown already made a local save commit, but push failed.
if ($localAhead -gt 0 -and $remoteAhead -eq 0) {
    Write-Host "Found $localAhead local commit(s) waiting to be uploaded."
    & git push $Remote $Branch
    if ($LASTEXITCODE -ne 0) { Fail "Push still failed. Nothing was deleted; try again after fixing connectivity/authentication." }
    Write-Host "Recovery upload succeeded." -ForegroundColor Green
    exit 0
}

if ($remoteAhead -gt 0 -or ($remoteAhead -gt 0 -and $localAhead -gt 0)) {
    Fail "The remote history moved ahead of this computer. Automatic recovery is intentionally blocked to avoid overwriting somebody else's world."
}

# At this point local HEAD and origin/main are the same commit. Verify the remote lock belongs to this machine.
$remoteLockText = & git show "$Remote/$Branch`:$LockFile" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $remoteLockText) {
    Fail "GitHub does not contain a hosting lock. There is nothing this recovery script can safely unlock automatically."
}

try {
    $remoteLock = ($remoteLockText -join "`n") | ConvertFrom-Json
} catch {
    Fail "The remote hosting lock could not be parsed."
}

if ($remoteLock.computer -ne $env:COMPUTERNAME) {
    Fail "The hosting lock belongs to computer '$($remoteLock.computer)', not '$env:COMPUTERNAME'. Recovery must be performed on the machine that hosted the interrupted session."
}

Write-Host "Remote lock belongs to this computer ($env:COMPUTERNAME)."
$worldStatus = & git status --porcelain -- $WorldPath
if ($LASTEXITCODE -ne 0) { Fail "Could not inspect the local world." }

if ($worldStatus) {
    Write-Host "Local world changes found; they will be preserved and uploaded."
} else {
    Write-Host "No uncommitted world changes found; this will only release this computer's stale lock."
}

Remove-Item $LockFile -ErrorAction SilentlyContinue
& git add -A -- $WorldPath $LockFile
if ($LASTEXITCODE -ne 0) { Fail "Could not stage recovery data." }

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
& git commit -m "Crash recovery: $env:USERNAME@$env:COMPUTERNAME - $timestamp"
if ($LASTEXITCODE -ne 0) { Fail "Could not create the recovery commit." }

& git push $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    Fail "Recovery commit is safe locally, but upload failed. Run this script again after fixing the connection/authentication problem."
}

Write-Host "Recovery succeeded: latest local world uploaded and hosting lock released." -ForegroundColor Green
